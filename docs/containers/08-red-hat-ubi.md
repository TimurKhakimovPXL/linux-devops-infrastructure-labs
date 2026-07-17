> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Red Hat Universal Base Images

Red Hat publishes four main Universal Base Image (UBI) variants:

1. **Standard:** the general-purpose image. It includes DNF and balances image size with package availability.
2. **Minimal:** a smaller image with `microdnf` instead of the full DNF stack.
3. **Micro:** the smallest variant. It has no package manager and is intended for applications that bring only their runtime dependencies.
4. **Init:** includes `systemd` for workloads that need an init system inside the container.

## Adding software to UBI Micro

Because UBI Micro has no package manager, packages cannot be installed in the final image directly. Use a multi-stage build: install the required files in a UBI builder stage, then copy the prepared filesystem into the Micro stage. This keeps the final image small without giving up package-based installation during the build.

## Reference

- [Adding software to a UBI container](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/building_running_and_managing_containers/assembly_adding-software-to-a-ubi-container_building-running-and-managing-containers#proc_using-the-ubi-micro-images_assembly_adding-software-to-a-ubi-container)
