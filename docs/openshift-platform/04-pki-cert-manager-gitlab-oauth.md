> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

## Target 4: PKI, GitLab HTTPS, and Identity Provider

**Objective:** Establish a private Certificate Authority managed by cert-manager inside OpenShift, issue and auto-renew TLS certificates for all cluster ingress and the GitLab VM, then configure GitLab as the OpenShift identity provider so GitLab users can authenticate to the cluster.
**Target Environment:** Single Node OpenShift lab — Single Node OpenShift 4.21
**GitLab Instance:** `https://gitlab.lab.example.internal` (the GitLab VM — `192.168.50.30`)
**cert-manager Operator:** v1.18.1 (`stable-v1` channel)

---

## 1. Design Decisions and Scope

### 1.1 Certificate Inventory

| Certificate | Issued To | Namespace | Secret | Consumer |
|---|---|---|---|---|
| Wildcard | `*.apps.lab.example.internal` | `openshift-ingress` | `wildcard-apps-stage-tls` | IngressController — all Routes |
| GitLab | `gitlab.lab.example.internal` | `lab-infra` | `gitlab-tls` | GitLab VM nginx via pull agent |

### 1.2 Design Decision: GitLab Certificate Delivery

cert-manager manages certificates as Kubernetes Secrets inside the cluster. GitLab is an external VM at `192.168.50.30` — not a pod inside OpenShift. There is no native cert-manager mechanism to write a Secret to a VM filesystem. Three approaches were evaluated:

|                                 | Option 1 — Pull agent (chosen)                           | Option 2 — Push CronJob                                          | Option 3 — GitLab in OpenShift                                           |
| ------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **Mechanism**                   | systemd timer on GitLab VM pulls cert from OpenShift API | Kubernetes CronJob SSHs into GitLab VM and copies cert           | GitLab runs as a container, cert-manager manages it natively via a Route |
| **Credentials stored**          | Least-privilege SA token on GitLab VM filesystem         | SSH private key as cluster Secret                                | N/A                                                                      |
| **Firewall direction**          | GitLab VM → OpenShift API (HTTPS/6443) — already open    | OpenShift → GitLab VM (SSH/22) — additional exposure             | N/A                                                                      |
| **Cluster knowledge of GitLab** | None — cluster does not need to know GitLab exists       | Cluster holds SSH credentials for an external VM                 | N/A                                                                      |
| **Complexity**                  | Low — 20-line bash script, logs to journal               | Medium — CronJob installs SSH client at runtime, harder to audit | High — full GitLab containerisation out of scope                         |
| **Production use**              | Standard pattern for external load balancers, HSMs, VMs  | Used but considered less clean due to SSH key sprawl             | Correct long-term architecture, not viable here                          |

**Decision: Option 1.** The GitLab VM already has outbound HTTPS to the OpenShift API through `vmbr1`. The ServiceAccount token is scoped to `get` on exactly one Secret in one namespace. The cluster has no knowledge of the GitLab VM and no credentials that could be used to reach it. The script is minimal, runs as root via systemd, and logs every execution to the system journal.

Option 2 was rejected because storing SSH keys in cluster Secrets creates a lateral movement path from the cluster to the GitLab VM. Option 3 is the correct production architecture for a fully containerised environment but is out of scope for this infrastructure.

### 1.3 GitOps Scope

The infrastructure layer — cert-manager operator, ClusterIssuer, OAuth CR, RBAC, and namespace configuration — was applied directly with `oc apply` and is not currently managed by ArgoCD. This is intentional: bringing operators and cluster-scoped resources under GitOps requires sync wave ordering and a secrets management solution (SealedSecrets or external-secrets-operator) to avoid committing sensitive values to Git in plaintext. That work is deferred to a future target.

Application workloads from Target 3 onward are deployed through GitOps. The infrastructure layer is managed directly. This hybrid model is standard practice — Terraform or Ansible for the infrastructure plane, GitOps for the application plane.

These phases must be executed in sequence. Each is a prerequisite for the next.

```
Phase 0: Generate the Lab Internal CA (jump VM)
Phase 1: Install cert-manager + import CA into cluster
Phase 2: Issue wildcard cert → patch IngressController
Phase 3: Issue GitLab cert → pull agent on GitLab VM
Phase 4: Register OAuth app in GitLab
Phase 5: Configure OpenShift OAuth CR
Phase 6: First login + grant cluster-admin
```

---

## 2. Architecture

```
  Lab Internal CA (ca.crt + ca.key)
  ~/pki/ on jump VM — import once, keep as offline backup
           │
           │  imported as Kubernetes Secret
           ▼
  ┌─────────────────────────────────────────────────────────────┐
  │                  SNO Cluster (192.168.50.20)                  │
  │                                                             │
  │  namespace: cert-manager-operator                           │
  │  ┌─────────────────────────────────────────┐                │
  │  │  Red Hat cert-manager Operator (OLM)    │                │
  │  │  v1.18.1 · channel: stable-v1           │                │
  │  └──────────────────┬──────────────────────┘                │
  │                     │ manages                               │
  │  namespace: cert-manager                                    │
  │  ┌─────────────────────────────────────────┐                │
  │  │  cert-manager controller                │                │
  │  │  cert-manager cainjector                │                │
  │  │  cert-manager webhook                   │                │
  │  │  Secret: lab-ca-keypair               │                │
  │  └──────────────────┬──────────────────────┘                │
  │                     │                                       │
  │  ClusterIssuer: lab-internal-ca (cluster-scoped)          │
  │                     │                                       │
  │          ┌──────────┴──────────┐                            │
  │          │                     │                            │
  │  ns: openshift-ingress   ns: lab-infra                    │
  │  Certificate:            Certificate:                       │ 
  │  wildcard-apps-stage     gitlab-local-internal              │
  │  Secret:                 Secret: gitlab-tls                 │
  │  wildcard-apps-stage-tls ServiceAccount: gitlab-cert-sync   │
  │          │                     │                            │
  └──────────┼─────────────────────┼───────────────────────────-┘
             │                     │
             ▼                     ▼ (HTTPS API pull, every 30min)
  IngressController default   GitLab VM (192.168.50.30)
  All Routes: console,        systemd timer
  ArgoCD, OAuth, apps         /etc/gitlab/ssl/ → nginx reload
             │
             │ OAuth 2.0 / OIDC over HTTPS
             ▼
  OpenShift OAuth Server
  identityProvider: GitLab
  ca: gitlab-ca ConfigMap (Lab Internal CA)
```

---

## 3. Known Limitations

These are accepted risks documented explicitly. They do not affect the correctness of the implementation for this environment but a production hardening review would address them.

| #   | Limitation                                                                                                   | Impact                                                                                                                                                                           | Resolution Path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Infrastructure layer (cert-manager, ClusterIssuer, OAuth CR, RBAC) applied via `oc apply` — not under GitOps | Cluster state can drift from documentation. Rebuild requires re-running all commands manually                                                                                    | Future target: commit all infra manifests to `cluster-configs/` in the GitOps repo with sync wave ordering and a secrets management solution (SealedSecrets or external-secrets-operator)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 2   | GitLab VM cert sync relies on a root-run systemd timer                                                       | The VM is responsible for kubeconfig security, timer health, and nginx reload correctness. Operational surface exists outside the cluster                                        | Accepted tradeoff for an external VM. Three potential hardening paths identified: <br>(1) Dedicated non-root user with a single narrow sudo rule for `gitlab-ctl hup nginx` only — <br>reduces attack surface, still requires privilege escalation for reload. <br>(2) Rootless Podman Quadlet for the pull and write steps — eliminates root for cert <br>retrieval but reload trigger remains unsolved with GitLab omnibus architecture. <br>(3) Migrate GitLab omnibus to rootless Podman Quadlets — cert-sync and GitLab nginx run <br>as Quadlets under the same user, sharing a Podman volume. SIGHUP sent between containers <br>rootlessly. Fully eliminates root requirement and resolves the limitation cleanly. <br>Equivalent to Option 3 from section 1.2 approached from the VM layer rather than <br>OpenShift. Deferred — out of scope for current infrastructure. |
| 3   | ~~ServiceAccount token valid for 1 year — rotation is manual~~                                               | ~~Long-lived bearer token on VM filesystem is a security liability if the VM is compromised. Rotation depends on a calendar reminder — the automation is not fully closed-loop~~ | **Resolved:** The sync script rotates its own token on every run. On each execution the script uses the current token to request a fresh 24h bound token via `oc create token`, then atomically overwrites the kubeconfig via a temp file before proceeding. The token is never older than 30 minutes plus 24 hours. No manual rotation required. The Role was extended with `serviceaccounts/token: create` on `gitlab-cert-sync` to permit self-rotation.                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 4   | ~~CA private key stored on jump VM~~                                                                         | ~~If the jump VM is compromised, the CA signing capability is compromised and all issued certificates are untrusted~~                                                            | **Resolved:** `ca.key` was shredded from the jump VM after import into the cluster. The cluster Secret `lab-ca-keypair` in the `cert-manager` namespace is now the sole holder of the CA signing capability, access-controlled by Kubernetes RBAC. `ca.crt` remains on the jump VM as a public trust anchor for distribution only                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

---

## 4. Phase 0 — Generate the Lab Internal CA

The Lab Internal CA is generated once on the jump VM using OpenSSL. This CA is the root of trust for all internal certificates. After generation it is imported into cert-manager (Phase 1) and the private key is shredded from the jump VM — the cluster Secret becomes the sole holder.

### 4.1 PKI Directory

```bash
mkdir -p ~/pki && cd ~/pki
```

### 4.2 Generate the CA Private Key and Certificate

```bash
# Generate CA private key (4096-bit RSA)
openssl genrsa -out ca.key 4096

# Generate self-signed CA certificate (10 year validity)
openssl req -new -x509 -days 3650 -key ca.key \
  -out ca.crt \
  -subj "/C=BE/ST=Flemish Brabant/L=Leuven/O=Infrastructure Lab/CN=Lab Internal CA"
```

**Verify the CA:**

```bash
openssl x509 -in ~/pki/ca.crt -noout -text | grep -A4 "Subject\|Validity"
```

Expected output:
```
Validity
    Not Before: Mar 19 12:48:49 2026 GMT
    Not After : Mar 16 12:48:49 2036 GMT
Subject: C=BE, ST=Flemish Brabant, L=Leuven, O=Infrastructure Lab, CN=Lab Internal CA
```

| File | Purpose |
|---|---|
| `ca.key` | CA private key — imported into cert-manager, then shredded from jump VM |
| `ca.crt` | CA public certificate — distributed to all trusting systems |

---

## 5. Phase 1 — cert-manager Operator

### 4.1 Install via OLM

All commands are executed from the jump VM (`192.168.50.101`) with kubeconfig exported:

```bash
export KUBECONFIG=~/sno-install/auth/kubeconfig
```

Create the operator namespace:

```bash
oc new-project cert-manager-operator
```

Create the OperatorGroup. The `targetNamespaces` scope is intentional — cert-manager's cluster-scoped resources (`ClusterIssuer`, `Certificate` CRDs) are registered separately and do not require a cluster-scoped OperatorGroup:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-group
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
EOF
```

Create the Subscription:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

### 4.2 Verify Installation

Watch the CSV until `Succeeded`:

```bash
oc get csv -n cert-manager-operator -w
```

Expected final state:
```
NAME                              DISPLAY                                        VERSION   PHASE
cert-manager-operator.v1.18.1    cert-manager Operator for Red Hat OpenShift    1.18.1    Succeeded
```

Verify the three operand pods are running in the `cert-manager` namespace (note: separate from `cert-manager-operator`):

```bash
oc get pods -n cert-manager
```

Expected — all three must be `Running` before proceeding:
```
NAME                                       READY   STATUS
cert-manager-xxxxxxxxxx-xxxxx              1/1     Running
cert-manager-cainjector-xxxxxxxxxx-xxxxx   1/1     Running
cert-manager-webhook-xxxxxxxxxx-xxxxx      1/1     Running
```

> [!note] Two Namespaces
> `cert-manager-operator` — OLM manages the operator here.
> `cert-manager` — the operator runs the controller, cainjector, and webhook here. CA Secrets referenced by ClusterIssuers must live in `cert-manager`.

### 4.3 Import the Lab Internal CA

Create the CA Secret in the `cert-manager` namespace:

```bash
oc create secret tls lab-ca-keypair \
  --namespace cert-manager \
  --cert=$HOME/pki/ca.crt \
  --key=$HOME/pki/ca.key
```

> [!note] `$HOME` not `~`
> The `oc` CLI does not expand `~` in file path arguments. Always use `$HOME` or an absolute path.

Create the ClusterIssuer. As a cluster-scoped resource it can sign certificates in any namespace:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-internal-ca
spec:
  ca:
    secretName: lab-ca-keypair
EOF
```

Verify it is ready:

```bash
oc get clusterissuer lab-internal-ca -o wide
```

Expected:
```
NAME                READY   STATUS                AGE
lab-internal-ca   True    Signing CA verified   Xs
```

If `READY` is `False`, check `oc describe clusterissuer lab-internal-ca` — the condition message will identify whether the issue is the Secret namespace, PEM formatting, or a webhook timeout.

---

## 6. Phase 2 — Wildcard Certificate for OpenShift Ingress

### 5.1 Issue the Certificate

The Certificate resource must be in `openshift-ingress` so the resulting Secret is co-located with the IngressController pods:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-apps-stage
  namespace: openshift-ingress
spec:
  secretName: wildcard-apps-stage-tls
  dnsNames:
    - "*.apps.lab.example.internal"
  issuerRef:
    kind: ClusterIssuer
    name: lab-internal-ca
    group: cert-manager.io
  privateKey:
    algorithm: RSA
    size: 2048
  renewBefore: 720h
EOF
```

`renewBefore: 720h` triggers renewal 30 days before expiry. cert-manager's default validity is 90 days, so renewal occurs at day 60.

> [!note] rotationPolicy warning
> cert-manager v1.18+ logs a warning if `spec.privateKey.rotationPolicy` is not set, as the default changed from `Never` to `Always` in this version. This is informational — `Always` means the private key is rotated on each renewal, which is correct practice.

Verify issuance:

```bash
oc get certificate wildcard-apps-stage -n openshift-ingress
```

Expected:
```
NAME                  READY   SECRET                    AGE
wildcard-apps-stage   True    wildcard-apps-stage-tls   Xs
```

### 5.2 Patch the IngressController

```bash
oc patch ingresscontroller default \
  -n openshift-ingress-operator \
  --type=merge \
  --patch='{"spec": {"defaultCertificate": {"name": "wildcard-apps-stage-tls"}}}'
```

Watch the router pod roll:

```bash
oc rollout status deployment/router-default -n openshift-ingress
```

### 5.3 Inject the Lab Internal CA into the Cluster Proxy Trust Bundle

After patching the wildcard cert onto the IngressController, OpenShift's internal components  including the OAuth server validate the router certificate against the cluster proxy trust bundle. The Lab Internal CA must be added to this bundle or the authentication operator will report `RouterCertsDegraded`.

```bash
oc create configmap lab-ca-bundle \
  --from-file=ca-bundle.crt=$HOME/pki/ca.crt \
  -n openshift-config

oc patch proxy/cluster \
  --type=merge \
  --patch='{"spec": {"trustedCA": {"name": "lab-ca-bundle"}}}'
```

Wait for the authentication operator to recover — it will roll its pods to pick up the new trust bundle:

```bash
oc get clusteroperators authentication -w
```

Wait until `AVAILABLE=True, PROGRESSING=False, DEGRADED=False`. On SNO this takes 2-3 minutes as there is only one node and zero pods are available briefly during the rollout.

Then verify all operators are healthy:

```bash
oc get clusteroperators | grep -v "True.*False.*False"
```

Expected: no output — only the header line.

### 5.4 Verify the Certificate is Served

```bash
echo | openssl s_client \
  -connect console-openshift-console.apps.lab.example.internal:443 \
  -servername console-openshift-console.apps.lab.example.internal 2>/dev/null \
  | openssl x509 -noout -text | grep -A2 "Subject Alternative"
```

Expected:
```
X509v3 Subject Alternative Name: critical
    DNS:*.apps.lab.example.internal
```

---

## 7. Phase 3 — GitLab Certificate Automation (Pull-Based Agent)

cert-manager issues and auto-renews the GitLab certificate as a Kubernetes Secret. A systemd timer on the GitLab VM pulls the current cert from the OpenShift API on a 30-minute schedule and reloads nginx. No manual certificate operations are required after initial setup.

### 6.1 Create the Namespace and Certificate

```bash
oc new-project lab-infra
```

```bash
cat << 'EOF' | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gitlab-local-internal
  namespace: lab-infra
spec:
  secretName: gitlab-tls
  dnsNames:
    - gitlab.lab.example.internal
  issuerRef:
    kind: ClusterIssuer
    name: lab-internal-ca
    group: cert-manager.io
  privateKey:
    algorithm: RSA
    size: 2048
  renewBefore: 720h
EOF
```

```bash
oc get certificate gitlab-local-internal -n lab-infra
# Wait for READY: True
```

### 6.2 Create the ServiceAccount and RBAC

The ServiceAccount is granted `get` access to exactly one Secret (`gitlab-tls`) in exactly one namespace (`lab-infra`):

```bash
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitlab-cert-sync
  namespace: lab-infra
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gitlab-cert-reader
  namespace: lab-infra
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["gitlab-tls"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["gitlab-cert-sync"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitlab-cert-reader-binding
  namespace: lab-infra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gitlab-cert-reader
subjects:
  - kind: ServiceAccount
    name: gitlab-cert-sync
    namespace: lab-infra
EOF
```

### 6.3 Generate the ServiceAccount Token

> [!warning] OCP 4.21 / Kubernetes 1.24+ Token Change
> ServiceAccounts no longer receive auto-created token Secrets in Kubernetes 1.24+. The `sa.secrets[0].name` pattern used in older documentation does not work. Use `oc create token` with an explicit duration.

```bash
oc create token gitlab-cert-sync \
  -n lab-infra \
  --duration=8760h \
  > /tmp/gitlab-cert-sync-token.txt

chmod 600 /tmp/gitlab-cert-sync-token.txt
```

### 6.4 Build the kubeconfig

The kubeconfig embeds the cluster CA so the `oc` client on the GitLab VM can verify the API server TLS certificate without additional system trust configuration:

```bash
APISERVER=$(oc whoami --show-server)
CA_DATA=$(oc config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(cat /tmp/gitlab-cert-sync-token.txt)

cat > /tmp/gitlab-cert-sync-kubeconfig.yaml << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${APISERVER}
  name: openshift
contexts:
- context:
    cluster: openshift
    namespace: lab-infra
    user: gitlab-cert-sync
  name: gitlab-cert-sync-ctx
current-context: gitlab-cert-sync-ctx
users:
- name: gitlab-cert-sync
  user:
    token: ${TOKEN}
EOF

chmod 600 /tmp/gitlab-cert-sync-kubeconfig.yaml
```

Verify the kubeconfig works before transferring:

```bash
oc --kubeconfig=/tmp/gitlab-cert-sync-kubeconfig.yaml \
  get secret gitlab-tls -n lab-infra --no-headers
```

Expected: one line showing the secret. Do not proceed if this fails.

Transfer to the GitLab VM:

```bash
scp /tmp/gitlab-cert-sync-kubeconfig.yaml \
  gitlab@192.168.50.30:/tmp/gitlab-cert-sync-kubeconfig.yaml
```

Clean up from the jump VM:

```bash
shred -u /tmp/gitlab-cert-sync-token.txt /tmp/gitlab-cert-sync-kubeconfig.yaml
```

### 6.5 Install `oc` on the GitLab VM

`openshift-clients` is not available in the default RHEL 10 repos. Install directly from the OpenShift mirror:

```bash
# On the GitLab VM
curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.21/openshift-client-linux.tar.gz \
  | sudo tar xz -C /usr/local/bin oc

# Symlink into sudo's secure path
sudo ln -s /usr/local/bin/oc /usr/bin/oc

oc version --client
```

### 6.6 Stage the kubeconfig

```bash
# On the GitLab VM
sudo mkdir -p /etc/gitlab/cert-sync
sudo mv /tmp/gitlab-cert-sync-kubeconfig.yaml /etc/gitlab/cert-sync/kubeconfig
sudo chmod 600 /etc/gitlab/cert-sync/kubeconfig
sudo chown root:root /etc/gitlab/cert-sync/kubeconfig
```

Verify root can reach the cluster:

```bash
sudo oc --kubeconfig=/etc/gitlab/cert-sync/kubeconfig \
  get secret gitlab-tls -n lab-infra --no-headers
```

### 6.7 Create the Pull Script

```bash
sudo tee /usr/local/bin/gitlab-cert-sync.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

KUBECONFIG=/etc/gitlab/cert-sync/kubeconfig
NAMESPACE=lab-infra
SECRET_NAME=gitlab-tls
CERT_DIR=/etc/gitlab/ssl
LOG_TAG="gitlab-cert-sync"

logger -t "${LOG_TAG}" "Starting certificate sync from OpenShift"

mkdir -p "${CERT_DIR}"

# Pull cert and key from the cluster Secret
oc --kubeconfig="${KUBECONFIG}" \
  -n "${NAMESPACE}" \
  get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CERT_DIR}/gitlab.lab.example.internal.crt"

oc --kubeconfig="${KUBECONFIG}" \
  -n "${NAMESPACE}" \
  get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "${CERT_DIR}/gitlab.lab.example.internal.key"

chmod 600 "${CERT_DIR}/gitlab.lab.example.internal.key"
chmod 644 "${CERT_DIR}/gitlab.lab.example.internal.crt"

# Rotate the token — request a fresh 24h token using the current token
NEW_TOKEN=$(oc --kubeconfig="${KUBECONFIG}" \
  create token gitlab-cert-sync \
  -n "${NAMESPACE}" \
  --duration=24h)

# Atomically update the token in the kubeconfig via temp file
TEMP_KUBECONFIG=$(mktemp)
sed "s/token: .*/token: ${NEW_TOKEN}/" "${KUBECONFIG}" > "${TEMP_KUBECONFIG}"
chmod 600 "${TEMP_KUBECONFIG}"
mv "${TEMP_KUBECONFIG}" "${KUBECONFIG}"

logger -t "${LOG_TAG}" "Token rotated successfully"

# Reload nginx without downtime
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
else
  gitlab-ctl hup nginx
fi

logger -t "${LOG_TAG}" "Certificate sync complete. Reloaded nginx."
SCRIPT

sudo chmod +x /usr/local/bin/gitlab-cert-sync.sh
```

### 6.8 Create the systemd Service and Timer

```bash
sudo tee /etc/systemd/system/gitlab-cert-sync.service << 'EOF'
[Unit]
Description=Sync GitLab TLS certificate from OpenShift cert-manager
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gitlab-cert-sync.sh
StandardOutput=journal
StandardError=journal
EOF

sudo tee /etc/systemd/system/gitlab-cert-sync.timer << 'EOF'
[Unit]
Description=Sync GitLab TLS certificate every 30 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Unit=gitlab-cert-sync.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gitlab-cert-sync.timer
```

### 6.9 Run the First Sync and Verify

```bash
sudo systemctl start gitlab-cert-sync.service
systemctl status gitlab-cert-sync.service
journalctl -u gitlab-cert-sync.service -n 20
```

Expected in journal: `Certificate sync complete. Reloaded nginx.` with `status=0/SUCCESS`.

Verify the cert files and confirm nginx is serving the cert-manager issued certificate:

```bash
ls -la /etc/gitlab/ssl/
openssl x509 -noout -subject -issuer -dates \
  -in /etc/gitlab/ssl/gitlab.lab.example.internal.crt
```

Confirm nginx is serving the same cert (serials must match):

```bash
# Serial from the file on disk
openssl x509 -noout -serial \
  -in /etc/gitlab/ssl/gitlab.lab.example.internal.crt

# Serial from what nginx is serving
echo | openssl s_client \
  -connect gitlab.lab.example.internal:443 \
  -servername gitlab.lab.example.internal 2>/dev/null \
  | openssl x509 -noout -serial
```

Verify the timer schedule:

```bash
systemctl list-timers gitlab-cert-sync.timer
```

### 6.10 Enable HTTPS on GitLab

Edit `/etc/gitlab/gitlab.rb`:

```ruby
external_url 'https://gitlab.lab.example.internal'
nginx['ssl_certificate'] = "/etc/gitlab/ssl/gitlab.lab.example.internal.crt"
nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/gitlab.lab.example.internal.key"
nginx['redirect_http_to_https'] = true
```

Apply:

```bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
```

Update the firewall:

```bash
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --remove-service=http
sudo firewall-cmd --reload
```

Verify from the jump VM:

```bash
curl --cacert $HOME/pki/ca.crt https://gitlab.lab.example.internal
```

Expected: HTML redirect to `/users/sign_in`.

### 6.11 Update ArgoCD for HTTPS GitLab

Since GitLab no longer serves HTTP, update the ArgoCD repository Secret and add the CA to ArgoCD's trust store.

Add the Lab Internal CA to ArgoCD's TLS trust:

```bash
oc create configmap argocd-tls-certs-cm \
  -n openshift-gitops \
  --from-file=gitlab.lab.example.internal=$HOME/pki/ca.crt \
  --dry-run=client -o yaml | oc apply -f -
```

Update the repository Secret to use HTTPS and disable the `insecure` flag:

```bash
GITLAB_TOKEN=$(cat ~/.argocd-gitlab-token)

cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: openshift-gitops-gitlab-repo
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
  username: YOUR_GITLAB_USER
  password: "<GITLAB_TOKEN>"
  insecure: "false"
EOF
```

Verify ArgoCD is healthy after the change:

```bash
oc get application sample-app -n openshift-gitops \
  -o jsonpath='Sync: {.status.sync.status}, Health: {.status.health.status}{"\n"}'
```

Expected: `Health: Healthy`

---

## 8. Phase 4 — GitLab OAuth Application

> [!note] TLS Prerequisite
> OAuth redirect flows carry authorization codes in the URL. All OAuth endpoints must serve HTTPS — this is why Phase 2 (GitLab HTTPS) and Phase 3 (wildcard certificate) must be completed before configuring the identity provider.

### 7.1 Create Instance OAuth Application

In GitLab Admin area (`https://gitlab.lab.example.internal/admin/applications`) → **Add new application**:

| Field | Value |
|---|---|
| Name | `openshift` |
| Redirect URI | `https://oauth-openshift.apps.lab.example.internal/oauth2callback/gitlab` |
| Trusted | ✓ checked |
| Confidential | ✓ checked |
| Scopes | `read_user`, `openid` |

The callback URL format is fixed by OpenShift:
```
https://oauth-openshift.apps.<cluster-name>.<base-domain>/oauth2callback/<idp-name>
```

GitLab provides an **Application ID** (Client ID) and **Secret** after saving — copy both immediately, the secret is shown only once.

> [!note] Trusted application
> Checking **Trusted** skips the OAuth consent screen for users. Without this, every user sees "OpenShift wants to access your GitLab account — Allow?" on first login.

---

## 9. Phase 5 — OpenShift OAuth Configuration

### 8.1 Create the Client Secret

```bash
oc create secret generic gitlab-client-secret \
  --from-literal=clientSecret=<gitlab-oauth-secret> \
  -n openshift-config
```

### 8.2 Create the CA ConfigMap

This ConfigMap tells the OpenShift OAuth server to trust the Lab Internal CA when connecting to GitLab over HTTPS. Without it, the OAuth server rejects GitLab's certificate as untrusted.

```bash
oc create configmap gitlab-ca \
  --from-file=ca.crt=$HOME/pki/ca.crt \
  -n openshift-config
```

### 8.3 Configure the OAuth CR

```bash
cat << 'EOF' | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: gitlab
    mappingMethod: claim
    type: GitLab
    gitlab:
      clientID: <application-id-from-gitlab>
      clientSecret:
        name: gitlab-client-secret
      url: https://gitlab.lab.example.internal
      ca:
        name: gitlab-ca
EOF
```

**Key fields:**

| Field | Value | Purpose |
|---|---|---|
| `name` | `gitlab` | IDP name on login page and in the callback URL |
| `mappingMethod` | `claim` | Maps GitLab username directly to OpenShift username |
| `type` | `GitLab` | Uses the GitLab OAuth/OIDC integration |
| `clientID` | Application ID from GitLab | Identifies OpenShift to GitLab |
| `clientSecret.name` | `gitlab-client-secret` | Secret object containing the OAuth secret |
| `url` | `https://gitlab.lab.example.internal` | Self-hosted GitLab instance URL |
| `ca.name` | `gitlab-ca` | ConfigMap containing the CA cert |

### 8.4 Verify OAuth Pod Restarts

```bash
oc get pods -n openshift-authentication -w
```

The `oauth-openshift` pods restart automatically to pick up the new configuration. Wait until they return to `Running`.

---

## 10. Phase 6 — Grant cluster-admin via RBAC

### 9.1 Log in via GitLab

Navigate to the OpenShift console and select **gitlab** from the login options. On first login, OpenShift creates a `User` object for the authenticated user.

### 9.2 Verify the User Object Was Created

```bash
oc get users
```

Expected:
```
NAME                UID                                    FULL NAME           IDENTITIES
YOUR_GITLAB_USER   00000000-0000-0000-0000-000000000000   Example User       gitlab:42
```

`IDENTITIES` shows `gitlab:42` — authenticated via the GitLab IDP with example user ID 42.

> [!warning] Username case sensitivity
> OpenShift User objects are created with the exact username returned by the identity provider. GitLab returns the configured username. The `oc adm policy` command must use the exact same case.

### 9.3 Grant cluster-admin

```bash
oc adm policy add-cluster-role-to-user cluster-admin YOUR_GITLAB_USER
```

### 9.4 Verify RBAC

```bash
oc auth can-i '*' '*' --as=YOUR_GITLAB_USER
```

Expected: `yes`

---

## 11. CA Trust Distribution

The Lab Internal CA must be trusted on all client machines that access HTTPS services. One-time operation per machine.

### 10.1 Windows (Tailscale Workstation)

1. Copy `ca.crt` to the Windows workstation.
2. Double-click → **Install Certificate** → **Local Machine** → **Trusted Root Certification Authorities**.
3. Restart browser.

PowerShell alternative:
```powershell
Import-Certificate -FilePath "ca.crt" -CertStoreLocation "Cert:\LocalMachine\Root"
```

### 10.2 RHEL / Fedora

```bash
sudo cp ca.crt /etc/pki/ca-trust/source/anchors/lab-internal-ca.crt
sudo update-ca-trust
```

---

## 12. Verification Reference

### 11.1 Full Login Flow

1. Navigate to `https://console-openshift-console.apps.lab.example.internal`
2. Two login options appear: `kube:admin` and `gitlab`
3. Click `gitlab` — browser redirects to `https://gitlab.lab.example.internal`
4. GitLab authenticates the user
5. Browser redirects back to OpenShift console
6. User is logged in with their GitLab username

### 11.2 cert-manager Health

```bash
# Operator
oc get csv -n cert-manager-operator

# Operand pods
oc get pods -n cert-manager

# ClusterIssuer
oc get clusterissuer lab-internal-ca

# All certificates
oc get certificate -A
```

### 11.3 Certificate Expiry

```bash
# Wildcard cert
oc get secret wildcard-apps-stage-tls -n openshift-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# GitLab cert
oc get secret gitlab-tls -n lab-infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

cert-manager renews both certificates automatically 30 days before expiry. No manual action required.

### 11.4 Sync Timer Status

```bash
# On the GitLab VM
systemctl list-timers gitlab-cert-sync.timer
journalctl -u gitlab-cert-sync.service --since "1 hour ago"
```

### 11.5 Token Rotation

The sync script (`/usr/local/bin/gitlab-cert-sync.sh`) rotates its own token on every run. Each execution requests a fresh 24-hour bound token via `oc create token` and atomically overwrites the kubeconfig. No manual rotation is required.

Verify the token is being rotated by checking the journal after a sync run:

```bash
# On the GitLab VM
journalctl -u gitlab-cert-sync.service --since "1 hour ago" | grep "Token rotated"
```

Expected: `Token rotated successfully`

---

## 13. Troubleshooting Reference

| Issue | Cause | Fix |
|---|---|---|
| ClusterIssuer `READY: False` | Secret in wrong namespace or bad PEM | Verify `lab-ca-keypair` is in `cert-manager` namespace. Check `oc describe clusterissuer lab-internal-ca`. |
| Certificate stuck `READY: False` | ClusterIssuer name mismatch or webhook timeout | `oc describe certificate <name> -n <ns>` — check Events. |
| Router still serving old cert | IngressController patch not applied or pod not rolled | Verify: `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate}'`. Check rollout status. |
| `oc` not found under sudo | `/usr/local/bin` not in sudo secure path | `sudo ln -s /usr/local/bin/oc /usr/bin/oc` |
| Sync script permission denied on kubeconfig | `gitlab` user can't read root-owned file | Expected — the systemd service runs as root. Test with `sudo oc --kubeconfig=...`. |
| `oc create token` — token approach broken | Using old `sa.secrets[0].name` pattern | Use `oc create token gitlab-cert-sync -n lab-infra --duration=8760h` |
| nginx serving old cert after sync | Serials mismatch between file and live | `sudo systemctl start gitlab-cert-sync.service` then compare serials. |
| GitLab cert browser warning | CA not in Windows trust store | Install `ca.crt` into Trusted Root Certification Authorities (Section 9.1). |
| `authentication` operator `RouterCertsDegraded` | Lab Internal CA not in cluster proxy trust bundle — internal components cannot validate the wildcard cert on the router | Add CA to proxy trust bundle: `oc create configmap lab-ca-bundle --from-file=ca-bundle.crt=$HOME/pki/ca.crt -n openshift-config` then patch `proxy/cluster` with `trustedCA.name: lab-ca-bundle`. Wait 2-3 minutes for OAuth pods to roll. |
| OAuth `redirect_uri_mismatch` | Callback URL mismatch | Verify callback URL in GitLab application exactly matches OCP OAuth server URL. |
| `certificate signed by unknown authority` in OAuth pod | CA not in `gitlab-ca` ConfigMap | Verify ConfigMap in `openshift-config` namespace contains correct CA cert. |
| ArgoCD repo fails after HTTPS change | CA not in ArgoCD trust store | Verify `argocd-tls-certs-cm` ConfigMap in `openshift-gitops` namespace. |
| User object not created | User never logged in | First login via GitLab triggers User object creation. |
| `cluster-admin` not working | Wrong username case | `oc get users` — use exact username. OpenShift is case sensitive. |

---

## 14. Key Resource Reference

| Resource | Name | Namespace | Purpose |
|---|---|---|---|
| Operator namespace | `cert-manager-operator` | — | OLM manages operator here |
| cert-manager control plane | `cert-manager` | — | Controller, cainjector, webhook |
| CA Secret | `lab-ca-keypair` | `cert-manager` | Lab Internal CA key pair |
| ClusterIssuer | `lab-internal-ca` | cluster-scoped | Signs all leaf certificates |
| Wildcard Certificate CR | `wildcard-apps-stage` | `openshift-ingress` | Issues wildcard TLS Secret |
| Wildcard TLS Secret | `wildcard-apps-stage-tls` | `openshift-ingress` | Used by IngressController |
| GitLab namespace | `lab-infra` | — | GitLab cert and sync SA |
| GitLab Certificate CR | `gitlab-local-internal` | `lab-infra` | Issues GitLab TLS Secret |
| GitLab TLS Secret | `gitlab-tls` | `lab-infra` | Pulled by sync agent |
| GitLab sync ServiceAccount | `gitlab-cert-sync` | `lab-infra` | Read-only access to gitlab-tls |
| GitLab sync Role | `gitlab-cert-reader` | `lab-infra` | get on gitlab-tls + create token for self |
| GitLab kubeconfig | `/etc/gitlab/cert-sync/kubeconfig` | on GitLab VM | SA token + cluster CA |
| GitLab sync script | `/usr/local/bin/gitlab-cert-sync.sh` | on GitLab VM | Pulls cert, reloads nginx |
| GitLab TLS cert dir | `/etc/gitlab/ssl/` | on GitLab VM | nginx reads certs here |
| Proxy CA bundle | `lab-ca-bundle` | `openshift-config` | Injects Lab Internal CA into cluster proxy trust bundle — required for internal components to trust the wildcard cert |
| OAuth CR | `cluster` | `openshift-config` | Cluster-wide OAuth config |
| Client secret | `gitlab-client-secret` | `openshift-config` | GitLab OAuth app secret |
| CA ConfigMap (OAuth) | `gitlab-ca` | `openshift-config` | CA trust for OAuth server |
| CA ConfigMap (ArgoCD) | `argocd-tls-certs-cm` | `openshift-gitops` | CA trust for repo-server |
| User object | `Timur` | cluster-scoped | OpenShift user from GitLab |

---

## 15. Official References

* **[1] Red Hat cert-manager Operator**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift

* **[2] Configuring Ingress Certificates**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/configuring-certificates

* **[3] cert-manager ClusterIssuer — CA Issuer**
  https://cert-manager.io/docs/configuration/ca/

* **[4] Configuring a GitLab Identity Provider**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/authentication_and_authorization/configuring-identity-providers#configuring-gitlab-identity-provider

* **[5] oc create token (Kubernetes TokenRequest API)**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/authentication_and_authorization/using-service-accounts-in-applications
