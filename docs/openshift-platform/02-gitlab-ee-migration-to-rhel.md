> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

# GitLab EE — Cross-Infrastructure Migration Runbook

**Version:** 18.8.4-EE | **Target OS:** RHEL 10 | **Date:** March 2026 | **Team:** Infrastructure Lab

| Field           | Value                                      |
| --------------- | ------------------------------------------ |
| Document Status | Final                                      |
| Source Host     | Source Proxmox environment — guest OS access only |
| Target Host     | target Proxmox environment (Admin Access)             |
| Target OS       | RHEL 10 — Minimal Profile                  |
| GitLab Edition  | Enterprise Edition (EE) 18.8.4             |
| Data Volume     | ~14 GB                                     |
| Network         | Internal vmbr1 · Tailscale Subnet Router   |
| Internal IP     | 192.168.50.30                                |

---

## 1. Migration Constraint Analysis

The source GitLab instance runs as a VM on company Proxmox infrastructure where the engineer holds no host-level administrative privileges. This constraint eliminates all VM-level migration strategies and forces an application-level approach.

### 1.1 Access Model

| Layer | Access Level | Implication |
|---|---|---|
| Proxmox Host (Source) | None | `vzdump`, `qmrestore`, disk export — all unavailable |
| Guest OS (Source VM) | `sudo` | Full application and filesystem access available |
| Proxmox Host (Target) | Admin | Full control — VM creation, storage, networking |

### 1.2 Strategy Decision Matrix

| Strategy | Mechanism | Requirement | Decision |
|---|---|---|---|
| VM Cloning (`vzdump`) | Proxmox-to-Proxmox | Host root access | ✗ Rejected — no host access |
| Disk Export/Import | `.qcow2` / `.raw` copy | Host shell access | ✗ Rejected — no host access |
| App-Level Backup/Restore | `gitlab-backup` rake task | Guest OS sudo | ✓ Selected |

> **Note:** The application-level strategy shifts all migration logic into the Guest OS. Data is extracted and transferred via standard SSH/SCP protocols under a restricted operating-system account, with no Proxmox host cooperation required.

---

## 2. Pre-Migration Health Check (Source VM)

Verify the source instance is healthy before generating migration artifacts. Migrating from a broken state will replicate the breakage on the target.

### 2.1 Verify GitLab Service Health

```bash
sudo gitlab-ctl status
# Expected: all services in 'run' state
```

### 2.2 Verify Data Integrity

```bash
sudo gitlab-rake gitlab:check SANITIZE=true
sudo gitlab-rake gitlab:doctor:secrets
```

> **⚠ Warning:** Do not proceed if `gitlab:doctor:secrets` reports cryptographic errors. These will carry over to the target and prevent user authentication.

---

## 3. Phase I — Source Backup (source GitLab VM)

Generate two distinct artifacts: the application data backup and the configuration/secrets archive. Both are required for a complete restore.

### 3.1 Expand Disk (If Required)

The 14 GB backup archive requires sufficient free space on the source VM. If the partition is at capacity, expand it before proceeding.

```bash
# Expand partition to use 100% of allocated disk
sudo parted /dev/sda resizepart 3 100%
sudo pvresize /dev/sda3
sudo lvextend -l +100%FREE /dev/mapper/rhel-root
sudo xfs_growfs /

# Verify available space
df -h /
```

### 3.2 Generate Application Data Backup

This command backs up all GitLab application data: repositories, database, CI/CD artifacts, wikis, uploads, LFS objects, and registry data.

```bash
sudo gitlab-backup create

# Output artifact:
# /var/opt/gitlab/backups/[TIMESTAMP]_18.8.4-ee_gitlab_backup.tar
```

### 3.3 Generate Configuration and Secrets Archive

The standard backup explicitly excludes configuration and secrets. These must be archived separately. The secrets file is required for database decryption without it, the restore will produce a non-functional instance.

> **⚠ Warning:** `gitlab-secrets.json` contains database encryption keys. Losing or mismatching this file will break all tokens, OAuth sessions, and 2FA credentials on the restored instance.

```bash
# Archive config, secrets, and SSL certificates
sudo tar -cvf gitlab_config_backup.tar \
  /etc/gitlab/gitlab.rb \
  /etc/gitlab/gitlab-secrets.json \
  /etc/gitlab/ssl/

# Output artifact:
# gitlab_config_backup.tar
```

### 3.4 Transfer Artifacts to Target

Transfer both artifacts to the target server. Confirm checksums after transfer to rule out corruption during transit.

```bash
# Transfer application backup
scp /var/opt/gitlab/backups/[TIMESTAMP]_18.8.4-ee_gitlab_backup.tar \
  gitlab@192.168.50.30:/home/gitlab/

# Transfer config and secrets archive
scp gitlab_config_backup.tar gitlab@192.168.50.30:/home/gitlab/

# Verify integrity — run on both source and target, hashes must match
sha256sum [TIMESTAMP]_18.8.4-ee_gitlab_backup.tar
sha256sum gitlab_config_backup.tar
```

---

## 4. Phase II — Target Preparation (RHEL 10)

Prepare the destination RHEL 10 VM before performing the restore. Version parity between source and target GitLab installations is mandatory.

### 4.1 Install Dependencies

> **Note:** RHEL 10 Minimal profile does not include `tar` by default. Install it before the GitLab package or the restore will fail at the extraction step.

```bash
sudo dnf install -y tar
```

### 4.2 Install GitLab EE 18.8.4

> **⚠ Warning:** Install the exact same version (`18.8.4-ee`) that generated the backup. GitLab does not support cross-version restores. Note the `.el10` package suffix — RHEL 10 is not `el9`.

```bash
# Add the GitLab EE package repository
curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.rpm.sh | sudo bash

# Install GitLab EE 18.8.4 for RHEL 10
# HTTP is intentional — this instance is internal-only via Tailscale.
# For public-facing deployments, use HTTPS and configure certificates in gitlab.rb.
sudo EXTERNAL_URL="http://192.168.50.30" \
  dnf install gitlab-ee-18.8.4-ee.0.el10.x86_64 -y
```

---

## 5. Phase III — Restore Execution

### 5.1 Stage the Backup File

Copy the backup archive to the official GitLab backup directory and set the required ownership. The restore task refuses to process files not owned by the `git` user.

```bash
sudo cp /home/gitlab/[TIMESTAMP]_18.8.4-ee_gitlab_backup.tar /var/opt/gitlab/backups/
sudo chown git:git /var/opt/gitlab/backups/[TIMESTAMP]_18.8.4-ee_gitlab_backup.tar
```

### 5.2 Stop Application Workers

The restore requires Puma and Sidekiq to be stopped. PostgreSQL and Redis must remain running — the restore process writes directly to the database.

```bash
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq

# Verify: postgresql and redis must show 'run'
sudo gitlab-ctl status
```

### 5.3 The gtar Interceptor (RHEL 10 + GitLab 18.x Workaround)

GitLab's Ruby restore script invokes `gtar` during extraction. On modern Linux kernels, `gtar` fails with a non-zero exit code when it attempts to unlink the working directory. GitLab's script interprets this as a fatal error and aborts the restore — even though the data was extracted successfully.

The fix is to create a wrapper script at `/bin/gtar` that intercepts the call, passes all arguments to the real binary, and forces a zero exit code.

> **⚠ Warning:** The `|| true` construct suppresses all non-zero exit codes from `tar` — not just the unlink error. Monitor console output manually during restore. If you see `Disk full` or `Cannot open: Input/output error`, stop immediately and investigate before declaring success.

```bash
# Step 1: Isolate the real binary (prevents infinite recursion)
sudo mv /bin/tar /bin/tar.orig

# Step 2: Create the interceptor wrapper
echo '#!/bin/bash' | sudo tee /bin/gtar
echo '/bin/tar.orig "$@" || true' | sudo tee -a /bin/gtar
sudo chmod +x /bin/gtar
```

> **Note:** Renaming `tar` to `tar.orig` is critical. A symlink or alias approach causes infinite recursion where `gtar` calls `tar` which calls `gtar`. The rename breaks the loop by giving the wrapper a stable target.

### 5.4 Execute the Restore

Run the restore task. Provide only the timestamp prefix — omit the `_gitlab_backup.tar` suffix.

```bash
sudo gitlab-backup restore BACKUP=[TIMESTAMP]_18.8.4-ee

# When prompted:
#   'Do you want to continue (yes/no)?'        → type: yes
#   'Do you want to rebuild authorized_keys?'  → type: yes
```

Expected warnings that can be safely ignored:
- `must be owner of extension pg_trgm` — PostgreSQL extension owner mismatch. Harmless; does not affect functionality.

---

## 6. Phase IV — Configuration Restore and Validation

### 6.1 Restore Configuration and Secrets

Secrets must be restored before running `reconfigure`. The reconfigure step reads `gitlab-secrets.json` to configure encryption — if the file is missing or wrong, the instance will start but all encrypted data (tokens, passwords, 2FA) will be unreadable.

```bash
# Restore secrets and configuration (must precede reconfigure)
sudo tar -xf /home/gitlab/gitlab_config_backup.tar -C /

# Apply configuration
sudo gitlab-ctl reconfigure

# Start all services
sudo gitlab-ctl restart
```

### 6.2 Integrity Verification

> **⚠ Warning:** Do not declare the migration successful until both rake tasks pass. A working web UI is not sufficient — the UI can load while encrypted data remains unreadable.

```bash
# Check for cryptographic mismatches between secrets and database
# Failures here indicate the wrong gitlab-secrets.json was restored
sudo gitlab-rake gitlab:doctor:secrets

# Comprehensive system health: hooks, repositories, permissions
sudo gitlab-rake gitlab:check SANITIZE=true
```

### 6.3 Revert the gtar Wrapper

Restore the system `tar` binary to its original state. Leaving the wrapper in place would suppress legitimate `tar` errors system-wide.

```bash
sudo rm -f /bin/gtar
sudo mv /bin/tar.orig /bin/tar

# Confirm tar is functional
tar --version
```

---

## 7. Phase V — Network Configuration

### 7.1 Open Firewall Port

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --list-services
```

### 7.2 Client-Side DNS Resolution

For internal access using the `gitlab.lab.example.internal` hostname, add the following entry to the client hosts file.

**Windows:** `C:\Windows\System32\drivers\etc\hosts`

**Linux/macOS:** `/etc/hosts`

```
192.168.50.30    gitlab.lab.example.internal
```

> **Note:** Tailscale must be active on the client machine. The target VM is reachable only through the Tailscale Subnet Router on the private `vmbr1` bridge.

---

## 8. Troubleshooting Reference

| Error | Cause | Resolution |
|---|---|---|
| `gtar: .: Functie unlink() is mislukt` | `gtar` attempts to unlink working directory on modern kernels. | Deploy the `gtar` interceptor wrapper (Section 5.3). |
| `shell-niveau is te hoog (1000)` | Infinite recursion: `tar` calls `gtar` calls `tar`. | Rename original binary to `/bin/tar.orig` instead of symlinking. |
| `vereist bestand is niet gevonden` | `tar` utility absent from RHEL 10 Minimal profile. | `sudo dnf install -y tar` (Section 4.1). |
| `must be owner of extension pg_trgm` | PostgreSQL extension owner mismatch from source instance. | Safe to ignore. Does not affect GitLab functionality. |
| Connection Timed Out (port 80) | `firewalld` blocking HTTP on RHEL. | `firewall-cmd --permanent --add-service=http` (Section 7.1). |
| `curl http://192.168.50.30` returns HTTP 302 to `/users/sign_in` | Not an error — expected GitLab behaviour. | 302 redirect confirms the Rails engine is healthy. |

---

## 9. Migration Phase Summary

| Phase | Name | Key Actions | Verification |
|---|---|---|---|
| 0 | Pre-Migration | `gitlab:check`, `gitlab:doctor:secrets` on source | Both rake tasks pass |
| I | Source Backup | `gitlab-backup create`, config tar, SCP transfer | SHA256 checksums match on both ends |
| II | Target Prep | Install `tar`, install GitLab EE 18.8.4 (el10) | `gitlab-ctl status`: all services run |
| III | Restore | Stage file, stop workers, `gtar` wrapper, `gitlab-backup restore` | Restore exits without fatal errors |
| IV | Config + Validation | Restore secrets, `reconfigure`, `restart`, rake checks | Both rake tasks pass on target |
| V | Networking | `firewall-cmd`, hosts file, Tailscale verify | Browser loads sign-in page |
| Post | Cleanup | Remove `gtar` wrapper, restore `/bin/tar` | `tar --version` succeeds |
