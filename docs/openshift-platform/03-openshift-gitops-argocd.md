> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 3: Configure OpenShift GitOps (ArgoCD)

**Objective:** Install the OpenShift GitOps operator and use ArgoCD to deploy manifests from a private GitLab repository to the SNO cluster.
**Target Environment:** Single Node OpenShift lab: Single Node OpenShift 4.21
**Operator Version:** Red Hat OpenShift GitOps 1.19.2

---

## 1. Concept Overview

### 1.1 What is GitOps?

GitOps is an operational model where a **Git repository is the single source of truth** for the desired state of your cluster. Instead of running `oc apply` manually, you commit manifests to Git and a controller (ArgoCD) continuously reconciles the cluster to match.

The reconciliation loop:

```
Developer commits manifest → Git repository (GitLab)
                                      ↓
                          ArgoCD polls repo every 3 minutes
                                      ↓
                    ArgoCD detects diff between Git and cluster
                                      ↓
                       ArgoCD applies changes to cluster
                                      ↓
                         Cluster state matches Git state
```

For this lab, that gives us:
- No manual `oc apply` for deployments
- Every change is version-controlled and auditable
- If someone manually changes something in the cluster, ArgoCD reverts it (`selfHeal`)
- If a manifest is deleted from Git, the resource is deleted from the cluster (`prune`)

### 1.2 Key Components

| Component | Role |
|---|---|
| **OpenShift GitOps Operator** | OLM-managed operator that installs and manages ArgoCD |
| **ArgoCD** | The GitOps controller: watches Git, syncs to cluster |
| **Application CR** | Kubernetes custom resource that tells ArgoCD what repo/path to watch and where to deploy |
| **AppProject** | Defines source repo and destination restrictions. The `default` project allows everything |
| **Repo Secret** | A Kubernetes Secret storing Git credentials so ArgoCD can clone private repos |

### 1.3 Operator Version Compatibility

| GitOps Version | ArgoCD | OCP Support |
|---|---|---|
| **1.19.x** | 3.1.9 | 4.14, 4.16–**4.21** |
| 1.18.x | 3.1.6 | 4.14, 4.16–4.20 |
| 1.17.x | 3.0.12 | 4.12–4.19 |

> [!note] Breaking change in 1.19
> The default resource tracking method changed from **label-based** to **annotation-based**. On a fresh install this requires no action. When upgrading from 1.18.x, remediation steps are required.

---

## 2. Prerequisites

### 2.1 GitLab Repository

The repository already exists and contains the manifests used in this lab:

```
http://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
```

**Repository structure:**

```
openshift-gitops/
├── README.md
├── apps/
│   └── sample-app/
│       └── deployment.yaml     ← Target 3 test workload
└── cluster-configs/
    ├── gitops-operator/        ← Operator installation manifests
    └── argocd/                 ← ArgoCD Application manifests
```

### 2.2 GitLab Personal Access Token

ArgoCD needs read access to the private repository. The GitLab Personal Access Token (PAT) uses these settings:

| Field | Value |
|---|---|
| Name | `argocd` |
| Scopes | `read_repository` only |
| Storage | `~/.argocd-gitlab-token` on the jump VM (chmod 600) |

> [!warning] Token Security
> Never paste tokens into chat interfaces, commit them to Git, or store them in world-readable files. The token is stored with `chmod 600` and referenced via shell variable during Secret creation.

### 2.3 Cluster Access

All commands are executed from the jump VM (`192.168.50.101`) with kubeconfig exported:

```bash
export KUBECONFIG=~/sno-install/auth/kubeconfig
oc get nodes
```

Expected output:
```
NAME      STATUS   ROLES                         AGE   VERSION
master0   Ready    control-plane,master,worker   12d   v1.34.4
```

---

## 3. Step 1: Install the OpenShift GitOps Operator

The operator is installed via OLM (Operator Lifecycle Manager) using three objects: a `Namespace`, an `OperatorGroup`, and a `Subscription`.

### 3.1 Create the Operator Namespace

```bash
oc create namespace openshift-gitops-operator
```

### 3.2 Create the OperatorGroup

```bash
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  upgradeStrategy: Default
EOF
```

An `OperatorGroup` scopes which namespaces an operator watches. The `upgradeStrategy: Default` means OLM manages upgrades automatically within the subscribed channel.

### 3.3 Create the Subscription

```bash
cat << 'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-gitops-operator
spec:
  channel: latest
  installPlanApproval: Automatic
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

The `Subscription` tells OLM which operator to install, from which catalog (`redhat-operators`), and on which update channel (`latest`). `installPlanApproval: Automatic` means upgrades within the channel apply without manual approval.

### 3.4 Verify Installation

Watch the ClusterServiceVersion (CSV) progress through its installation phases:

```bash
oc get csv -n openshift-gitops-operator -w
```

Expected progression:
```
NAME                                DISPLAY                    VERSION   PHASE
openshift-gitops-operator.v1.19.2   Red Hat OpenShift GitOps   1.19.2    Pending
openshift-gitops-operator.v1.19.2   Red Hat OpenShift GitOps   1.19.2    InstallReady
openshift-gitops-operator.v1.19.2   Red Hat OpenShift GitOps   1.19.2    Installing
openshift-gitops-operator.v1.19.2   Red Hat OpenShift GitOps   1.19.2    Succeeded
```

Installation is complete when `PHASE` shows `Succeeded`.

---

## 4. Step 2: Verify the ArgoCD Instance

After the operator reaches `Succeeded`, it **automatically provisions** a fully configured ArgoCD instance in the `openshift-gitops` namespace. No additional configuration is required.

### 4.1 Verify All Pods Are Running

```bash
oc get pods -n openshift-gitops
```

Expected output (all 8 pods must be Running):

```
NAME                                                          READY   STATUS
cluster-58ff748fd6-qlbqz                                      1/1     Running
gitops-plugin-5966f98946-t2l8h                                1/1     Running
openshift-gitops-application-controller-0                     1/1     Running
openshift-gitops-applicationset-controller-6586b7d6d6-jsv8h   1/1     Running
openshift-gitops-dex-server-6d947b66fb-gc77w                  1/1     Running
openshift-gitops-redis-79d7b4df5b-rgxcc                       1/1     Running
openshift-gitops-repo-server-76b47f79d9-jftfx                 1/1     Running
openshift-gitops-server-767dcbd5cb-27f4r                      1/1     Running
```

| Pod | Role |
|---|---|
| `application-controller` | Core sync engine: watches Git and reconciles cluster state |
| `repo-server` | Clones Git repositories and renders manifests |
| `server` | ArgoCD API server and web UI |
| `dex-server` | OpenShift OAuth integration |
| `redis` | Caching layer for application state |
| `applicationset-controller` | Manages ApplicationSet resources (multi-app templating) |
| `cluster` | GitOps plugin for the OCP web console |
| `gitops-plugin` | UI integration with the OpenShift console |

### 4.2 Verify ArgoCD CR Status

```bash
oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.status.phase}{"\n"}'
```

Expected output:
```
Available
```

### 4.3 Retrieve the ArgoCD UI URL

The operator automatically creates an OpenShift Route (not a Kubernetes Ingress) for the ArgoCD UI:

```bash
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}'
```

The URL resolves to:
```
https://openshift-gitops-server-openshift-gitops.apps.lab.example.internal
```

This is covered by the existing wildcard DNS record `*.apps.lab.example.internal → 192.168.50.20` and is accessible from the Windows workstation via Tailscale split DNS.

### 4.4 Retrieve the Admin Password

> [!warning] OpenShift GitOps does NOT use `argocd-initial-admin-secret`
> The upstream ArgoCD admin secret does not exist in OpenShift GitOps. The password is stored in a secret named `openshift-gitops-cluster` in the `openshift-gitops` namespace.

```bash
oc get secret openshift-gitops-cluster \
  -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 --decode && echo
```

---

## 5. Step 3: Register the GitLab Repository

ArgoCD needs a credential Secret to clone the private GitLab repository. The Secret must carry the label `argocd.argoproj.io/secret-type: repository` so ArgoCD's repo-server recognizes it.

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
  url: http://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
  username: YOUR_GITLAB_USER
  password: "<GITLAB_TOKEN>"
  insecure: "true"
EOF
```

`insecure: "true"` is required because the GitLab instance uses HTTP only: no TLS certificate is present for ArgoCD to verify.

**Verify the Secret was created correctly:**

```bash
oc get secret openshift-gitops-gitlab-repo -n openshift-gitops \
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}{"\n"}'
```

Expected: `repository`

```bash
oc get secret openshift-gitops-gitlab-repo -n openshift-gitops \
  -o jsonpath='{.data.url}' | base64 --decode && echo
```

Expected: `http://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git`

---

## 6. Step 4: Prepare the Target Namespace

ArgoCD's application controller only has permissions within its own `openshift-gitops` namespace by default. Deploying to any other namespace requires explicit RBAC.

### 6.1 Create the Namespace

```bash
oc create namespace sample-app
```

### 6.2 Grant ArgoCD Access via Label

Applying the `argocd.argoproj.io/managed-by` label to a namespace triggers the GitOps Operator to automatically create a `Role` and `RoleBinding` granting the ArgoCD application controller admin-equivalent access within that namespace.

```bash
oc label namespace sample-app argocd.argoproj.io/managed-by=openshift-gitops
```

### 6.3 Verify RBAC Was Created Automatically

```bash
oc get rolebindings -n sample-app
```

Expected output: the operator creates these automatically upon seeing the label:

```
NAME                                             ROLE                                                  AGE
openshift-gitops-argocd-application-controller   Role/openshift-gitops-argocd-application-controller   15s
openshift-gitops-argocd-server                   Role/openshift-gitops-argocd-server                   15s
system:deployers                                 ClusterRole/system:deployer                           15s
system:image-builders                            ClusterRole/system:image-builder                      15s
```

The two `openshift-gitops-argocd-*` RoleBindings are the critical ones: they give ArgoCD permission to create, update, and delete resources in `sample-app`.

---

## 7. Step 5: Create the ArgoCD Application

The `Application` CR is the core GitOps object. It defines what Git repo to watch, which path within the repo contains manifests, and where in the cluster to deploy them.

```bash
cat << 'EOF' | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sample-app
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: http://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
    targetRevision: main
    path: apps/sample-app
  destination:
    server: https://kubernetes.default.svc
    namespace: sample-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
```

**Key fields explained:**

| Field | Value | Why |
|---|---|---|
| `namespace` (metadata) | `openshift-gitops` | Application CRs must live in the ArgoCD control plane namespace |
| `project` | `default` | The default AppProject has no source/destination restrictions |
| `repoURL` | GitLab HTTP URL | The repo ArgoCD will clone |
| `targetRevision` | `main` | Git branch to track |
| `path` | `apps/sample-app` | Directory within the repo containing manifests |
| `destination.server` | `https://kubernetes.default.svc` | Local cluster (the one ArgoCD runs on) |
| `destination.namespace` | `sample-app` | Target namespace for all deployed resources |
| `automated.prune` | `true` | Delete cluster resources when removed from Git |
| `automated.selfHeal` | `true` | Revert manual cluster changes within 5 seconds |
| `CreateNamespace=false` | - | Namespace already exists and is labeled, so do not recreate it |
| `ServerSideApply=true` | - | Recommended for OpenShift; avoids annotation size limit errors |

---

## 8. Step 6: Verify the Deployment

### 8.1 Check Application Sync and Health Status

```bash
oc get application sample-app -n openshift-gitops \
  -o jsonpath='Sync: {.status.sync.status}, Health: {.status.health.status}{"\n"}'
```

Expected output:
```
Sync: Synced, Health: Healthy
```

### 8.2 Verify the Pod Is Running

```bash
oc get pods -n sample-app
```

Expected output:
```
NAME                          READY   STATUS    RESTARTS   AGE
sample-app-66ccd96b9b-dn6ld   1/1     Running   0          19s
```

### 8.3 Understanding the Status Axes

Sync status and health status are **independent**:

**Sync Status**: does the cluster match Git?

| Status | Meaning |
|---|---|
| `Synced` | Cluster resources match the Git manifests exactly |
| `OutOfSync` | A manifest changed in Git, or a resource was manually edited in the cluster |
| `Unknown` | ArgoCD cannot reach Git or the Kubernetes API |

**Health Status**: are the resources actually working?

| Status | Meaning |
|---|---|
| `Healthy` | All pods are running and passing health checks |
| `Progressing` | Resources are converging: rolling update, initial scheduling in progress |
| `Degraded` | One or more resources are failing: `CrashLoopBackOff`, `ImagePullBackOff`, zero ready replicas |
| `Missing` | Resources defined in Git do not exist in the cluster |

> [!note] An application can be `Synced` but `Degraded`
> `Synced` only says that ArgoCD applied the manifests. The workload can still be `Degraded`, so check both values.

---

## 9. The Sample Workload

The test Deployment uses a Red Hat UBI minimal image running a simple shell loop. It is written specifically to satisfy OpenShift's `restricted-v2` SCC requirements.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  labels:
    app: sample-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
      - name: sample-app
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["sh", "-c", "while true; do echo hello; sleep 30; done"]
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop: ["ALL"]
```

**Why this specific security context:**

OpenShift enforces Security Context Constraints (SCCs) on every pod. The default SCC for new namespaces is `restricted-v2`, which requires:

| Requirement | Field |
|---|---|
| No privilege escalation | `allowPrivilegeEscalation: false` |
| No root execution | `runAsNonRoot: true` |
| Seccomp profile | `seccompProfile.type: RuntimeDefault` |
| No Linux capabilities | `capabilities.drop: ["ALL"]` |

A pod that omits any of these fields will be **rejected by the admission controller** before it is scheduled. OpenShift will assign a random UID from the namespace's allowed range automatically: no `runAsUser` is needed.

The `namespace:` field is intentionally absent from the manifest. The destination namespace is declared in the ArgoCD `Application` CR, not in individual manifests. This keeps manifests portable and avoids conflicts.

---

## 10. Architecture Overview

```
  Windows Workstation (Tailscale)
           │
           │ https://openshift-gitops-server-openshift-gitops
           │       .apps.lab.example.internal
           ▼
  ┌─────────────────────────────────────────────────────────┐
  │                SNO Cluster (192.168.50.20)                │
  │                                                         │
  │  namespace: openshift-gitops                            │
  │  ┌───────────────────────────────────────────────────┐  │
  │  │  ArgoCD                                           │  │
  │  │  ┌──────────────┐    ┌─────────────────────────┐  │  │
  │  │  │ repo-server  │───▶│ application-controller  │  │  │
  │  │  │ (clones Git) │    │ (reconciles cluster)    │  │  │
  │  │  └──────┬───────┘    └───────────┬─────────────┘  │  │
  │  └─────────┼─────────────────────────┼───────────────┘  │
  │            │                         │                   │
  │            │ clone                   │ apply             │
  │            ▼                         ▼                   │
  │  gitlab.lab.example.internal     namespace: sample-app         │
  │  (192.168.50.30)             ┌─────────────────────┐       │
  │                            │  Deployment         │       │
  │  /YOUR_GITLAB_USER/openshift-gitops   │  ReplicaSet         │       │
  │  apps/sample-app/          │  Pod (ubi-minimal)  │       │
  │  deployment.yaml           └─────────────────────┘       │
  └─────────────────────────────────────────────────────────┘
```

---

## 11. Troubleshooting Reference

| Issue | Symptoms | Fix |
|---|---|---|
| Application stuck `OutOfSync` | Sync never completes, no error | Check repo-server logs: `oc logs -n openshift-gitops -l app.kubernetes.io/name=argocd-repo-server` |
| Repo connection failed | Application shows `ComparisonError` | Verify Secret label, URL, token. Check `insecure: "true"` is set for HTTP repos |
| Pod rejected by SCC | `oc get pods` shows `Error` or `CreateContainerConfigError` | Add required `securityContext` fields: `allowPrivilegeEscalation: false`, `runAsNonRoot: true`, `seccompProfile`, `capabilities.drop: ALL` |
| RBAC forbidden on deploy | ArgoCD shows `deployments.apps is forbidden` | Verify namespace label: `oc get namespace sample-app --show-labels` |
| ArgoCD UI inaccessible | Browser cannot reach console URL | Verify wildcard DNS: `Resolve-DnsName openshift-gitops-server-openshift-gitops.apps.lab.example.internal` returns `192.168.50.20` |
| Wrong admin password | Login rejected | Retrieve from correct secret: `openshift-gitops-cluster` in `openshift-gitops` namespace: NOT `argocd-initial-admin-secret` |

---

## 12. Key Resource Reference

| Resource | Name | Namespace |
|---|---|---|
| Operator namespace | `openshift-gitops-operator` | - |
| ArgoCD control plane namespace | `openshift-gitops` | - |
| ArgoCD CR | `openshift-gitops` | `openshift-gitops` |
| ArgoCD server Route | `openshift-gitops-server` | `openshift-gitops` |
| Admin password Secret | `openshift-gitops-cluster` | `openshift-gitops` |
| GitLab repo credential Secret | `openshift-gitops-gitlab-repo` | `openshift-gitops` |
| Application CR | `sample-app` | `openshift-gitops` |
| Application Controller SA | `openshift-gitops-argocd-application-controller` | `openshift-gitops` |
| Namespace management label | `argocd.argoproj.io/managed-by=openshift-gitops` | On target namespace |
| OLM channel | `latest` (resolves to `gitops-1.19`) | - |
