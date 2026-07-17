> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Rootful Docker and Rootless Podman: Security Comparison

## Goal

Compare the privilege boundaries of rootful Docker and rootless Podman. This lab focuses on namespaces and host access, not performance.

# 1. Rootful Docker's trust boundary

In its default rootful configuration, Docker uses a privileged daemon (`dockerd`) that:

- runs as host root;
- controls container operations;
- exposes its API through `/var/run/docker.sock`; and
- can grant host-level access to anyone who controls that socket.

### Main risks

1. **The Docker socket is root-equivalent.** A process with unrestricted access to it can mount the host filesystem or start a privileged container.

2. **User namespaces are not enabled by default.** Without user-namespace remapping, UID 0 in the container is also UID 0 on the host. Namespace isolation still applies, but a successful breakout reaches host root.

3. **The daemon is privileged.** A daemon vulnerability has a larger impact because `dockerd` runs as root.

4. **Image handling happens with elevated privileges.** A flaw in image parsing or extraction can therefore affect the host.

---

# 2. Why Podman Is Safer

Rootless Podman changes that trust boundary. It is:

- **daemonless**  
- uses **per-container system calls**  
- integrates with **systemd**  
- supports **fully rootless operation**

### Practical advantages

- There is no long-running privileged daemon.
- The user does not need access to a root-owned control socket.
- Images can be unpacked as an unprivileged user.
- Rootless containers use a user namespace by default.

These controls reduce the impact of a container escape. They do not make an untrusted container harmless: it can still access anything available to the host user who launched it.

---

# 3. Rootless Podman Security Model

In rootless mode:

- Container `root` maps to an unprivileged host UID, such as 100000.
- Container storage lives under the user's home directory rather than `/var/lib/containers`.
- Networking uses a user-space helper such as `slirp4netns` or `pasta`.
- Operations that require real host privileges remain unavailable.

If the container is compromised, the attacker is limited to the permissions of the host user unless another vulnerability or unsafe configuration provides a path to higher privileges.

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

## 5. Practical demonstration

```console
labuser@lab-host:~$ sudo docker run -v /:/mnt -it alpine sh
/ # hostname
394ada1cc8f8

/ # ls /mnt
Docker      boot        etc         init        lib64       media
opt         proc        root        run         sbin        srv
sys         tmp         usr         var         bin         dev
home        lib         lost+found  mnt

# Alpine has neither apt nor sudo
/ # apt
sh: apt: not found

# Enter the bind-mounted host filesystem
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
The `-v /:/mnt` option exposes the host filesystem inside the container. Running `chroot /mnt` then uses the host filesystem as `/`, including its binaries and account database. Switching to `labuser` confirms that the process is reading the host's account files. The example succeeds because the operator explicitly mounted `/`; it demonstrates why access to Docker is root-equivalent, not a generic escape from an otherwise isolated container.

## References

- **Docker Daemon Socket Security (`/var/run/docker.sock`):** [https://docs.docker.com/engine/security/protect-access/](https://docs.docker.com/engine/security/protect-access/)
    
- **Podman Architecture (Daemonless & Rootless):** [https://docs.podman.io/en/latest/Introduction.html](https://docs.podman.io/en/latest/Introduction.html)

- [Privilege Escalation using Docker Container | by Bishal Chapagain | InfoSec Write-ups](https://infosecwriteups.com/privilege-escalation-using-docker-container-e9110713936b)
