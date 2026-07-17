# Linux, DevOps and OpenShift Infrastructure Labs

A technical portfolio of hands-on infrastructure work completed during a DevOps and infrastructure engineering internship.

The repository follows the progression of the internship: Linux containers and automation first, followed by a complete OpenShift platform lab with GitLab, GitOps, internal PKI and secured application delivery.

## Highlights

- Compared rootful Docker with rootless Podman and demonstrated the security impact of privileged container access.
- Built and published OCI-compatible application images.
- Managed rootless containers through Podman Quadlet and systemd.
- Automated repeatable deployments with Ansible, Nginx and TLS.
- Installed Single Node OpenShift on Proxmox and diagnosed storage, DNS and bootstrap failures.
- Migrated GitLab EE between infrastructures using application-level backup and restore.
- Integrated private GitLab with OpenShift GitOps and Argo CD.
- Built an internal PKI with cert-manager and integrated GitLab as an OpenShift identity provider.
- Deployed a hardened static website through an App-of-Apps GitOps workflow.

## Repository structure

```text
docs/
├── containers/
│   ├── 01-install-docker.md
│   ├── 02-rootless-podman.md
│   ├── 03-docker-vs-rootless-podman.md
│   ├── 04-ansible-docker-installation.md
│   ├── 05-oci-standard.md
│   ├── 06-build-oci-webserver-image.md
│   ├── 07-rootless-quadlet-nginx-ansible.md
│   └── 08-red-hat-ubi.md
└── openshift-platform/
    ├── 00-kubernetes-openshift-basics.md
    ├── 01-single-node-openshift-on-proxmox.md
    ├── 02-gitlab-ee-migration-to-rhel.md
    ├── 03-openshift-gitops-argocd.md
    ├── 04-pki-cert-manager-gitlab-oauth.md
    └── 05-static-website-via-gitops.md
```

## Learning path

### 1. Containers and Linux automation

The first track covers container fundamentals, OCI portability, rootless Podman, systemd integration, reverse proxying, TLS and Ansible automation.

Start with [`docs/containers/01-install-docker.md`](docs/containers/01-install-docker.md).

### 2. OpenShift platform engineering

The second track documents the construction of a Single Node OpenShift platform and its supporting services: DNS, storage, GitLab, Argo CD, cert-manager, OAuth and re-encrypt Routes.

Start with [`docs/openshift-platform/01-single-node-openshift-on-proxmox.md`](docs/openshift-platform/01-single-node-openshift-on-proxmox.md).

## Security and sanitization

This is a public portfolio edition. The original work was completed in an internship environment, so the published documents use example domains, RFC 1918 addresses, placeholder usernames and placeholder secrets.

Never commit:

- pull secrets, access tokens or passwords;
- kubeconfig files;
- private keys or certificates containing private keys;
- Ansible Vault password files;
- internal backups, database exports or GitLab secrets;
- real infrastructure inventories without authorization.

Run the local preflight check before every push:

```bash
./scripts/preflight.sh
```

## Publish from WSL

After extracting the repository inside WSL, verify the files and publish them with:

```bash
cd ~/projects/linux-devops-infrastructure-labs
./scripts/preflight.sh
./scripts/publish-to-github.sh linux-devops-infrastructure-labs public
```

The publishing script uses the GitHub CLI, initializes Git, creates the first commit and publishes the repository under `TimurKhakimovPXL`. Change `public` to `private` for a private repository.

## Scope

The documents are detailed engineering records rather than one-click production recipes. Versions and environment assumptions are recorded in each document. Validate commands against current vendor documentation before using them in production.

## Author

**Timur Khakimov** — Junior Linux and DevOps Engineer focused on RHEL/Fedora, automation, containers, OpenShift and platform security.

## License

Released under the [MIT License](LICENSE).
