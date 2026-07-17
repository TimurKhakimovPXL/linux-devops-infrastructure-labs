> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

# Target 1 — Install Docker on Debian/Ubuntu

## Goal
Install Docker Engine on a fresh Debian/Ubuntu virtual machine using best practices.  
The installation must work for a non-privileged user who can run containers without sudo.

## 1. Create the VM

Use any hypervisor (VirtualBox, VMware, Proxmox).  
The following settings are recommended:

- **OS:** Ubuntu Server 24.04 LTS or Debian 13  
- **vCPUs:** 2  
- **RAM:** 4 GB  
- **Disk:** 20 GB  
- **Installation:** Minimal server installation  
- **Boot mode:** UEFI  
- **Networking:** NAT or Bridged  

During installation:

- Enable *OpenSSH Server* if you plan to connect remotely.

After installation:

- Shut down the VM.
- Take a snapshot named `clean-install`.

## 2. Update the System

```bash
sudo apt update && sudo apt upgrade -y
```

## 3. Install/Enable Docker Engine
```bash
##Install
sudo apt install -y ca-certificates curl gnupg lsb-release

##Add Docker's official GPG key
sudo mkdir -p /etc/apt/keyrings
sudo chmod 755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | 
sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

##Add the Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

##Update package index and install Docker
sudo apt update
sudo apt install -y 
docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

##Note
For Debian use:
curl -fsSL https://download.docker.com/linux/debian/gpg | 
sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
For other distros refer to official documentation

##Enabling
sudo systemctl enable --now docker
##Verify
sudo docker run --rm hello-world
```

## 4. Create a Non-Privileged User for Docker

Running containers directly as root is unsafe.  
Instead, assign Docker privileges through group membership.

```bash
##Create the user
sudo adduser labuser
##Add the user to the docker group
sudo usermod -aG docker labuser
##Verify group membership
id labuser
##Test Docker as the user
su - labuser
docker run --rm hello-world
docker run -it --rm debian /bin/bash
```
- **Docker Engine Installation (Ubuntu):** [https://docs.docker.com/engine/install/ubuntu/](https://docs.docker.com/engine/install/ubuntu/)
    
- **Docker Post-installation Steps (User Group Setup):** [https://docs.docker.com/engine/install/linux-postinstall/](https://docs.docker.com/engine/install/linux-postinstall/)
    
- **Docker Security (Daemon Attack Surface):** [https://docs.docker.com/engine/security/](https://docs.docker.com/engine/security/)