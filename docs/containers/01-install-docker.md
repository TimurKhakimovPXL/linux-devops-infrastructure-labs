> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 1: Install Docker on Debian or Ubuntu

## Goal

Install Docker Engine on a fresh Debian or Ubuntu VM, then give a regular user permission to run containers without `sudo`.

## 1. Create the VM

Use any convenient hypervisor. These settings are enough for the lab:

- **OS:** Ubuntu Server 24.04 LTS or Debian 13  
- **vCPUs:** 2  
- **RAM:** 4 GB  
- **Disk:** 20 GB  
- **Installation:** Minimal server installation  
- **Boot mode:** UEFI  
- **Networking:** NAT or Bridged  

Enable *OpenSSH Server* during installation if you plan to connect remotely. When the installation is finished, shut down the VM and take a snapshot named `clean-install`.

## 2. Update the System

Run the installation commands on the target VM as the account created during OS installation. It must have `sudo` access.

```bash
sudo apt update && sudo apt upgrade -y
```

## 3. Install Docker Engine

Docker publishes separate APT repositories for Debian and Ubuntu. The following block reads the target VM's `/etc/os-release` and selects the matching repository. It stops instead of treating another Debian-derived distribution as interchangeable.

```bash
sudo apt install -y ca-certificates curl

. /etc/os-release
case "$ID" in
  debian|ubuntu) docker_distribution="$ID" ;;
  *)
    echo "Unsupported distribution: $ID" >&2
    exit 1
    ;;
esac

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL \
  "https://download.docker.com/linux/${docker_distribution}/gpg" \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_distribution} ${VERSION_CODENAME} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

This installs the current packages from Docker's stable channel. To reproduce an older lab at exact package versions, record the values from `apt list --installed 'docker*' containerd.io` and use version-qualified package names; this document does not invent a historical version pin.

## 4. Create a Docker User

Add the lab user to the `docker` group so Docker can be used without `sudo`. Membership in this group is effectively root access, so grant it only to trusted users.

```bash
sudo adduser labuser
sudo usermod -aG docker labuser
id labuser
```

Group membership is read when a login session starts. Log out and back in as `labuser`, or open a fresh SSH session, before testing:

```bash
docker run --rm hello-world
docker run -it --rm debian /bin/bash
```
- **Docker Engine Installation (Ubuntu):** [https://docs.docker.com/engine/install/ubuntu/](https://docs.docker.com/engine/install/ubuntu/)

- **Docker Engine Installation (Debian):** [https://docs.docker.com/engine/install/debian/](https://docs.docker.com/engine/install/debian/)
    
- **Docker Post-installation Steps (User Group Setup):** [https://docs.docker.com/engine/install/linux-postinstall/](https://docs.docker.com/engine/install/linux-postinstall/)
    
- **Docker Security (Daemon Attack Surface):** [https://docs.docker.com/engine/security/](https://docs.docker.com/engine/security/)
