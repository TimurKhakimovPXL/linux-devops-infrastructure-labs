> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 1: Install Single Node OpenShift on Proxmox

**Objective:** Install a Single Node OpenShift (SNO) 4.21 cluster on the Proxmox lab.
**Target Environment:** Virtualized lab infrastructure
**Topology:** Control Plane and Worker nodes combined onto a single physical machine.

---

## 1. Minimum requirements

The SNO VM needs at least:

- **CPU:** Minimum 8 vCPUs (16+ recommended for production workloads).
- **RAM:** Minimum 16 GB (64 GB recommended).
- **Storage:** 120 GB minimum on storage with low, consistent write latency (see the observed storage problem below).
- **Network:** 1 static public/private IP address assigned to the server.

> [!CAUTION]
> **Storage performance matters**
> In this lab, qcow2 on directory-based (`local`) storage measured about 2 MB/s in a small `dsync` test and the bootstrap API repeatedly failed while writing RBAC data to etcd. Moving the disk to LVM thin storage raised the same rough measurement to about 1.5 GB/s and the install completed. Throughput from this `dd` command is troubleshooting evidence, not a universal etcd acceptance threshold; sustained fsync latency is the more relevant measure.
>
> **Use LVM thin provisioning** for the VM disk. Raw volumes on LVM deliver ~1.5 GB/s, which is more than sufficient.
>
> Test with: `dd if=/dev/zero of=/tmp/testfile bs=4k count=1000 oflag=dsync`

The admin workstation or jump VM needs:

- `openshift-install` binary (v4.21).
- `coreos-installer` tool.
- Red Hat CoreOS Live ISO (`rhcos-live.x86_64.iso`).
- OpenShift Pull Secret downloaded from the Red Hat Hybrid Cloud Console.

---

## 2. Step 1: DNS Planning and Configuration

OpenShift needs its API and application hostnames to resolve before the installation media boots.

Add these records to the internal BIND server:

| **Record Type**  | **Name (cluster: lab, domain: example.internal)** | **Target IP** | **Purpose**                                         |
| ---------------- | --------------------------------------------------------- | ------------- | --------------------------------------------------- |
| **A**            | `api.lab.example.internal`                        | `<Server_IP>` | External access to the cluster API and Web Console. |
| **A**            | `api-int.lab.example.internal`                    | `<Server_IP>` | Internal communication between cluster components.  |
| **A (Wildcard)** | `*.apps.lab.example.internal`                     | `<Server_IP>` | Ingress routing for deployed user applications.     |

### 2.1 DHCP Static Reservation (`dnsmasq`)

Reserve `192.168.50.20` for the SNO node's MAC address.

1. Identify the VM MAC address in the Proxmox Hardware tab.
2. Add the host entry to your DHCP configuration:

```bash
# Run as root on the Proxmox host; replace the example MAC if needed.
DHCP_HOST="dhcp-host=52:54:00:AA:BB:CC,192.168.50.20,master0"
grep -qxF "$DHCP_HOST" /etc/dnsmasq.conf || echo "$DHCP_HOST" >> /etc/dnsmasq.conf
systemctl restart dnsmasq
```

> [!WARNING]
> **DHCP Lease Conflicts**
> If you are recreating a VM with a new MAC address, the old lease for `192.168.50.20` may still be active in `/var/lib/misc/dnsmasq.leases`, causing the new VM to receive an IP from the dynamic pool instead.
>
> **Fix:** Stop dnsmasq, delete the stale lease line from `/var/lib/misc/dnsmasq.leases`, then restart dnsmasq before booting the new VM.

### 2.2 Proxmox Firewall Toggle

The Proxmox firewall must be disabled on this VM because the lab's default rules drop DHCP and internal OVN-Kubernetes traffic.

- **Action:** Proxmox GUI → SNO VM → **Hardware** → **Network Device** → Uncheck **Firewall**.

---

### 2.3 DNS Server Configuration (BIND9)

The API and application FQDNs must resolve to the node IP (`192.168.50.20`).

### 2.4 Global Options (`/etc/named.conf`)

Modify the `options {}` block to allow queries from your local subnet:

```conf
listen-on port 53 { any; };
allow-query     { localhost; 192.168.50.0/24; };
allow-recursion { localhost; 192.168.50.0/24; };
forwarders { 1.1.1.1; 8.8.8.8; };
```

### 2.5 Zone Definitions (`/etc/named.conf`)

Add the forward and reverse lookup zones:

```conf
zone "example.internal" IN {
    type master;
    file "example.internal.zone";
    allow-update { none; };
};

zone "50.168.192.in-addr.arpa" IN {
    type master;
    file "50.168.192.rev";
    allow-update { none; };
};
```

### 2.6 Forward Zone File (`/var/named/example.internal.zone`)

This file maps the OpenShift API and wildcard apps to the SNO IP.

```dns
$TTL 1W
@       IN      SOA     ns1.example.internal.     root.example.internal. (
                        2026022700      ; serial (YYYYMMDD00)
                        3H              ; refresh
                        30M             ; retry
                        2W              ; expiry
                        1W )            ; minimum
        IN      NS      ns1.example.internal.

ns1.example.internal.                     IN      A       192.168.50.10
smtp.example.internal.                    IN      A       192.168.50.10

api.lab.example.internal.       IN      A       192.168.50.20
api-int.lab.example.internal.   IN      A       192.168.50.20
*.apps.lab.example.internal.    IN      A       192.168.50.20
master0.lab.example.internal.   IN      A       192.168.50.20
```

### 2.7 Reverse Zone File (`/var/named/50.168.192.rev`)

```dns
$TTL 1W
@       IN      SOA     ns1.example.internal.     root.example.internal. (
                        2026022700      ; serial
                        3H 30M 2W 1W )
        IN      NS      ns1.example.internal.

20      IN      PTR     master0.lab.example.internal.
```

### 2.8 Syntax Validation

```bash
sudo named-checkconf /etc/named.conf
sudo named-checkzone example.internal /var/named/example.internal.zone
sudo named-checkzone 50.168.192.in-addr.arpa /var/named/50.168.192.rev
sudo systemctl restart named
```

---

## 3. Step 2: Preparing the Installation

Red Hat provides several ways to do the installation (Manual, CoreOS, Assisted). We will be following the **CoreOS path**.

### 3.1 Pull Secret

- Download the pull secret from the Red Hat Hybrid Console.
- Store it as `pull-secret.txt` on the jump VM and verify that it is valid JSON:

```bash
jq -e . pull-secret.txt >/dev/null
```

The pull secret is environment-specific and is not included in this repository. Keep the file out of version control and paste the compact output of `jq -c . pull-secret.txt` into `install-config.yaml` only on the secured jump VM.

### 3.2 Create the `install-config.yaml` Blueprint

Create a dedicated installation directory on the jump VM:

```bash
mkdir -p "$HOME/sno-install"
cd "$HOME/sno-install"
```

Create `install-config.yaml` there, ensuring `bootstrapInPlace` is declared at the root level to force the Single Node topology. Replace the pull-secret and SSH-key placeholders locally.

`bootstrapInPlace` → bootstrap AND control plane run on the same machine.

```yaml
apiVersion: v1
baseDomain: example.internal
metadata:
  name: lab
compute:
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: 1
networking:
  networkType: OVNKubernetes
  machineNetwork:
    - cidr: 192.168.50.0/24
platform:
  none: {}
bootstrapInPlace:
  installationDisk: /dev/sda
pullSecret: '<compact JSON from pull-secret.txt>'
sshKey: '<public SSH key for the core user>'
```

> [!NOTE]
> **`installationDisk: /dev/sda`**
> This tells `coreos-installer` where to write the final OS: it is **not** the boot source. The VM boots from the ISO in RAM; `/dev/sda` must be a blank, unmounted disk at install time.

---

## 4. Step 3: Generating and Embedding Ignition Data

### 4.1 Generate the SNO Ignition File

Convert the YAML blueprint into an automated provisioning script (Ignition). Use the single-node specific subcommand to prevent the installer from expecting a 3-node HA architecture.

```bash
openshift-install create single-node-ignition-config --dir=.
```

This generates a `bootstrap-in-place-for-live-iso.ign` file, alongside an `auth/` directory containing your initial cluster credentials.

### 4.2 Embed Ignition into the Bootable ISO

> [!CAUTION]
> **Critical: Use `--live-ignition`, NOT `--dest-ignition`**
> The bootstrap-in-place flow **must** run entirely in the live ISO environment (in RAM). The ignition config must be embedded as a **live ignition** so the full bootstrap process (bootkube, MCS, `install-to-disk.service`) executes while `/dev/sda` is unmounted.
>
> Using `--dest-ignition` instead embeds the ignition into the installed OS on disk. This causes `install-to-disk.service` to fail with `"Error: checking for exclusive access to /dev/sda: found busy partitions"` because the OS is already running from the disk it needs to overwrite.

```bash
coreos-installer iso customize \
  --dest-device /dev/sda \
  --live-ignition bootstrap-in-place-for-live-iso.ign \
  -o sno-installer.iso \
  rhcos-live.x86_64.iso
```

**Ignition file contains:** cluster configuration, systemd units, kubelet configuration, CRI-O configuration, networking, and bootstrap services.

**`rhcos-live.x86_64.iso` contains:** kernel, initramfs, live root filesystem, and `coreos-installer`.

### 4.3 Boot Sequence (Bootstrap-in-Place)

The SNO bootstrap-in-place flow has two distinct phases:

**Phase 1: Live ISO (runs in RAM):**

1. VM boots ISO into RAM
2. RHCOS live environment starts
3. Live ignition config loads: bootstrap services begin
4. `bootkube.service` starts: renders manifests, starts bootstrap etcd + kube-apiserver
5. Bootstrap kube-apiserver comes up, cluster resources are created
6. MCS (Machine Config Server) renders and serves the permanent node config
7. `bootkube.service` completes, stops bootstrap etcd
8. `install-to-disk.service` writes RHCOS + permanent ignition (master.ign) to `/dev/sda`
9. Node reboots (with 60-second countdown)

**Phase 2: Permanent OS (boots from disk):**

10. VM boots from `/dev/sda`
11. Ignition runs on first boot,
12. applies full machine config
13. `machine-config-daemon-firstboot.service` runs: applies OS config, pulls images
14. Node reboots once more after MCD firstboot completes
15. Permanent control plane starts (etcd, kube-apiserver, kube-controller-manager, kube-scheduler)
16. Cluster operators deploy and stabilize

### 4.4 Sanity Check

Verify the injection was successful before uploading to the server:

```bash
coreos-installer iso ignition show sno-installer.iso
```

---

## 5. Step 4: Proxmox Storage Setup

> [!CAUTION]
> **Do NOT use directory-based (`local`) storage for the SNO disk**
> qcow2 on directory storage delivered about 2 MB/s in this lab's `dsync` test, alongside repeated kube-apiserver startup-probe failures (`poststarthook/rbac/bootstrap-roles failed`). This is an observed failure mode, not a claim that every directory-backed Proxmox disk will have the same result.

### 5.1 Create LVM Thin Storage

If the Proxmox host has a verified unused disk such as `/dev/sdb`, run the following as root on that host. `pvcreate` destroys existing filesystem metadata on its target, so confirm the device with `lsblk` before continuing and replace the example storage names if the host uses different ones.

```bash
# Confirm that /dev/sdb is the intended unused disk.
lsblk -f /dev/sdb

# Create physical volume
pvcreate /dev/sdb

# Create volume group
vgcreate vm-storage /dev/sdb

# Create thin pool (use most of the space)
lvcreate -l 95%FREE -T vm-storage/vm-thin

# Add to Proxmox
pvesm add lvmthin vm-storage --vgname vm-storage --thinpool vm-thin --content images,rootdir

# Verify
pvesm status
```

---

## 6. Step 5: Bare Metal Deployment

### 6.1 Secure Copy (SCP) to the Host

From the jump VM's `~/sno-install` directory, copy the ISO over the internal LAN bridge. The destination assumes the Proxmox storage ID `local`; use the ISO directory configured for that host if it differs.

```bash
scp sno-installer.iso root@192.168.50.1:/var/lib/vz/template/iso/
```

> [!NOTE]
> **Routing**
> Attempting to `scp` to the external IP (e.g., `100.64.0.10`) from within the internal virtual network may result in connection timeouts due to missing outbound NAT reflection rules. Using the internal gateway (`192.168.50.1`) ensures a direct layer-2 transfer (~500MB/s).

### 6.2 Create and Configure the VM in Proxmox

Create the VM with these settings:

| **Setting**         | **Value**                                      |
| ------------------- | ---------------------------------------------- |
| **Machine**         | q35                                            |
| **BIOS**            | SeaBIOS                                        |
| **SCSI Controller** | VirtIO SCSI single                             |
| **OS Disk (scsi0)** | 200 GiB on LVM thin (`vm-storage`), IO thread  |
| **CPU**             | 8 cores, 1 socket, type `host`                 |
| **Memory**          | 16 GiB minimum (ballooning disabled)           |
| **Network**         | VirtIO, bridge `vmbr1`                         |
| **CD-ROM (ide2)**   | `sno-installer.iso`                            |
| **QEMU Agent**      | Disabled (not included in RHCOS)               |
| **NUMA**            | Disabled (single-socket host)                  |

### 6.3 Boot Procedure

> [!CAUTION]
> **Critical: ISO Ejection During Reboot**
> The bootstrap-in-place flow ends with `install-to-disk.service` writing the permanent OS to `/dev/sda` and scheduling a reboot with a 60-second countdown. During this window, you **must** eject the ISO so the VM boots from disk on the next reboot. If the ISO is still attached, the VM will boot the ISO again and overwrite the permanent OS.

**Procedure:**

1. **Set boot order** to CD-ROM (ide2) first, then hard disk (scsi0):
   ```bash
   VM_ID=123  # replace with the lab VM ID
   qm set "$VM_ID" --boot order='ide2;scsi0;net0'
   ```

2. **Start the VM.** It boots from the ISO into RAM.

3. **Watch the Proxmox console and the node journal.** The full bootstrap runs in the live ISO environment (~5-10 minutes). Watch for:
   ```bash
   ssh core@192.168.50.20
   journalctl -b -f -u bootkube.service -u install-to-disk.service
   ```

4. **Wait for the install-to-disk completion message:**
   ```text
   Bootstrap completed, server is going to reboot.
   The system will reboot at <time>!
   ```

5. **Immediately eject the ISO** (you have 60 seconds):
   ```bash
   VM_ID=123  # use the same lab VM ID as above
   qm set "$VM_ID" --ide2 none,media=cdrom
   ```

6. **The VM reboots from disk.** Ignition applies the full machine config. The MCD firstboot service runs, pulls images, and the node reboots once more.

7. **The permanent control plane starts.** The bootstrap etcd member is removed, operators deploy, and the cluster stabilizes.

> [!TIP]
> **No manual boot order flipping needed**
> Unlike the `--dest-ignition` approach, with `--live-ignition` the entire bootstrap runs in the live ISO. You only need to eject the ISO once during the 60-second reboot countdown. The node handles everything else automatically.

### 6.4 Clean Rebuild Procedure

If you need to start fresh, run this as root on the Proxmox host. It permanently deletes the selected VM disk. Set `VM_ID` to the lab VM, verify the resulting LV path with `lvs`, and do not run it against a VM that must be retained. The storage names `vm-storage` and `vm-thin`, bridge `vmbr1`, and ISO store `local` are specific to this Proxmox host and must be replaced on a different installation.

```bash
VM_ID=123  # replace with the lab VM ID

# Stop the VM
qm stop "$VM_ID"

# Verify and then delete the lab VM's LVM disk.
lvs "vm-storage/vm-${VM_ID}-disk-0"
lvremove -f "vm-storage/vm-${VM_ID}-disk-0"
lvcreate -V 200G -T vm-storage/vm-thin -n "vm-${VM_ID}-disk-0"

# Re-attach the ISO
qm set "$VM_ID" --ide2 local:iso/sno-installer.iso,media=cdrom
qm set "$VM_ID" --boot order='ide2;scsi0;net0'

# Clear any stale DHCP leases if the MAC changed
systemctl stop dnsmasq
nano /var/lib/misc/dnsmasq.leases  # remove stale entries
systemctl start dnsmasq
```

Then repeat from step 6.3.

---

## 7. Step 6: Monitoring the Installation

### 7.1 Enable Logging (Before Starting the VM)

**On the Proxmox host**: watch outbound NAT traffic:

```bash
iptables -t nat -I POSTROUTING 1 -s 192.168.50.0/24 -o vmbr0 -j LOG --log-prefix "NAT-EGRESS: "
journalctl -k -f | grep "NAT-EGRESS"
```

**On the BIND DNS VM (192.168.50.10)**: watch DNS queries:

```bash
sudo rndc querylog on
sudo journalctl -u named -f
```

### 7.2 Wait for Bootstrap and Install

From the Admin Workstation / jump VM, run both stages sequentially:

```bash
cd ~/sno-install

# Stage 1: Bootstrap (API comes up, bootstrap control plane hands off to permanent)
openshift-install wait-for bootstrap-complete --dir . --log-level=debug

# Stage 2: Install complete (all operators stabilize)
openshift-install wait-for install-complete --dir . --log-level=debug
```

Use `--log-level=debug` for maximum visibility during troubleshooting.

**Expected progression on the jump VM:**

1. `no route to host` → node is still booting
2. `connection refused` → node is up, API server not ready yet
3. `API v1.x.x up` → API is live, bootstrap in progress
4. `Bootstrap status: complete` → bootstrap etcd member being removed
5. `Bootstrap is complete` → move to `wait-for install-complete`
6. `Working towards 4.21.4: X of 971 done` → operators deploying
7. `Install complete!` → cluster is ready

### 7.3 On-Node Debugging (SSH)

If you need to inspect the node during bootstrap:

```bash
ssh core@192.168.50.20

# Watch all bootstrap services (live ISO phase)
journalctl -b -f -u bootkube.service -u install-to-disk.service

# Watch all bootstrap services (permanent OS phase)
journalctl -b -f -u release-image.service -u bootkube.service -u node-image-pull.service

# Watch MCD firstboot (permanent OS phase)
systemctl status machine-config-daemon-firstboot.service

# Watch kubelet
journalctl -b -u kubelet -f

# Check running containers
sudo crictl ps
sudo crictl ps | wc -l

# Test disk I/O performance
sudo dd if=/dev/zero of=/tmp/testfile bs=4k count=1000 oflag=dsync
sudo rm /tmp/testfile
```

---

## 8. Step 7: Cluster Access and Validation

### 8.1 Export Credentials

```bash
cd ~/sno-install
export KUBECONFIG="$PWD/auth/kubeconfig"
cat auth/kubeadmin-password
```

### 8.2 Login and Verify Node

```bash
oc login -u kubeadmin https://api.lab.example.internal:6443
oc get nodes -o wide
```

Enter the password from `auth/kubeadmin-password` at the prompt. Avoid putting it directly on the command line, where it can be exposed through process listings or shell history.

Expected output: a single node in `Ready` state with `control-plane,master,worker` roles.

### 8.3 Cluster Health

```bash
oc get clusterversion
oc get clusteroperators
```

All cluster operators should show `Available=True`, `Progressing=False`, `Degraded=False`.

### 8.4 Web Console

- URL: `https://console-openshift-console.apps.lab.example.internal`
- Login with kubeadmin credentials.

### 8.5 Approve Pending CSRs (if any)

```bash
oc get csr

# After checking that the pending requests belong to this node:
oc get csr --no-headers | awk '$5 == "Pending" {print $1}' | \
  xargs -r oc adm certificate approve
```

---

## 9. Architecture Diagram

```text
                               ┌──────────────┐
                               │   Internet   │
                               └──────┬───────┘
                                      │
                               ┌──────┴───────┐
                               │ vmbr0 (Pub)  │
                               └──────┬───────┘
                                      │
     ┌────────────────────────────────┼──────────────────────────────┐
     │                 Proxmox Host (192.168.50.1)                   │
     │                                                               │
     │  tailscale0 ←── VPN admin access (100.64.0.0/10)              │
     │  dnsmasq    ←── DHCP for vmbr1                                │
     │  iptables   ←── NAT masquerade (vmbr1 → vmbr0)                │
     │                                                               │
     │                 ┌────────────────────┐                        │
     │                 │  vmbr1 (Private)   │                        │
     │                 │  192.168.50.0/24   │                        │
     │                 └──┬────────┬─────┬──┘                        │
     └────────────────────┼────────┼─────┼───────────────────────────┘
                          │        │     │
          ┌───────────────┘        │     └────────────────┐
          │                        │                      │
   ┌──────┴───────────┐   ┌────────┴──────────┐   ┌───────┴────────────┐
   │ BIND DNS         │   │ SNO Cluster       │   │ Jump VM            │
   │ 192.168.50.10    │   │ 192.168.50.20     │   │ 192.168.50.101     │
   │                  │   │                   │   │                    │
   │ Zones:           │   │ OCP 4.21          │   │ oc CLI             │
   │ example.internal │   │ api.* and *.apps.*│   │ openshift-install  │
   │                  │   │ Disk: LVM thin    │   │                    │
   └──────────────────┘   └───────────────────┘   └────────────────────┘
```

---

## 10. Troubleshooting Reference

| **Issue**                          | **Symptoms**                                                                                                                              | **Fix**                                                                                                                                                                |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Disk I/O too slow for etcd         | Bootstrap kube-apiserver startup probes fail with HTTP 500, `poststarthook/rbac/bootstrap-roles failed`. `dd oflag=dsync` shows < 10 MB/s | Move VM disk to LVM thin storage. Do not use qcow2-on-directory.                                                                                                       |
| `install-to-disk` busy partitions  | `Error: checking for exclusive access to /dev/sda: found busy partitions: /dev/sda3 mounted on /boot, /dev/sda4 mounted on /sysroot`     | ISO was built with `--dest-ignition`. Rebuild with `--live-ignition` so bootstrap runs in RAM.                                                                         |
| ISO overwrites permanent install   | After `install-to-disk` completes and reboots, the ISO boots again and `coreos-installer` rewrites the disk                               | Set `VM_ID` to the lab VM and eject the ISO during the 60-second reboot countdown: `qm set "$VM_ID" --ide2 none,media=cdrom`                                          |
| MCD firstboot service missing      | `machine-config-daemon-firstboot.service` not found, `/etc/kubernetes/manifests/` empty or missing                                        | The permanent ignition was not applied. Usually caused by `--dest-ignition` or ISO rebooting over the permanent install. Rebuild with `--live-ignition` and eject ISO. |
| Ignition skipped (first-boot lost) | Node idle, no bootstrap services, logs show `ConditionFirstBoot=true` skipped                                                             | Only applies to `--dest-ignition` flow. With `--live-ignition`, this is not an issue. If using dest-ignition: wipe disk, boot ISO once, immediately flip boot order.   |
| DHCP gives wrong IP                | Node gets IP from dynamic range instead of static reservation                                                                             | Clear stale leases in `/var/lib/misc/dnsmasq.leases`, restart dnsmasq.                                                                                                 |
| Bootstrap timeout                  | `wait-for bootstrap-complete` times out at 45 minutes                                                                                     | Check VM console, DNS resolution, network connectivity, disk I/O performance, ignition logs.                                                                           |
| API not reachable                  | `oc login` fails / `no route to host`                                                                                                     | Verify DNS for `api.lab.example.internal`, check firewall ports 6443/22623.                                                                                    |
| `node-image-pull.service` failed   | `ref coreos/node-image already exists`                                                                                                    | This was harmless in the recorded run because the image was present and installation continued. Confirm later service and installer progress before ignoring it.       |
| Node NotReady                      | `oc get nodes` shows NotReady                                                                                                             | Check `oc describe node`, `oc get clusteroperators`, approve pending CSRs.                                                                                             |
| etcd operator retrying             | `Error getting etcd operator singleton, retrying: server unable to return response in time`                                               | It occurred transiently during this deployment. Watch operator state and storage latency; investigate if it persists instead of treating every occurrence as normal.    |

---

## 11. Official References & Documentation Sources

* **[1] Installing a Cluster on a Single Node (SNO): Overview**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index

* **[2] Networking and DNS Requirements for SNO**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index#install-sno-networking-requirements_installing-on-a-single-node

* **[3] Generating the Single-Node Ignition Configuration**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index#install-sno-generating-the-ignition-config-files-manually_installing-on-a-single-node

* **[4] Customizing the Live ISO (Ignition Embedding)**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html-single/installing_on_a_single_node/index#install-sno-installing-sno-with-the-coreos-installer_installing-on-a-single-node

* **[5] Red Hat Hybrid Cloud Console: Pull Secret Management**
  https://console.redhat.com/openshift/install/pull-secret
