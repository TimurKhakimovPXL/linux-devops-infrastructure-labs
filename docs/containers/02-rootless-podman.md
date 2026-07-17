> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

# Target 2  Configure Podman in Rootless Mode

## Goal
Install Podman and configure it so a **non-privileged user** can run containers securely in rootless mode.  
Rootless Podman reduces host risk by ensuring container “root” is mapped to an unprivileged host UID.

---

## 1. Install Podman and Dependencies

```bash
sudo apt update
sudo apt install -y podman uidmap slirp4netns
```

## 2. Ensure Subordinate UID/GID Ranges Exist

Podman needs a UID/GID range in `/etc/subuid` and `/etc/subgid` to map container identities.

On modern Ubuntu/Debian, `adduser` **usually** creates these lines automatically:

```bash
##Example mapping
labuser:100000:65536

##Verify:
grep labuser /etc/subuid 
grep labuser /etc/subgid

##If missing, assign manually:

sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 labuser
```

## 3. Test Rootless Podman
```bash
##Login
su - labuser

##Run container without sudo
podman run --rm hello-world
podman run -it --rm debian bash
```

## 4. Systemd warning when using su

A warning may appear stating ``Falling back to cgroupfs``
This is due to using ``su`` which does not create an user-level systemd session
Solution:
```bash
sudo -iu labuser
## Opens a real login session handled by systemd + PAM
## Or login via SSH
```

## 5. Container Isolation: Default vs. Private User Namespaces

By default, **rootless containers started by the same user share one user namespace**.  
This protects the host but allows potential lateral movement between containers.

```bash
labuser userns
 ├── container A (same UID map)
 └── container B (same UID map)
## Shared namespace --> Shared attack surface
```

#### **Improving isolation: Rootless --userns=auto**

To give each container its **own** UID/GID mapping:
```bash
podman run --userns=auto -it alpine sh

##Podman allocates a unique block of subordinate IDs for each container, isolating them from each other.
labuser user
 ├── container A (private namespace)
 ├── container B (private namespace)
 └── container C (private namespace)
```

- **Podman Rootless Guide (Official Tutorial):** [https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
    
- **Understanding `slirp4netns` (Rootless Networking):** [https://github.com/rootless-containers/slirp4netns](https://github.com/rootless-containers/slirp4netns)
    
- **User Namespaces (`subuid`/`subgid` explanation):** [https://man7.org/linux/man-pages/man7/user_namespaces.7.html](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)