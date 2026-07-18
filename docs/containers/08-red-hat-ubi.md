> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Red Hat Universal Base Image Reference Notes

This page is background material rather than a completed lab. It records where UBI fits among the OCI images discussed in the previous sections without claiming that a UBI-based image was built or tested here.

## What UBI is

Red Hat Universal Base Images are OCI-compliant container base images built from a redistributable subset of Red Hat Enterprise Linux user-space content. They can be built and run on Red Hat and non-Red Hat container platforms.

UBI images and their public package repositories receive Red Hat updates. Their content lifecycle follows the corresponding RHEL major release, but Red Hat support still depends on an appropriate subscription and a supported Red Hat stack.

The current images are listed in the Red Hat Ecosystem Catalog. Red Hat publishes them through both the authenticated `registry.redhat.io` registry and the unauthenticated `registry.access.redhat.com` registry.

## Base-image variants

The four UBI base-image variants serve different runtime needs:

| Variant | UBI 9 image | Package tooling | Intended use |
|---|---|---|---|
| Standard | `ubi9/ubi` | Full DNF | General-purpose builds where normal RPM tooling is useful |
| Minimal | `ubi9/ubi-minimal` | `microdnf` | Smaller application images that still need package installation during the build |
| Micro | `ubi9/ubi-micro` | None | Very small final images whose filesystem is prepared outside the final image |
| Init | `ubi9/ubi-init` | Full DNF | Containers that specifically need `systemd` as their init process |

### Standard

Standard UBI is the least restrictive starting point of the four. It includes a shell and the full DNF stack, which makes repository queries and package installation straightforward. The trade-off is a larger base and more installed tooling than Minimal or Micro.

### Minimal

UBI Minimal keeps RPM support but replaces full DNF with `microdnf`. It leaves out several utilities and runtime components found in Standard, so a build should check that every required shell tool and library is present instead of assuming Standard and Minimal are interchangeable.

### Micro

UBI Micro omits the package manager and its dependencies. Packages cannot be installed by running DNF inside the final image. Red Hat documents preparing the mounted image filesystem with Buildah, and the catalog also identifies multi-stage builds as an option.

This reduces the final filesystem and package-manager surface, but it also removes interactive troubleshooting tools. The required runtime files, trust store, users, and permissions have to be prepared during the build.

### Init

UBI Init adds the configuration needed to run `systemd` as PID 1. It is meant for the narrower case where a container needs an init system or multiple systemd-managed processes. A single-process application normally does not need it.

## Packages and repositories

Standard and Minimal are configured for the public UBI BaseOS and AppStream repositories. Packages installed from those repositories are the redistributable UBI subset, not the complete set of RHEL packages.

Adding packages from subscription-only RHEL repositories changes the licensing and redistribution position of the resulting image. A package being available to a subscribed RHEL host does not by itself make that package UBI content.

For a disconnected build, access to the UBI content delivery network must be mirrored or allowlisted. The public repositories are still an external build dependency, so reproducible builds need controlled repository content as well as a pinned base-image digest.

## Redistribution and licensing boundary

The UBI EULA permits redistribution of the UBI images and UBI-covered RPM content. Application code and third-party packages layered on top keep their own licences and terms.

Only Red Hat content designated as UBI content receives the UBI redistribution terms. Non-UBI RHEL RPMs are governed separately, so they should not be added to an image intended for unrestricted redistribution without checking the applicable agreement.

The Ecosystem Catalog and the UBI repositories are the practical sources for identifying covered Red Hat content. The current UBI EULA remains the controlling source for the terms.

## Relationship to the image in document 06

[Document 06](06-build-oci-webserver-image.md) builds the Flask application from `docker.io/library/python:3.12-slim-bookworm`. That is a Debian-based Python image, not a UBI image.

OCI compatibility lets Podman build and run either image format, but it does not make their user space interchangeable. Replacing the `FROM` line with UBI would also require reviewing Python availability, package commands, filesystem paths, users, certificates, and dependency installation.

A deliberate UBI version of that application could start from a UBI Python runtime image or add Python to an appropriate UBI base variant. It would be a separate build decision and would need its own test evidence. No such result is claimed in this repository.

The reproducibility limits from document 06 still apply: a mutable base tag and dependencies resolved from live repositories do not produce a bit-for-bit rebuild. A reviewed image digest and locked application dependencies would be needed regardless of whether the base is Debian or UBI.

## Sources

- [Red Hat Enterprise Linux 9: Types of container images](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/assembly_types-of-container-images_building-running-and-managing-containers)
- [Red Hat Enterprise Linux 9: Adding software to a UBI container](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/assembly_adding-software-to-a-ubi-container_building-running-and-managing-containers)
- [Red Hat: UBI images, repositories, packages, and source code](https://access.redhat.com/articles/4238681)
- [Red Hat Developer: Universal Base Images FAQ](https://developers.redhat.com/articles/ubi-faq)
- [Red Hat Universal Base Image EULA](https://www.redhat.com/en/about/eulas)
