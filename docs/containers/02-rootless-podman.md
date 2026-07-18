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

Example entries:

```text
labuser:100000:65536
```

```bash
grep labuser /etc/subuid
grep labuser /etc/subgid
```

If both entries are missing, choose an unused range and add it as an administrator. The range below is the one used in this isolated lab; check the existing files before reusing it on a shared host.

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 labuser
```

## 3. Test Rootless Podman

Open a normal console or SSH login as `labuser`. Do not use `sudo podman`, because that tests rootful Podman instead.

```bash
podman run --rm hello-world
podman run -it --rm debian bash
```

## 4. Avoid the systemd warning caused by `su`

A plain `su` or `sudo -iu` shell may not have the user systemd manager or `XDG_RUNTIME_DIR` that rootless services need. Use a console or SSH login when testing `systemctl --user`. For services that must start at boot and survive logout, enable lingering as an administrator with `sudo loginctl enable-linger labuser`.

## 5. Container Isolation: Default vs. Private User Namespaces

By default, rootless containers started by one user share that user's namespace. This protects the host, but it provides less separation between those containers.

```text
labuser userns
 ├── container A (same UID map)
 └── container B (same UID map)
# Shared namespace: less separation between this user's containers
```

### Give each container its own mapping

Use `--userns=auto` to allocate a separate UID/GID mapping for each container:

```bash
podman run --rm --userns=auto -it alpine sh
```

```text
labuser user
 ├── container A (private namespace)
 ├── container B (private namespace)
 └── container C (private namespace)
```

Podman allocates a different subordinate-ID block for each `--userns=auto` container. This improves separation between the containers, but each process still has the permissions of `labuser` for host resources explicitly made available to it.

- **Podman Rootless Guide (Official Tutorial):** [https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)
    
- **Understanding `slirp4netns` (Rootless Networking):** [https://github.com/rootless-containers/slirp4netns](https://github.com/rootless-containers/slirp4netns)
    
- **User Namespaces (`subuid`/`subgid` explanation):** [https://man7.org/linux/man-pages/man7/user_namespaces.7.html](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)
