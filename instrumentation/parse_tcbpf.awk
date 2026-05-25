#!/usr/bin/awk -f
# parse_tcbpf.awk — Parse TC-BPF trace_pipe output into M1/M3 delay pairs
# Akhil's PhD: Intelligent Latency-Aware UPF Orchestration | MNNIT Allahabad
#
# Input: /sys/kernel/debug/tracing/trace_pipe lines filtered to "upf_m"
# Format: process-tid [cpu] flags ts: bpf_trace_printk: upf_m1 SLICE ts=NS len=LEN teid=TEID
#
# Output CSV: ts_rx_ns,ts_tx_ns,delay_us,pkt_len,netif_rx,slice
#
# Match window: 600 µs — M1 (GTP-U ingress) to M3 (ogstun egress)
# Per-slice buffers: separate M1 pending queues per slice for correct pairing

BEGIN {
    WINDOW_NS = 10000000
    BUF_SIZE  = 500
    matched   = 0
    print "ts_rx_ns,ts_tx_ns,delay_us,pkt_len,netif_rx,slice"
}

/bpf_trace_printk: upf_m/ {
    # Extract type and slice: "upf_m1 eMBB" or "upf_m3 eMBB"
    if (match($0, /upf_m([13]) ([^ ]+) ts=([0-9]+) len=([0-9]+)/, arr)) {
        mtype = arr[1]   # "1" or "3"
        slice = arr[2]   # "eMBB", "URLLC", "mMTC"
        ts    = arr[3] + 0
        len   = arr[4] + 0
    } else {
        next
    }

    if (mtype == "1") {
        # Store M1 in per-slice circular buffer
        key = slice "_" (buf_head[slice] % BUF_SIZE)
        m1_ts[key]   = ts
        m1_len[key]  = len
        m1_used[key] = 0
        buf_head[slice]++
        if (buf_count[slice] < BUF_SIZE) buf_count[slice]++
    }
    else if (mtype == "3") {
        # Find matching M1 in same slice within window
        if (!(slice in buf_count) || buf_count[slice] == 0) next

        count = buf_count[slice]
        head  = buf_head[slice]
        start = (head - count + BUF_SIZE * 10000) % BUF_SIZE

        best_idx  = -1
        best_diff = WINDOW_NS + 1

        for (k = 0; k < count; k++) {
            idx = (start + k) % BUF_SIZE
            key = slice "_" idx
            if (m1_used[key]) continue
            diff = ts - m1_ts[key]
            if (diff < 0) continue
            if (diff > WINDOW_NS) {
                m1_used[key] = 1  # expire
                continue
            }
            if (diff < best_diff) {
                best_diff = diff
                best_idx  = idx
            }
        }

        if (best_idx >= 0) {
            key = slice "_" best_idx
            m1_used[key] = 1
            delay_us = best_diff / 1000.0
            printf "%d,%d,%.3f,%d,%s,%s\n",
                m1_ts[key], ts, delay_us, m1_len[key], slice, slice
            matched++
        }
    }
}

END {
    print "# matched=" matched > "/dev/stderr"
}
