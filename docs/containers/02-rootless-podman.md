> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 2: Configure Rootless Podman

## Goal

Install Podman for an unprivileged user. In rootless mode, the container's `root` account maps to an unprivileged host UID instead of the host's real root account.

---

## 1. Install Podman and Dependencies

```bash
sudo apt update
sudo apt install -y podman uidmap slirp4netns
```

## 2. Check the subordinate UID and GID ranges

Podman needs a UID/GID range in `/etc/subuid` and `/etc/subgid` to map container identities.

Current Debian and Ubuntu releases normally add these mappings when the user is created. Check before adding them manually:

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

## 4. Avoid the systemd warning caused by `su`

A plain `su` session may produce a `Falling back to cgroupfs` warning because it does not create a user systemd session. Use a PAM-backed login or SSH when systemd integration is required:
```bash
sudo -iu labuser
## Opens a real login session handled by systemd + PAM
## Or login via SSH
```

## 5. Container Isolation: Default vs. Private User Namespaces

By default, rootless containers started by one user share that user's namespace. This protects the host, but it provides less separation between those containers.

```bash
labuser userns
 ├── container A (same UID map)
 └── container B (same UID map)
## Shared namespace --> Shared attack surface
```

### Give each container its own mapping

Use `--userns=auto` to allocate a separate UID/GID mapping for each container:
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
