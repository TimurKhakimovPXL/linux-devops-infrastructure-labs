> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 4: PKI, GitLab HTTPS, and Identity Provider

**Objective:** Create an internal CA, use cert-manager to renew the OpenShift and GitLab certificates, and let users sign in to OpenShift through GitLab.
**Target Environment:** Single Node OpenShift lab: Single Node OpenShift 4.21
**GitLab Instance:** `https://gitlab.lab.example.internal` (the GitLab VM: `192.168.50.30`)
**cert-manager Operator:** v1.18.1 (`stable-v1` channel)

---

## 1. Design Decisions and Scope

### 1.1 Certificate Inventory

| Certificate | Issued To | Namespace | Secret | Consumer |
|---|---|---|---|---|
| Wildcard | `*.apps.lab.example.internal` | `openshift-ingress` | `wildcard-apps-lab-tls` | IngressController default for Routes that use it |
| GitLab | `gitlab.lab.example.internal` | `lab-infra` | `gitlab-tls` | GitLab VM nginx via pull agent |

### 1.2 Design Decision: GitLab Certificate Delivery

cert-manager stores certificates as Kubernetes Secrets. GitLab runs on a separate VM at `192.168.50.30`, so cert-manager cannot write the certificate directly to its filesystem. I considered three ways to bridge that gap:

|                                 | Option 1: Pull agent (chosen)                           | Option 2: Push CronJob                                          | Option 3: GitLab in OpenShift                                           |
| ------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **Mechanism**                   | systemd timer on GitLab VM pulls cert from OpenShift API | Kubernetes CronJob SSHs into GitLab VM and copies cert           | GitLab runs as a container, cert-manager manages it natively via a Route |
| **Credentials stored**          | Least-privilege SA token on GitLab VM filesystem         | SSH private key as cluster Secret                                | N/A                                                                      |
| **Firewall direction**          | GitLab VM → OpenShift API (HTTPS/6443): already open    | OpenShift → GitLab VM (SSH/22): additional exposure             | N/A                                                                      |
| **Cluster knowledge of GitLab** | None: cluster does not need to know GitLab exists       | Cluster holds SSH credentials for an external VM                 | N/A                                                                      |
| **Complexity**                  | Low: 20-line bash script, logs to journal               | Medium: CronJob installs SSH client at runtime, harder to audit | High: full GitLab containerisation out of scope                         |
| **Fit for this lab**            | Good: narrow API access and no inbound SSH                | Poor: adds SSH keys and inbound access                            | Too large a change for this stage                                        |

**Decision: Option 1.** The GitLab VM already has outbound HTTPS access to the OpenShift API through `vmbr1`. Its ServiceAccount can read one Secret in one namespace. OpenShift stores no credentials for connecting back to the VM, and the pull script logs each run to the system journal.

I rejected Option 2 because an SSH key in the cluster would create a path back into the GitLab VM. Option 3 would require moving GitLab itself, which was outside this lab's scope.

### 1.3 GitOps Scope

I applied the cert-manager operator, ClusterIssuer, OAuth CR, RBAC, and namespace configuration directly with `oc apply`. Moving those cluster-scoped resources into ArgoCD also needs sync ordering and a way to manage secrets without committing plaintext values, so that work remains separate for now.

Application workloads from Target 3 onward still go through GitOps. The cluster infrastructure in this lab is managed directly.

These phases must be executed in sequence. Each is a prerequisite for the next.

```text
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

```text
  Lab Internal CA (ca.crt + ca.key)
  ~/pki/ on jump VM: import once, then remove the working private-key copy
           │
           │  imported as Kubernetes Secret
           ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                   SNO Cluster (192.168.50.20)                    │
  │                                                                  │
  │  namespace: cert-manager-operator                                │
  │  ┌─────────────────────────────────────────┐                     │
  │  │ Red Hat cert-manager Operator (OLM)     │                     │
  │  │ v1.18.1 · channel: stable-v1            │                     │
  │  └──────────────────┬──────────────────────┘                     │
  │                     │ manages                                    │
  │  namespace: cert-manager                                         │
  │  ┌─────────────────────────────────────────┐                     │
  │  │ cert-manager controller                 │                     │
  │  │ cert-manager cainjector                 │                     │
  │  │ cert-manager webhook                    │                     │
  │  │ Secret: lab-ca-keypair                  │                     │
  │  └──────────────────┬──────────────────────┘                     │
  │                     │                                            │
  │  ClusterIssuer: lab-internal-ca (cluster-scoped)                 │
  │                     │                                            │
  │            ┌────────┴─────────┐                                  │
  │            │                  │                                  │
  │  ns: openshift-ingress   ns: lab-infra                           │
  │  Certificate:             Certificate:                           │
  │    wildcard-apps-lab       gitlab-local-internal                 │
  │  Secret:                  Secret:                                │
  │    wildcard-apps-lab-tls   gitlab-tls                            │
  │                            ServiceAccount: gitlab-cert-sync      │
  │            │                  │                                  │
  └────────────┼──────────────────┼──────────────────────────────────┘
               │                  │
               ▼                  ▼ (HTTPS API pull, every 30 min)
  IngressController default   GitLab VM (192.168.50.30)
  Default cert for eligible   systemd timer
  console, ArgoCD, OAuth,     /etc/gitlab/ssl/ → nginx reload
  and application Routes
             │
             │ OAuth 2.0 over HTTPS
             ▼
  OpenShift OAuth Server
  identityProvider: GitLab
  ca: gitlab-ca ConfigMap (Lab Internal CA)
```

---

## 3. Known Limitations

The lab works with these limitations, but they would need attention before production use.

| #   | Limitation                                                                                                   | Impact                                                                                                                                                                           | Resolution Path                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| --- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Infrastructure layer (cert-manager, ClusterIssuer, OAuth CR, RBAC) applied via `oc apply`: not under GitOps | Cluster state can drift from documentation. Rebuild requires re-running all commands manually                                                                                    | Future target: commit all infra manifests to `cluster-configs/` in the GitOps repo with sync wave ordering and a secrets management solution (SealedSecrets or external-secrets-operator)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 2   | GitLab VM cert sync relies on a root-run systemd timer                                                       | Kubeconfig storage, timer health, and nginx reloads are managed outside the cluster                                                        | Run the pull under a dedicated user and allow only the nginx reload through `sudo`, or move GitLab and the sync job into rootless Quadlets. Deferred for this lab. |
| 3   | Bound ServiceAccount token on the GitLab VM | A stolen current token can read `gitlab-tls` and request a replacement token until it expires | The timer requests a fresh 24-hour token on each successful 30-minute run. This reduces token age but still depends on timer health, file permissions, and the current token remaining valid. |
| 4   | CA signing key stored in the `lab-ca-keypair` Secret | Moving the key out of the jump VM reduces copies but does not make the signing key offline; cluster compromise or Secret loss can expose or destroy it | Restrict Secret access, protect etcd and cluster backups, and keep an approved encrypted offline backup if CA recovery is required. `ca.crt` remains on the jump VM as a public trust anchor. |

---

## 4. Phase 0: Generate the Lab Internal CA

Generate the Lab Internal CA once on the jump VM, import it into cert-manager in Phase 1, and then remove the working private-key copy from the jump VM. In the recorded setup, the cluster Secret becomes the active signing-key store; that Secret and any approved encrypted backup must be protected separately.

### 4.1 PKI Directory

```bash
umask 077
mkdir -p "$HOME/pki"
cd "$HOME/pki"
```

### 4.2 Generate the CA Private Key and Certificate

```bash
# Generate CA private key (4096-bit RSA)
openssl genrsa -out ca.key 4096

# Generate self-signed CA certificate (10 year validity)
openssl req -new -x509 -days 3650 -key ca.key \
  -out ca.crt \
  -subj "/C=BE/ST=Flemish Brabant/L=Leuven/O=Infrastructure Lab/CN=Lab Internal CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
```

**Verify the CA:**

```bash
openssl x509 -in ~/pki/ca.crt -noout -text | grep -A4 "Subject\|Validity"
```

Expected output from the recorded run:

```text
Validity
    Not Before: Mar 19 12:48:49 2026 GMT
    Not After : Mar 16 12:48:49 2036 GMT
Subject: C=BE, ST=Flemish Brabant, L=Leuven, O=Infrastructure Lab, CN=Lab Internal CA
```

| File | Purpose |
|---|---|
| `ca.key` | CA private key: imported into cert-manager, then shredded from jump VM |
| `ca.crt` | CA public certificate: distributed to all trusting systems |

---

## 5. Phase 1: cert-manager Operator

### 5.1 Install via OLM

All commands are executed from the jump VM (`192.168.50.101`) with kubeconfig exported:

```bash
export KUBECONFIG=~/sno-install/auth/kubeconfig
```

Create the operator namespace:

```bash
oc new-project cert-manager-operator
```

Create the OperatorGroup. cert-manager Operator 1.18.1 supports narrower install modes, but Red Hat recommends `AllNamespaces` for versions 1.15 and later. An empty `spec` selects that mode; it does not deploy a separate operator into every namespace:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec: {}
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

`installPlanApproval: Automatic` follows updates published on `stable-v1`. The 1.18.1 CSV below records this lab run; the Subscription does not pin that patch release.

### 5.2 Verify Installation

Watch the CSV until `Succeeded`:

```bash
oc get csv -n cert-manager-operator -w
```

Expected final state from this run:

```console
NAME                              DISPLAY                                        VERSION   PHASE
cert-manager-operator.v1.18.1    cert-manager Operator for Red Hat OpenShift    1.18.1    Succeeded
```

Verify the three operand pods are running in the `cert-manager` namespace (note: separate from `cert-manager-operator`):

```bash
oc get pods -n cert-manager
```

Expected: all three must be `Running` before proceeding:

```console
NAME                                       READY   STATUS
cert-manager-xxxxxxxxxx-xxxxx              1/1     Running
cert-manager-cainjector-xxxxxxxxxx-xxxxx   1/1     Running
cert-manager-webhook-xxxxxxxxxx-xxxxx      1/1     Running
```

> [!NOTE]
> **Two Namespaces**
> `cert-manager-operator`: OLM manages the operator here.
> `cert-manager`: the operator runs the controller, cainjector, and webhook here. CA Secrets referenced by ClusterIssuers must live in `cert-manager`.

### 5.3 Import the Lab Internal CA

Create the CA Secret in the `cert-manager` namespace:

```bash
oc create secret tls lab-ca-keypair \
  --namespace cert-manager \
  --cert=$HOME/pki/ca.crt \
  --key=$HOME/pki/ca.key
```

This command sends the CA private key to the cluster Secret. Confirm that cluster backups and RBAC meet the lab's recovery and access requirements before deleting the jump-VM copy. Do not commit either key material or the generated Secret YAML.

> [!NOTE]
> **`$HOME` not `~`**
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

```console
NAME                READY   STATUS                AGE
lab-internal-ca   True    Signing CA verified   Xs
```

If `READY` is `False`, check `oc describe clusterissuer lab-internal-ca`: the condition message will identify whether the issue is the Secret namespace, PEM formatting, or a webhook timeout.

After the issuer is ready and any approved encrypted backup has been verified, remove the working private-key copy from the jump VM:

```bash
shred -u "$HOME/pki/ca.key"
```

---

## 6. Phase 2: Wildcard Certificate for OpenShift Ingress

### 6.1 Issue the Certificate

The Certificate resource must be in `openshift-ingress` so the resulting Secret is co-located with the IngressController pods:

```bash
cat << 'EOF' | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-apps-lab
  namespace: openshift-ingress
spec:
  secretName: wildcard-apps-lab-tls
  dnsNames:
    - "*.apps.lab.example.internal"
  issuerRef:
    kind: ClusterIssuer
    name: lab-internal-ca
    group: cert-manager.io
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  duration: 2160h
  renewBefore: 720h
EOF
```

The manifest explicitly requests a 90-day certificate and renewal 30 days before expiry. `rotationPolicy: Always` also makes the private-key behavior independent of version-specific defaults.

> [!NOTE]
> **rotationPolicy warning**
> Earlier versions of this manifest omitted `spec.privateKey.rotationPolicy`, which produced a warning after the v1.18 default changed. It is now set explicitly to `Always`.

Verify issuance:

```bash
oc get certificate wildcard-apps-lab -n openshift-ingress
```

Expected:

```console
NAME                  READY   SECRET                    AGE
wildcard-apps-lab   True    wildcard-apps-lab-tls   Xs
```

### 6.2 Patch the IngressController

```bash
oc patch ingresscontroller default \
  -n openshift-ingress-operator \
  --type=merge \
  --patch='{"spec": {"defaultCertificate": {"name": "wildcard-apps-lab-tls"}}}'
```

Watch the router pod roll:

```bash
oc rollout status deployment/router-default -n openshift-ingress
```

### 6.3 Inject the Lab Internal CA into the Cluster Proxy Trust Bundle

After patching the wildcard cert onto the IngressController, OpenShift internal components, including the OAuth server, validate the router certificate against the cluster proxy trust bundle. In this lab, omitting the Lab Internal CA caused the authentication operator to report `RouterCertsDegraded`.

```bash
oc create configmap lab-ca-bundle \
  --from-file=ca-bundle.crt=$HOME/pki/ca.crt \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

oc patch proxy/cluster \
  --type=merge \
  --patch='{"spec": {"trustedCA": {"name": "lab-ca-bundle"}}}'
```

Wait for the authentication operator to recover: it will roll its pods to pick up the new trust bundle:

```bash
oc get clusteroperators authentication -w
```

Wait until `AVAILABLE=True, PROGRESSING=False, DEGRADED=False`. On SNO this takes 2-3 minutes as there is only one node and zero pods are available briefly during the rollout.

Then verify all operators are healthy:

```bash
oc get clusteroperators | grep -v "True.*False.*False"
```

Expected: the header line only.

### 6.4 Verify the Certificate is Served

```bash
echo | openssl s_client \
  -connect console-openshift-console.apps.lab.example.internal:443 \
  -servername console-openshift-console.apps.lab.example.internal 2>/dev/null \
  | openssl x509 -noout -text | grep -A2 "Subject Alternative"
```

Expected:

```text
X509v3 Subject Alternative Name: critical
    DNS:*.apps.lab.example.internal
```

---

## 7. Phase 3: GitLab Certificate Automation (Pull-Based Agent)

cert-manager issues and auto-renews the GitLab certificate as a Kubernetes Secret. A systemd timer on the GitLab VM pulls the current cert from the OpenShift API on a 30-minute schedule and reloads nginx. During normal operation, the timer also renews its bounded API token; an outage longer than that token's actual lifetime needs the recovery step in Section 12.5.

### 7.1 Create the Namespace and Certificate

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
    rotationPolicy: Always
  duration: 2160h
  renewBefore: 720h
EOF
```

```bash
oc get certificate gitlab-local-internal -n lab-infra
# Wait for READY: True
```

### 7.2 Create the ServiceAccount and RBAC

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

### 7.3 Generate the ServiceAccount Token

> [!WARNING]
> **OCP 4.21 / Kubernetes 1.24+ Token Change**
> ServiceAccounts no longer receive auto-created token Secrets in Kubernetes 1.24+. The `sa.secrets[0].name` pattern used in older documentation does not work. Use `oc create token` with an explicit duration.

```bash
umask 077
oc create token gitlab-cert-sync \
  -n lab-infra \
  --duration=24h \
  > /tmp/gitlab-cert-sync-token.txt

chmod 600 /tmp/gitlab-cert-sync-token.txt
```

### 7.4 Build the kubeconfig

The kubeconfig embeds the cluster CA so the `oc` client on the GitLab VM can verify the API server TLS certificate without additional system trust configuration. Run this on the same secured jump VM used above:

```bash
umask 077
APISERVER=$(oc whoami --show-server)
CA_DATA=$(oc config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
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
unset TOKEN CA_DATA APISERVER
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
  labuser@192.168.50.30:/tmp/gitlab-cert-sync-kubeconfig.yaml
```

Clean up from the jump VM:

```bash
shred -u /tmp/gitlab-cert-sync-token.txt /tmp/gitlab-cert-sync-kubeconfig.yaml
```

### 7.5 Install `oc` on the GitLab VM

`openshift-clients` was not available in the default RHEL 10 repositories used for this VM. The recorded cluster ran 4.21.4, so this uses that exact x86_64 client archive and verifies it against the checksum published in the same release directory before extracting `oc`:

```bash
# On the GitLab VM as labuser
OCP_CLIENT_VERSION=4.21.4
OCP_CLIENT_BASE="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_CLIENT_VERSION}"

curl -fL \
  "${OCP_CLIENT_BASE}/openshift-client-linux.tar.gz" \
  -o /tmp/openshift-client-linux.tar.gz
curl -fL "${OCP_CLIENT_BASE}/sha256sum.txt" -o /tmp/openshift-sha256sum.txt

grep ' openshift-client-linux.tar.gz$' /tmp/openshift-sha256sum.txt \
  | (cd /tmp && sha256sum -c -)
sudo tar -xzf /tmp/openshift-client-linux.tar.gz -C /usr/local/bin oc

# Symlink into sudo's secure path
sudo ln -sf /usr/local/bin/oc /usr/bin/oc

oc version --client
rm -f /tmp/openshift-client-linux.tar.gz /tmp/openshift-sha256sum.txt
```

### 7.6 Stage the kubeconfig

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

### 7.7 Create the Pull Script

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

# Pull into temporary files in the destination directory so the current
# certificate remains intact if the API request or validation fails.
TEMP_DIR=$(mktemp -d "${CERT_DIR}/.gitlab-cert-sync.XXXXXX")
trap 'rm -rf "${TEMP_DIR}"' EXIT

oc --kubeconfig="${KUBECONFIG}" \
  -n "${NAMESPACE}" \
  get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${TEMP_DIR}/tls.crt"

oc --kubeconfig="${KUBECONFIG}" \
  -n "${NAMESPACE}" \
  get secret "${SECRET_NAME}" \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "${TEMP_DIR}/tls.key"

openssl x509 -in "${TEMP_DIR}/tls.crt" -noout -checkend 3600
CERT_PUBKEY=$(openssl x509 -in "${TEMP_DIR}/tls.crt" -pubkey -noout | sha256sum)
KEY_PUBKEY=$(openssl pkey -in "${TEMP_DIR}/tls.key" -pubout | sha256sum)
test "${CERT_PUBKEY}" = "${KEY_PUBKEY}"

install -m 0644 "${TEMP_DIR}/tls.crt" "${CERT_DIR}/gitlab.lab.example.internal.crt"
install -m 0600 "${TEMP_DIR}/tls.key" "${CERT_DIR}/gitlab.lab.example.internal.key"

# Rotate the token: request a fresh 24h token using the current token
NEW_TOKEN=$(oc --kubeconfig="${KUBECONFIG}" \
  create token gitlab-cert-sync \
  -n "${NAMESPACE}" \
  --duration=24h)

# Atomically update the token in the kubeconfig via temp file
TEMP_KUBECONFIG=$(mktemp "${KUBECONFIG}.tmp.XXXXXX")
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

### 7.8 Create the systemd Service and Timer

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

### 7.9 Run the First Sync and Verify

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

### 7.10 Enable HTTPS on GitLab

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

### 7.11 Update ArgoCD for HTTPS GitLab

Since GitLab no longer serves HTTP, update the ArgoCD repository Secret and add the CA to ArgoCD's trust store.

Add the Lab Internal CA to ArgoCD's TLS trust:

```bash
oc create configmap argocd-tls-certs-cm \
  -n openshift-gitops \
  --from-file=gitlab.lab.example.internal=$HOME/pki/ca.crt \
  --dry-run=client -o yaml | oc apply -f -
```

Update the repository Secret to use HTTPS. With the CA installed above, no `insecure` override is needed:

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
  password: "${GITLAB_TOKEN}"
EOF

unset GITLAB_TOKEN
```

Verify ArgoCD is healthy after the change:

```bash
oc get application sample-app -n openshift-gitops \
  -o jsonpath='Sync: {.status.sync.status}, Health: {.status.health.status}{"\n"}'
```

Expected: `Health: Healthy`

---

## 8. Phase 4: GitLab OAuth Application

> [!NOTE]
> **TLS Prerequisite**
> This lab uses HTTPS for both sides of the OAuth redirect flow so credentials and authorization codes are not exposed on the network. Complete the GitLab HTTPS and wildcard-certificate work before configuring the identity provider.

### 8.1 Create Instance OAuth Application

In GitLab Admin area (`https://gitlab.lab.example.internal/admin/applications`) → **Add new application**:

| Field | Value |
|---|---|
| Name | `openshift` |
| Redirect URI | `https://oauth-openshift.apps.lab.example.internal/oauth2callback/gitlab` |
| Trusted | ✓ checked |
| Confidential | ✓ checked |
| Scopes | `read_user` |

The callback URL format is fixed by OpenShift:

```text
https://oauth-openshift.apps.<cluster-name>.<base-domain>/oauth2callback/<idp-name>
```

GitLab shows an **Application ID** (Client ID) and **Secret** after saving. Copy both immediately because the secret is shown only once.

> [!NOTE]
> **Trusted application**
> Checking **Trusted** skips the OAuth consent screen for users. Without this, every user sees "OpenShift wants to access your GitLab account: Allow?" on first login.

---

## 9. Phase 5: OpenShift OAuth Configuration

### 9.1 Create the Client Secret

```bash
read -rsp "GitLab OAuth application secret: " GITLAB_OAUTH_SECRET
echo
oc create secret generic gitlab-client-secret \
  --from-literal=clientSecret="${GITLAB_OAUTH_SECRET}" \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -
unset GITLAB_OAUTH_SECRET
```

### 9.2 Create the CA ConfigMap

This ConfigMap tells the OpenShift OAuth server to trust the Lab Internal CA when connecting to GitLab over HTTPS. Without it, the OAuth server rejects GitLab's certificate as untrusted.

```bash
oc create configmap gitlab-ca \
  --from-file=ca.crt=$HOME/pki/ca.crt \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -
```

### 9.3 Configure the OAuth CR

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
      clientID: "<application-id-from-gitlab>"
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
| `mappingMethod` | `claim` | Uses the identity provider's preferred username when mapping the OpenShift user |
| `type` | `GitLab` | Uses OpenShift's built-in GitLab OAuth integration |
| `clientID` | Application ID from GitLab | Identifies OpenShift to GitLab |
| `clientSecret.name` | `gitlab-client-secret` | Secret object containing the OAuth secret |
| `url` | `https://gitlab.lab.example.internal` | Self-hosted GitLab instance URL |
| `ca.name` | `gitlab-ca` | ConfigMap containing the CA cert |

### 9.4 Verify OAuth Pod Restarts

```bash
oc get pods -n openshift-authentication -w
```

The `oauth-openshift` pods restart automatically to pick up the new configuration. Wait until they return to `Running`.

---

## 10. Phase 6: Grant cluster-admin via RBAC

### 10.1 Log in via GitLab

Navigate to the OpenShift console and select **gitlab** from the login options. On first login, OpenShift creates a `User` object for the authenticated user.

### 10.2 Verify the User Object Was Created

```bash
oc get users
```

Expected:
```console
NAME                UID                                    FULL NAME           IDENTITIES
YOUR_GITLAB_USER   00000000-0000-0000-0000-000000000000   Example User       gitlab:42
```

`IDENTITIES` shows `gitlab:42`: authenticated via the GitLab IDP with example user ID 42.

> [!WARNING]
> **Username case sensitivity**
> OpenShift User objects are created with the exact username returned by the identity provider. GitLab returns the configured username. The `oc adm policy` command must use the exact same case.

### 10.3 Grant cluster-admin

This is the lab administrator account. Do not grant `cluster-admin` to every user authenticated through the GitLab provider; bind narrower roles for ordinary users.

```bash
oc adm policy add-cluster-role-to-user cluster-admin YOUR_GITLAB_USER
```

### 10.4 Verify RBAC

```bash
oc auth can-i '*' '*' --as=YOUR_GITLAB_USER
```

Expected: `yes`

---

## 11. CA Trust Distribution

The Lab Internal CA must be trusted on all client machines that access HTTPS services. One-time operation per machine.

### 11.1 Windows (Tailscale Workstation)

1. Copy `ca.crt` to the Windows workstation.
2. Double-click → **Install Certificate** → **Local Machine** → **Trusted Root Certification Authorities**.
3. Restart browser.

PowerShell alternative:
```powershell
Import-Certificate -FilePath "ca.crt" -CertStoreLocation "Cert:\LocalMachine\Root"
```

### 11.2 RHEL / Fedora

```bash
sudo cp ca.crt /etc/pki/ca-trust/source/anchors/lab-internal-ca.crt
sudo update-ca-trust
```

---

## 12. Verification Reference

### 12.1 Full Login Flow

1. Navigate to `https://console-openshift-console.apps.lab.example.internal`
2. Two login options appear: `kube:admin` and `gitlab`
3. Click `gitlab`: browser redirects to `https://gitlab.lab.example.internal`
4. GitLab authenticates the user
5. Browser redirects back to OpenShift console
6. User is logged in with their GitLab username

### 12.2 cert-manager Health

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

### 12.3 Certificate Expiry

```bash
# Wildcard cert
oc get secret wildcard-apps-lab-tls -n openshift-ingress \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# GitLab cert
oc get secret gitlab-tls -n lab-infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

cert-manager requests renewal 30 days before expiry. Delivery to GitLab still depends on the sync timer, token rotation, and nginx reload succeeding.

### 12.4 Sync Timer Status

```bash
# On the GitLab VM
systemctl list-timers gitlab-cert-sync.timer
journalctl -u gitlab-cert-sync.service --since "1 hour ago"
```

### 12.5 Token Rotation

The sync script (`/usr/local/bin/gitlab-cert-sync.sh`) rotates its own token on every successful run. Each execution requests a fresh 24-hour bound token via `oc create token` and atomically overwrites the kubeconfig. During healthy operation this avoids a separate manual rotation step; an outage longer than the token lifetime requires a new token to be staged from the jump VM.

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
| Certificate stuck `READY: False` | ClusterIssuer name mismatch or webhook timeout | `oc describe certificate <name> -n <ns>`: check Events. |
| Router still serving old cert | IngressController patch not applied or pod not rolled | Verify: `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate}'`. Check rollout status. |
| `oc` not found under sudo | `/usr/local/bin` not in sudo secure path | `sudo ln -s /usr/local/bin/oc /usr/bin/oc` |
| Sync script permission denied on kubeconfig | `gitlab` user can't read root-owned file | Expected: the systemd service runs as root. Test with `sudo oc --kubeconfig=...`. |
| `oc create token`: token approach broken | Using old `sa.secrets[0].name` pattern | Use `oc create token gitlab-cert-sync -n lab-infra --duration=24h`; the API server may cap requested durations. |
| nginx serving old cert after sync | Serials mismatch between file and live | `sudo systemctl start gitlab-cert-sync.service` then compare serials. |
| GitLab cert browser warning | CA not in Windows trust store | Install `ca.crt` into Trusted Root Certification Authorities (Section 11.1). |
| `authentication` operator `RouterCertsDegraded` | Lab Internal CA not in cluster proxy trust bundle: internal components cannot validate the wildcard cert on the router | Add CA to proxy trust bundle: `oc create configmap lab-ca-bundle --from-file=ca-bundle.crt=$HOME/pki/ca.crt -n openshift-config` then patch `proxy/cluster` with `trustedCA.name: lab-ca-bundle`. Wait 2-3 minutes for OAuth pods to roll. |
| OAuth `redirect_uri_mismatch` | Callback URL mismatch | Verify callback URL in GitLab application exactly matches OCP OAuth server URL. |
| `certificate signed by unknown authority` in OAuth pod | CA not in `gitlab-ca` ConfigMap | Verify ConfigMap in `openshift-config` namespace contains correct CA cert. |
| ArgoCD repo fails after HTTPS change | CA not in ArgoCD trust store | Verify `argocd-tls-certs-cm` ConfigMap in `openshift-gitops` namespace. |
| User object not created | User never logged in | First login via GitLab triggers User object creation. |
| `cluster-admin` not working | Wrong username case | `oc get users`: use exact username. OpenShift is case sensitive. |

---

## 14. Key Resource Reference

| Resource | Name | Namespace | Purpose |
|---|---|---|---|
| Operator namespace | `cert-manager-operator` | - | OLM manages operator here |
| cert-manager control plane | `cert-manager` | - | Controller, cainjector, webhook |
| CA Secret | `lab-ca-keypair` | `cert-manager` | Lab Internal CA key pair |
| ClusterIssuer | `lab-internal-ca` | cluster-scoped | Signs all leaf certificates |
| Wildcard Certificate CR | `wildcard-apps-lab` | `openshift-ingress` | Issues wildcard TLS Secret |
| Wildcard TLS Secret | `wildcard-apps-lab-tls` | `openshift-ingress` | Used by IngressController |
| GitLab namespace | `lab-infra` | - | GitLab cert and sync SA |
| GitLab Certificate CR | `gitlab-local-internal` | `lab-infra` | Issues GitLab TLS Secret |
| GitLab TLS Secret | `gitlab-tls` | `lab-infra` | Pulled by sync agent |
| GitLab sync ServiceAccount | `gitlab-cert-sync` | `lab-infra` | Read-only access to gitlab-tls |
| GitLab sync Role | `gitlab-cert-reader` | `lab-infra` | get on gitlab-tls + create token for self |
| GitLab kubeconfig | `/etc/gitlab/cert-sync/kubeconfig` | on GitLab VM | SA token + cluster CA |
| GitLab sync script | `/usr/local/bin/gitlab-cert-sync.sh` | on GitLab VM | Pulls cert, reloads nginx |
| GitLab TLS cert dir | `/etc/gitlab/ssl/` | on GitLab VM | nginx reads certs here |
| Proxy CA bundle | `lab-ca-bundle` | `openshift-config` | Injects Lab Internal CA into cluster proxy trust bundle: required for internal components to trust the wildcard cert |
| OAuth CR | `cluster` | `openshift-config` | Cluster-wide OAuth config |
| Client secret | `gitlab-client-secret` | `openshift-config` | GitLab OAuth app secret |
| CA ConfigMap (OAuth) | `gitlab-ca` | `openshift-config` | CA trust for OAuth server |
| CA ConfigMap (ArgoCD) | `argocd-tls-certs-cm` | `openshift-gitops` | CA trust for repo-server |
| User object | `YOUR_GITLAB_USER` | cluster-scoped | OpenShift user from GitLab |

---

## 15. Official References

* **[1] Red Hat cert-manager Operator**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/cert-manager-operator-for-red-hat-openshift

* **[2] Configuring Ingress Certificates**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/configuring-certificates

* **[3] cert-manager ClusterIssuer: CA Issuer**
  https://cert-manager.io/docs/configuration/ca/

* **[4] Configuring a GitLab Identity Provider**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/authentication_and_authorization/configuring-identity-providers#configuring-gitlab-identity-provider

* **[5] oc create token (Kubernetes TokenRequest API)**
  https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/authentication_and_authorization/using-service-accounts-in-applications
