> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 5: Understanding the OCI Standards

## Goal

Explain the Open Container Initiative (OCI) specifications and how they let tools such as Podman, Docker, containerd, and registries work together.

# 1. What Is OCI?

The **Open Container Initiative (OCI)** maintains open, vendor-neutral specifications for:

- **image format:** how container images are structured;
- **runtime behavior:** how a container process is created and isolated; and
- **distribution:** how clients push images to and pull images from registries.

These shared formats and interfaces prevent each container engine and registry from becoming its own incompatible ecosystem.

---

# 2. Why OCI Exists 

Early container tools used incompatible image formats and registry interfaces. OCI gave engines and registries a common set of specifications now used across Podman, Docker, CRI-O, containerd, Kubernetes, and other projects.

In practice, an OCI image built with one engine can usually be pushed to a standard registry and run by another engine. Platform, architecture, and runtime requirements still have to match, so “build once, run anywhere” is a useful goal rather than an absolute guarantee.

---

# 3. The three OCI specifications

### OCI Image Specification

Defines the image manifest, configuration metadata, filesystem layers, and content-addressable layout.

- Image layers
- Configuration metadata
- Filesystem layout
- Manifest format

A `Containerfile` can produce an OCI-compatible image that both Podman and Docker understand.

---

### OCI Runtime Specification

Defines how a container process is launched, including its root filesystem, namespaces, cgroups, capabilities, and seccomp settings.

- **Namespaces** control what the process can see.
- **Cgroups** limit and account for resource usage.
- **Seccomp** filters system calls.
- **Capabilities** split root privileges into smaller units.
- **rootfs** defines the filesystem presented as `/`.

Low-level runtimes that implement this specification include `runc` and `crun`.

---

### OCI Distribution Specification

Defines the registry API used to transfer images and related artifacts:

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

For example, an image pushed to Quay with Podman can be pulled with Docker, provided both clients support its manifest and platform.

---

# 4. Why OCI matters

Podman and Docker understand the same standard image formats. An image built with:

```bash
podman build -t myapp .
```

can be tagged, pushed to an OCI-compatible registry, and pulled by another compatible engine. The practical benefits are portable build files, a choice of registries and runtimes, and images that can be deployed through Kubernetes.

## References

- **Open Container Initiative (Main Site):** [https://opencontainers.org/](https://opencontainers.org/)
    
- **OCI Image Specification:** [https://github.com/opencontainers/image-spec](https://github.com/opencontainers/image-spec)
    
- **OCI Runtime Specification:** [https://github.com/opencontainers/runtime-spec](https://github.com/opencontainers/runtime-spec)
    
- **`crun` (High performance OCI runtime):** [https://github.com/containers/crun](https://github.com/containers/crun)
