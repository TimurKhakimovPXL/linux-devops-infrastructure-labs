> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# GitLab EE: Cross-Infrastructure Migration Runbook

**Version:** 18.8.4-EE | **Target OS:** RHEL 10 | **Date:** March 2026 | **Team:** Infrastructure Lab

| Field           | Value                                      |
| --------------- | ------------------------------------------ |
| Document Status | Final                                      |
| Source Host     | Source Proxmox environment: guest OS access only |
| Target Host     | target Proxmox environment (Admin Access)             |
| Target OS       | RHEL 10: Minimal Profile                  |
| GitLab Edition  | Enterprise Edition (EE) 18.8.4             |
| Data Volume     | ~14 GB                                     |
| Network         | Internal vmbr1 · Tailscale Subnet Router   |
| Internal IP     | 192.168.50.30                                |

---

## 1. Migration constraints

I had `sudo` access inside the source GitLab VM but no access to its Proxmox host. That ruled out VM backups and disk exports, leaving GitLab's application backup and restore as the workable migration path.

### 1.1 Access Model

| Layer | Access Level | Implication |
|---|---|---|
| Proxmox Host (Source) | None | `vzdump`, `qmrestore`, disk export: all unavailable |
| Guest OS (Source VM) | `sudo` | Full application and filesystem access available |
| Proxmox Host (Target) | Admin | Full control: VM creation, storage, networking |

### 1.2 Strategy Decision Matrix

| Strategy | Mechanism | Requirement | Decision |
|---|---|---|---|
| VM Cloning (`vzdump`) | Proxmox-to-Proxmox | Host root access | ✗ Rejected: no host access |
| Disk Export/Import | `.qcow2` / `.raw` copy | Host shell access | ✗ Rejected: no host access |
| App-Level Backup/Restore | `gitlab-backup` rake task | Guest OS sudo | ✓ Selected |

> **Note:** Everything in this approach runs inside the guest OS. The source Proxmox administrator does not need to export or copy the VM.

---

## 2. Pre-Migration Health Check (Source VM)

Check the source before taking a backup. Existing data or encryption problems will follow the backup to the target.

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

## 3. Phase I: Source Backup (source GitLab VM)

Create two files: GitLab's application backup and a separate archive containing its configuration and secrets. A complete restore needs both.

### 3.1 Expand Disk (If Required)

The 14 GB backup archive requires sufficient free space on the source VM. The commands below match the recorded `/dev/sda3` + LVM + XFS layout and modify its partition table. Confirm the actual device, volume, and filesystem with `lsblk -f`, `pvs`, `lvs`, and `findmnt /` before using them; another layout needs different commands.

```bash
# Inspect the source VM first. Continue only if these names match.
lsblk -f
sudo pvs
sudo lvs
findmnt /

# Expand partition to use 100% of allocated disk
sudo parted /dev/sda resizepart 3 100%
sudo pvresize /dev/sda3
sudo lvextend -l +100%FREE /dev/mapper/rhel-root
sudo xfs_growfs /

# Verify available space
df -h /
```

### 3.2 Generate Application Data Backup

This command backs up the database, repositories, CI/CD artifacts, wikis, uploads, LFS objects, and locally stored registry data. Data kept in object storage needs the separate backup process for that storage; `gitlab-backup` does not copy those objects into this archive.

```bash
sudo gitlab-backup create
```

The output names the generated archive, for example `/var/opt/gitlab/backups/<timestamp>_18.8.4-ee_gitlab_backup.tar`. Keep the part before `_gitlab_backup.tar` as `BACKUP_ID` in the following steps.

### 3.3 Generate Configuration and Secrets Archive

GitLab's standard backup excludes its configuration and secrets. Archive them separately. Without the matching `gitlab-secrets.json`, the restored database contains encrypted values that GitLab cannot read.

> **⚠ Warning:** `gitlab-secrets.json` contains database encryption keys. Losing or mismatching this file will break all tokens, OAuth sessions, and 2FA credentials on the restored instance.

```bash
# Archive config, secrets, and SSL certificates
sudo tar -cvf "$HOME/gitlab_config_backup.tar" \
  /etc/gitlab/gitlab.rb \
  /etc/gitlab/gitlab-secrets.json \
  /etc/gitlab/ssl/
sudo chown "$(id -u):$(id -g)" "$HOME/gitlab_config_backup.tar"
chmod 600 "$HOME/gitlab_config_backup.tar"
```

If `/etc/gitlab/ssl/` does not exist on the source, omit that path rather than ignoring the tar error. Treat this archive as a secret because it contains `gitlab-secrets.json` and may contain TLS private keys.

### 3.4 Transfer Artifacts to Target

Transfer both artifacts to the target server. In this sanitized example, `labuser` is the normal SSH account created during the RHEL installation; it is not GitLab's service account. Replace `<timestamp>` once, then confirm checksums on both hosts.

```bash
# On the source VM
BACKUP_ID="<timestamp>_18.8.4-ee"
sudo cp "/var/opt/gitlab/backups/${BACKUP_ID}_gitlab_backup.tar" "$HOME/"
sudo chown "$(id -u):$(id -g)" "$HOME/${BACKUP_ID}_gitlab_backup.tar"
chmod 600 "$HOME/${BACKUP_ID}_gitlab_backup.tar"

scp "$HOME/${BACKUP_ID}_gitlab_backup.tar" \
  labuser@192.168.50.30:/home/labuser/
scp "$HOME/gitlab_config_backup.tar" \
  labuser@192.168.50.30:/home/labuser/

# Record source hashes.
sha256sum "$HOME/${BACKUP_ID}_gitlab_backup.tar" \
  "$HOME/gitlab_config_backup.tar"
```

On the target VM, run `sha256sum` on the two files under `/home/labuser` and compare the results with the source output before continuing.

---

## 4. Phase II: Target Preparation (RHEL 10)

Prepare the destination RHEL 10 VM before performing the restore. Version parity between source and target GitLab installations is mandatory.

### 4.1 Install Dependencies

> **Note:** RHEL 10 Minimal profile does not include `tar` by default. Install it before the GitLab package or the restore will fail at the extraction step.

```bash
sudo dnf install -y tar
```

### 4.2 Install GitLab EE 18.8.4

> **⚠ Warning:** The target must use the same GitLab version and edition (`18.8.4-ee`) that generated this backup. Restore first, then follow supported upgrade paths separately. The package suffix must also match the target operating system.

```bash
# Add the GitLab EE package repository after reviewing the downloaded script.
curl -fsSL \
  https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.rpm.sh \
  -o /tmp/gitlab-ee-repository.sh
sudo bash /tmp/gitlab-ee-repository.sh

# Install GitLab EE 18.8.4 for RHEL 10
# HTTP is intentional: this instance is internal-only via Tailscale.
# For public-facing deployments, use HTTPS and configure certificates in gitlab.rb.
sudo EXTERNAL_URL="http://192.168.50.30" \
  dnf install gitlab-ee-18.8.4-ee.0.el10.x86_64 -y
```

---

## 5. Phase III: Restore Execution

### 5.1 Stage the Backup File

Copy the backup archive to the official GitLab backup directory and set the required ownership. In a new shell on the target VM, set `BACKUP_ID` to the same value used on the source. The restore task expects the file to be owned by the `git` service account.

```bash
BACKUP_ID="<timestamp>_18.8.4-ee"
sudo cp "/home/labuser/${BACKUP_ID}_gitlab_backup.tar" /var/opt/gitlab/backups/
sudo chown git:git "/var/opt/gitlab/backups/${BACKUP_ID}_gitlab_backup.tar"
```

### 5.2 Restore Configuration and Secrets

GitLab requires the matching `gitlab-secrets.json` before the database restore. Restore the protected configuration archive and run `reconfigure` now, while the destination still contains no migrated application data.

```bash
sudo tar -xf /home/labuser/gitlab_config_backup.tar -C /
sudo gitlab-ctl reconfigure
```

Check the restored `external_url`, storage paths, and any external database or object-storage settings in `/etc/gitlab/gitlab.rb` before continuing. They must either still apply to the target or be adjusted deliberately; the sanitized runbook cannot supply environment-specific values.

### 5.3 Stop Application Workers

The restore requires Puma and Sidekiq to be stopped. PostgreSQL and Redis must remain running: the restore process writes directly to the database.

```bash
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq

# Verify: postgresql and redis must show 'run'
sudo gitlab-ctl status
```

### 5.4 The gtar Interceptor (RHEL 10 + GitLab 18.x Workaround)

During this lab, GitLab's Ruby restore task called `gtar`, which returned a non-zero status after trying to unlink its working directory. GitLab treated that status as fatal even though extraction had completed.

The temporary workaround was a `gtar` wrapper that passed the arguments to the real GNU tar binary and forced a zero exit code. The first attempt used aliases around `/bin/tar` and recursed; the corrected wrapper uses an explicit `/usr/bin/tar` path and leaves the system binary in place.

> **⚠ Warning:** The `|| true` construct suppresses all non-zero exit codes from `tar`: not just the unlink error. Monitor console output manually during restore. If you see `Disk full` or `Cannot open: Input/output error`, stop immediately and investigate before declaring success.

```bash
# Create the temporary interceptor ahead of /usr/bin in root's PATH.
sudo tee /usr/local/bin/gtar >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
/usr/bin/tar "$@" || true
SCRIPT
sudo chmod 0755 /usr/local/bin/gtar

# Confirm the restore process will resolve this wrapper.
sudo sh -c 'command -v gtar'
```

> **Note:** Calling `/usr/bin/tar` explicitly prevents the `gtar → tar → gtar` recursion seen in the earlier attempt. This remains a narrow lab workaround, not a permanent system configuration.

### 5.5 Execute the Restore

Run the restore task. Provide the backup ID recorded earlier and omit the `_gitlab_backup.tar` suffix.

```bash
sudo gitlab-backup restore BACKUP="$BACKUP_ID"

# When prompted:
#   'Do you want to continue (yes/no)?'        → type: yes
#   'Do you want to rebuild authorized_keys?'  → type: yes
```

The recorded restore printed `must be owner of extension pg_trgm`. It did not affect that migration, but the warning should only be accepted after the restore exits successfully and the health checks below pass.

---

## 6. Phase IV: Configuration Restore and Validation

### 6.1 Reconfigure and Start GitLab

The matching configuration and secrets were restored in Section 5.2. Reconfigure once more after the data restore, then start all services.

```bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
```

### 6.2 Integrity Verification

> **⚠ Warning:** Do not declare the migration successful until both rake tasks pass. A working web UI is not sufficient: the UI can load while encrypted data remains unreadable.

```bash
# Check for cryptographic mismatches between secrets and database
# Failures here indicate the wrong gitlab-secrets.json was restored
sudo gitlab-rake gitlab:doctor:secrets

# Broader health check: hooks, repositories, and permissions
sudo gitlab-rake gitlab:check SANITIZE=true
```

After the migration is accepted, remove the staging copies from both users' home directories or move them to approved encrypted backup storage. Do not leave `gitlab_config_backup.tar` readable in a general-purpose home directory.

### 6.3 Revert the gtar Wrapper

Restore the system `tar` binary to its original state. Leaving the wrapper in place would suppress legitimate `tar` errors system-wide.

```bash
sudo rm -f /usr/local/bin/gtar

# Confirm tar is functional
/usr/bin/tar --version
```

---

## 7. Phase V: Network Configuration

### 7.1 Open Firewall Port

```bash
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --list-services
```

### 7.2 Client-Side DNS Resolution

For internal access through `gitlab.lab.example.internal`, add this entry to the client's hosts file.

**Windows:** `C:\Windows\System32\drivers\etc\hosts`

**Linux/macOS:** `/etc/hosts`

```text
192.168.50.30    gitlab.lab.example.internal
```

> **Note:** Tailscale must be active on the client machine. The target VM is reachable only through the Tailscale Subnet Router on the private `vmbr1` bridge.

---

## 8. Troubleshooting Reference

| Error | Cause | Resolution |
|---|---|---|
| `gtar: .: Functie unlink() is mislukt` | `gtar` attempts to unlink working directory on modern kernels. | Deploy the `gtar` interceptor wrapper (Section 5.4). |
| `shell-niveau is te hoog (1000)` | Infinite recursion: `tar` calls `gtar` calls `tar`. | Make the temporary `gtar` wrapper call `/usr/bin/tar` explicitly; do not alias `tar` back to `gtar`. |
| `vereist bestand is niet gevonden` | `tar` utility absent from RHEL 10 Minimal profile. | `sudo dnf install -y tar` (Section 4.1). |
| `must be owner of extension pg_trgm` | PostgreSQL extension owner mismatch from source instance. | It was non-fatal in this run. Confirm restore exit status and run both GitLab health checks before accepting it. |
| Connection Timed Out (port 80) | `firewalld` blocking HTTP on RHEL. | `firewall-cmd --permanent --add-service=http` (Section 7.1). |
| `curl http://192.168.50.30` returns HTTP 302 to `/users/sign_in` | Not an error: expected GitLab behaviour. | 302 redirect confirms the Rails engine is healthy. |

---

## 9. Migration Phase Summary

| Phase | Name | Key Actions | Verification |
|---|---|---|---|
| 0 | Pre-Migration | `gitlab:check`, `gitlab:doctor:secrets` on source | Both rake tasks pass |
| I | Source Backup | `gitlab-backup create`, config tar, SCP transfer | SHA256 checksums match on both ends |
| II | Target Prep | Install `tar`, install GitLab EE 18.8.4 (el10) | `gitlab-ctl status`: all services run |
| III | Restore | Stage file, restore matching secrets, stop workers, use the temporary `gtar` wrapper, run `gitlab-backup restore` | Restore exits without fatal errors |
| IV | Reconfigure + Validation | `reconfigure`, `restart`, rake checks | Both rake tasks pass on target |
| V | Networking | `firewall-cmd`, hosts file, Tailscale verify | Browser loads sign-in page |
| Post | Cleanup | Remove the temporary `gtar` wrapper | `/usr/bin/tar --version` succeeds |
