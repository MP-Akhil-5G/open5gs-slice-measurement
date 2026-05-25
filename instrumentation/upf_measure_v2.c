// SPDX-License-Identifier: GPL-2.0
/*
 * upf_measure_v2.c — TC-BPF O1 measurement using bpf_trace_printk
 * Output goes to /sys/kernel/debug/tracing/trace_pipe
 * Akhil's PhD: Intelligent Latency-Aware UPF Orchestration | MNNIT Allahabad
 *
 * Compile:
 *   clang -O2 -g -target bpf -c upf_measure_v2.c -o upf_measure_v2.o \
 *         -I/usr/include -I/usr/include/x86_64-linux-gnu
 *
 * Attach (from host, per UPF namespace):
 *   UPF1: nsenter -t <UPF1_PID> -n tc filter add dev eth0 ingress bpf da obj upf_measure_v2.o sec tc/m1_embb
 *   UPF1: nsenter -t <UPF1_PID> -n tc filter add dev ogstun egress bpf da obj upf_measure_v2.o sec tc/m3_embb
 *   UPF2: ... sec tc/m1_urllc / tc/m3_urllc
 *   UPF3: ... sec tc/m1_mmtc  / tc/m3_mmtc
 *
 * Read output:
 *   cat /sys/kernel/debug/tracing/trace_pipe | grep "upf_m"
 */

#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#define IPPROTO_UDP 17
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define GTP_UDP_PORT 2152

struct gtpuhdr {
    __u8   flags;
    __u8   msg_type;
    __be16 length;
    __be32 teid;
} __attribute__((packed));

/* ── eMBB M1 — eth0 ingress in UPF1 namespace ──────────────────────────────── */
SEC("tc/m1_embb")
int m1_embb(struct __sk_buff *skb)
{
    void *data     = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(0x0800)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;
    if (ip->protocol != IPPROTO_UDP) return TC_ACT_OK;

    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end) return TC_ACT_OK;
    if (udp->dest != bpf_htons(GTP_UDP_PORT)) return TC_ACT_OK;

    struct gtpuhdr *gtp = (void *)(udp + 1);
    if ((void *)(gtp + 1) > data_end) return TC_ACT_OK;

    __u64 ts  = bpf_ktime_get_ns();
    __u32 len = skb->len;
    __u32 teid = bpf_ntohl(gtp->teid);

    char fmt[] = "upf_m1 eMBB ts=%llu len=%u teid=%u\n";
    bpf_trace_printk(fmt, sizeof(fmt), ts, len, teid);
    return TC_ACT_OK;
}

/* ── eMBB M3 — ogstun egress in UPF1 namespace ─────────────────────────────── */
SEC("tc/m3_embb")
int m3_embb(struct __sk_buff *skb)
{
    if (skb->len < 40) return TC_ACT_OK;
    __u64 ts  = bpf_ktime_get_ns();
    __u32 len = skb->len;
    char fmt[] = "upf_m3 eMBB ts=%llu len=%u teid=0\n";
    bpf_trace_printk(fmt, sizeof(fmt), ts, len, 0);
    return TC_ACT_OK;
}

/* ── URLLC M1 ───────────────────────────────────────────────────────────────── */
SEC("tc/m1_urllc")
int m1_urllc(struct __sk_buff *skb)
{
    void *data     = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(0x0800)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;
    if (ip->protocol != IPPROTO_UDP) return TC_ACT_OK;

    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end) return TC_ACT_OK;
    if (udp->dest != bpf_htons(GTP_UDP_PORT)) return TC_ACT_OK;

    struct gtpuhdr *gtp = (void *)(udp + 1);
    if ((void *)(gtp + 1) > data_end) return TC_ACT_OK;

    __u64 ts  = bpf_ktime_get_ns();
    __u32 len = skb->len;
    __u32 teid = bpf_ntohl(gtp->teid);
    char fmt[] = "upf_m1 URLLC ts=%llu len=%u teid=%u\n";
    bpf_trace_printk(fmt, sizeof(fmt), ts, len, teid);
    return TC_ACT_OK;
}

/* ── URLLC M3 ───────────────────────────────────────────────────────────────── */
SEC("tc/m3_urllc")
int m3_urllc(struct __sk_buff *skb)
{
    if (skb->len < 40) return TC_ACT_OK;
    __u64 ts  = bpf_ktime_get_ns();
    __u32 len = skb->len;
    char fmt[] = "upf_m3 URLLC ts=%llu len=%u teid=0\n";
    bpf_trace_printk(fmt, sizeof(fmt), ts, len, 0);
    return TC_ACT_OK;
}

/* ── mMTC M1 ────────────────────────────────────────────────────────────────── */
SEC("tc/m1_mmtc")
int m1_mmtc(struct __sk_buff *skb)
{
    void *data     = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return TC_ACT_OK;
    if (eth->h_proto != bpf_htons(0x0800)) return TC_ACT_OK;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return TC_ACT_OK;
    if (ip->protocol != IPPROTO_UDP) return TC_ACT_OK;

    struct udphdr *udp = (void *)ip + (ip->ihl * 4);
    if ((void *)(udp + 1) > data_end) return TC_ACT_OK;
    if (udp->dest != bpf_htons(GTP_UDP_PORT)) return TC_ACT_OK;

    struct gtpuhdr *gtp = (void *)(udp + 1);
    if ((void *)(gtp + 1) > data_end) return TC_ACT_OK;

    __u64 ts  = bpf_ktime_get_ns();
    __u32 len = skb->len;
    __u32 teid = bpf_ntohl(gtp->teid);
    char fmt[] = "upf_m1 mMTC ts=%llu len=%u teid=%u\n";
    bpf_trace_printk(fmt, sizeof(fmt), ts, len, teid);
    return TC_ACT_OK;
}

/* ── mMTC M3 ────────────────────────────────────────────────────────────────── */
SEC("tc/m3_mmtc")
int m3_mmtc(struct __sk_buff *skb)
{
    if (skb->len < 40) return TC_ACT_OK;
    __u64 ts  = bpf_ktime_get_ns();
    __u32 len = skb->len;
    char fmt[] = "upf_m3 mMTC ts=%llu len=%u teid=0\n";
    bpf_trace_printk(fmt, sizeof(fmt), ts, len, 0);
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
