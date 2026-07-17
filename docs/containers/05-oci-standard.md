> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

# Target 5 — Understanding the OCI Standard

## Goal
Explain the Open Container Initiative (OCI) standard and why it matters when building and running containers with Podman and Docker.  
This target focuses on practical implications relevant to your project: image format compatibility, tooling interoperability, and secure operations.

---

# 1. What Is OCI?

The **Open Container Initiative (OCI)** defines open, vendor-neutral specifications for:

- **Image Format**: how container images are structured  
- **Runtime Specification**: how a container process is created and isolated  
- **Distribution Specification**: how images are pushed/pulled from registries  

OCI solves the fragmentation that existed between early container technologies by standardizing the container ecosystem.

---

# 2. Why OCI Exists 

Before OCI:

- Docker images worked only with Docker  
- Other runtimes had incompatible formats  
- No standard for registries, layers, or metadata  

After OCI, all major engines use the same specifications:

- Podman  
- Docker  
- CRI-O  
- containerd  
- Kubernetes  

**Meaning: you can build an image once and run it anywhere.**

---

# 3. The Three OCI Specifications (Concise)

### 1) **OCI Image Specification**
Defines:
- Image layers  
- Config metadata  
- Filesystem layout  
- Manifest format  

Example:  
The `Containerfile` produces an OCI-compliant image. Podman and Docker can both run it.

---

### 2) **OCI Runtime Specification**
Defines how a container process is launched using Linux primitives:

- namespaces  --> "What can I see?"
- cgroups   --> How much can I use?
- seccomp  --> Where do I live ?
- capabilities  --> What powers do I have ?
- rootfs mount  --> Who can I call? (Secure Computing Mode)
	--> Acts as a firewall for System Calls to the Linux Kernel

Tools that implement this spec:
	- **runc** (used by Docker & containerd)  
	- **crun** (default in Podman, faster & safer)  

---

### 3) **OCI Distribution Specification**
Defines how images are transferred:

- Push/pull  
- Tagging  
- Registry API  
- Content-addressable layers (SHA256)  
- Manifest lists (multi-arch images)  

Registries implementing this spec:
- Quay.io  
- Docker Hub  
- GHCR  
- Harbor  

This ensures you can push an image to Quay and pull it with Podman or Docker.

---

# 4. Why OCI Matters 

###  Podman and Docker share the same image format  
Everything you build with:

```bash
podman build -t myapp .
```
is pullable by `docker pull myapp`
1) Containerfile is portable
2) Registries are independent of engines
3) Kubernetes compatible

- **Open Container Initiative (Main Site):** [https://opencontainers.org/](https://opencontainers.org/)
    
- **OCI Image Specification:** [https://github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)
    
- **OCI Runtime Specification:** [https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
    
- **`crun` (High performance OCI runtime):** [https://github.com/containers/crun](https://github.com/containers/crun)