# Platform Setup Guide

This document describes how to build the open5GS + UERANSIM three-slice containerised 5G Core platform from scratch on an Ubuntu 22.04 host.

## Hardware Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| CPU | x86_64, 4 cores | 8+ cores |
| RAM | 16 GB | 32 GB (92 GB for 600s experiments) |
| Storage | 50 GB free | 200 GB (raw trace files are large) |
| OS | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| Kernel | 5.15+ | 6.8.0 (TC-BPF support) |

---

## 1. Container Infrastructure — Incus 6.23

Incus is a community fork of LXD and provides the container runtime for all 5GC network functions.

### Install Incus

```bash
# Add the Zabbly repository
curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/zabbly.gpg] \
  https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main" \
  > /etc/apt/sources.list.d/zabbly-incus-stable.list
apt update && apt install -y incus

# Install LXC libraries
apt install -y lxc

# Initialise Incus
incus admin init --minimal
```

### Create the br5gc Bridge Network

```bash
# Create bridge
ip link add br5gc type bridge
ip addr add 10.45.0.1/24 dev br5gc
ip link set br5gc up

# Enable NAT — replace wlp23s0 with your outbound interface
iptables -t nat -A POSTROUTING -s 10.45.0.0/24 -o wlp23s0 -j MASQUERADE
iptables -A FORWARD -i br5gc -j ACCEPT
iptables -A FORWARD -o br5gc -j ACCEPT

# Save rules across reboots
apt install -y iptables-persistent
netfilter-persistent save
```

### Create and Configure Containers

```bash
# Launch base Ubuntu 22.04 containers
for name in amf-smf upf1 upf2 upf3 gnb-ue; do
    incus launch ubuntu:22.04 $name
done

# Attach all containers to br5gc bridge
for name in amf-smf upf1 upf2 upf3 gnb-ue; do
    incus network attach br5gc $name eth0
done

# Assign static IPs (add to /etc/netplan inside each container)
incus exec amf-smf -- ip addr add 10.45.0.10/24 dev eth0
incus exec upf1    -- ip addr add 10.45.0.11/24 dev eth0
incus exec upf2    -- ip addr add 10.45.0.12/24 dev eth0
incus exec upf3    -- ip addr add 10.45.0.13/24 dev eth0
incus exec gnb-ue  -- ip addr add 10.45.0.14/24 dev eth0

# Enable privileged mode and TUN device for UPF containers
for name in upf1 upf2 upf3; do
    incus config set $name security.privileged true
    incus config device add $name tun unix-char path=/dev/net/tun
    incus restart $name
done
```

### Container Summary

| Container | IP Address | Mode | Services |
|-----------|-----------|------|----------|
| amf-smf | 10.45.0.10 | Standard | open5GS v2.7.6 + MongoDB 7.0 |
| upf1 | 10.45.0.11 | Privileged + tun | open5GS UPF + iperf3 server |
| upf2 | 10.45.0.12 | Privileged + tun | open5GS UPF + Asterisk 18.10 |
| upf3 | 10.45.0.13 | Privileged + tun | open5GS UPF + Nginx 1.18 |
| gnb-ue | 10.45.0.14 | Standard | UERANSIM v3.2.7 |

---

## 2. open5GS v2.7.6

### Build from Source (inside amf-smf container)

```bash
incus exec amf-smf -- bash

apt install -y git cmake meson ninja-build build-essential \
    libgnutls28-dev libgcrypt-dev libssl-dev libidn11-dev \
    libmongoc-dev libbson-dev libyaml-dev libnghttp2-dev \
    libmicrohttpd-dev libcurl4-gnutls-dev libtins-dev libtalloc-dev

git clone --branch v2.7.6 https://github.com/open5gs/open5gs.git
cd open5gs
meson build --prefix=/usr
ninja -C build
ninja -C build install
```

All Network Functions installed: NRF, SCP, SEPP, AMF, SMF, UPF, AUSF, UDM, UDR, PCF, NSSF, BSF.

### Install MongoDB 7.0 (inside amf-smf container)

```bash
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
    > /etc/apt/sources.list.d/mongodb-org-7.0.list
apt update && apt install -y mongodb-org
systemctl enable --now mongod
```

### Add Subscribers

```bash
# Add three UE subscribers — one per slice
open5gs-dbctl add 999700000000001 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA
open5gs-dbctl add 999700000000002 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA
open5gs-dbctl add 999700000000003 465B5CE8B199B49FAA5F0A2EE238A6BC E8ED289DEBA952E4283B54E88E6183CA
```

Configure each subscriber with the appropriate S-NSSAI (SST/SD) and DNN to route to the correct UPF. Refer to the open5GS documentation at https://open5gs.org/open5gs/docs/ for subscriber configuration details.

### Copy UPF Binary to UPF Containers

```bash
for name in upf1 upf2 upf3; do
    incus file push /usr/bin/open5gs-upfd $name/usr/bin/
    incus file push /usr/lib/open5gs/ $name/usr/lib/ --recursive
done
```

---

## 3. UERANSIM v3.2.7

### Build from Source (inside gnb-ue container)

```bash
incus exec gnb-ue -- bash

apt install -y git cmake g++ libsctp-dev lksctp-tools iproute2

git clone https://github.com/aligungr/UERANSIM.git
cd UERANSIM
git checkout v3.2.7
mkdir build && cd build
cmake ..
make -j$(nproc)
```

### UE3 Heartbeat Fix — Required Before Use

The default UERANSIM binary declares radio link failure within 9 minutes under mMTC curl traffic. This is caused by the RLS heartbeat threshold of 2000ms in `src/ue/rls/udp_task.cpp` being too low for sustained data traffic. Apply this fix once:

```bash
# Inside gnb-ue container
sed -i 's/HEARTBEAT_THRESHOLD = 2000/HEARTBEAT_THRESHOLD = 10000/' \
    /root/UERANSIM/src/ue/rls/udp_task.cpp

cd /root/UERANSIM
mkdir -p build_cmake && cd build_cmake
cmake .. -DCMAKE_BUILD_TYPE=Release > /dev/null 2>&1
make -j$(nproc) nr-ue 2>&1 | tail -3
```

Always use `./build_cmake/nr-ue` for UE3. UE1 and UE2 can use the default `./build/nr-ue`.

---

## 4. Application Servers

### Asterisk 18 — URLLC slice (upf2)

```bash
incus exec upf2 -- bash
apt install -y asterisk
# Configure Asterisk for SIP/RTP on 10.42.0.1
systemctl enable --now asterisk
```

### Nginx 1.18 — mMTC slice (upf3)

```bash
incus exec upf3 -- bash
apt install -y nginx
# Create a test file for curl streaming
dd if=/dev/urandom of=/var/www/html/stream.bin bs=1M count=10
systemctl enable --now nginx
```

### iperf3 — eMBB slice (upf1)

```bash
incus exec upf1 -- bash
apt install -y iperf3
# iperf3 server is started automatically by the experiment scripts
```

---

## 5. Network Slicing Configuration

Edit the open5GS SMF and UPF configuration YAML files to define three slices:

| Slice | SST | SD | DNN | UPF ogstun IP | UPF container |
|-------|-----|----|-----|---------------|---------------|
| eMBB | 1 | 0x000001 | internet | 10.41.0.1/16 | upf1 |
| URLLC | 2 | 0x000002 | voip | 10.42.0.1/16 | upf2 |
| mMTC | 3 | 0x000003 | streaming | 10.43.0.1/16 | upf3 |

Refer to https://open5gs.org/open5gs/docs/ for SMF and UPF YAML configuration details.

---

## 6. Platform Scripts

The `platform/` folder contains three convenience scripts. They use container names and network addresses matching this setup. Adapt them if your configuration differs.

```bash
# Start the full platform
bash platform/start_5g.sh
# Wait for: Platform is READY!

# Check platform health
bash platform/status_5g.sh

# Stop everything cleanly
bash platform/stop_5g.sh
```

`start_5g.sh` performs: systemctl restart incus, incus start all containers, ogstun interface restoration, and waits for all 9 open5GS NFs to be ready.

---

## 7. Dependencies Summary

### Host (Ubuntu 22.04)

```bash
apt install -y incus lxc gawk bpftrace linux-tools-$(uname -r) \
    tshark iproute2 iptables-persistent python3-pip
pip3 install pandas numpy matplotlib
```

### Inside amf-smf

open5GS v2.7.6, MongoDB 7.0, Node.js (for open5GS WebUI)

### Inside gnb-ue

UERANSIM v3.2.7, iperf3, sipp, curl

### Inside upf1

open5GS UPF, iperf3

### Inside upf2

open5GS UPF, Asterisk 18

### Inside upf3

open5GS UPF, Nginx 1.18
