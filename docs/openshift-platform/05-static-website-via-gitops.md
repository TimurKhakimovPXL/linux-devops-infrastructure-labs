> [!NOTE]
> This is a sanitized copy of an internship lab document. Names, addresses, credentials, and other internal details use placeholders. Review the commands before applying them elsewhere.

# Target 5: Deploy a Static Website via GitOps

**Objective:** Deploy an nginx static site from Git with ArgoCD, and expose it through a re-encrypt Route backed by an OpenShift service certificate.
**Target Environment:** Single Node OpenShift 4.21 lab
**GitLab Repository:** `https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git`
**nginx Image:** `registry.access.redhat.com/ubi10/nginx-126@sha256:5f7981bbd959e58e3fac0b0a1920b3e0954959cc963b495b9a4606a5a09d9dea`

---

## 1. Prerequisites

Verify the ArgoCD pipeline from Target 3 is healthy before starting:

```bash
export KUBECONFIG=~/sno-install/auth/kubeconfig

oc get application sample-app -n openshift-gitops \
  -o jsonpath='Sync: {.status.sync.status}, Health: {.status.health.status}{"\n"}'
```

Expected:
```
Sync: Synced, Health: Healthy
```

> [!warning] Pre-flight: ArgoCD HTTP/HTTPS mismatch
> After Target 4 switched GitLab to HTTPS, the `sample-app` Application CR may still contain the old HTTP `repoURL`. The Secret was updated in Target 4 but the Application CR was not. If you see `ComparisonError: dial tcp 192.168.50.30:80`, apply this fix before proceeding:
>
> ```bash
> oc patch application sample-app -n openshift-gitops \
>   --type=merge \
>   --patch='{"spec":{"source":{"repoURL":"https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git"}}}'
>
> oc rollout restart deployment/openshift-gitops-repo-server -n openshift-gitops
> oc rollout status deployment/openshift-gitops-repo-server -n openshift-gitops
> ```
>
> Then save the corrected Application CR to Git so it cannot drift again.
>
> **Note:** This CR also changes `project` from `default` to `lab-apps`. Target 3 originally created `sample-app` under `project: default`. The `lab-apps` AppProject created in this target (Section 5.2) replaces it. This change only works after the AppProject bootstrap in Section 7: if you commit this file before applying `lab-project.yaml`, ArgoCD will reject it with `AppProject lab-apps not found`.
>
> ```bash
> cat > ~/openshift-gitops/cluster-configs/argocd/sample-app.yaml << 'EOF'
> apiVersion: argoproj.io/v1alpha1
> kind: Application
> metadata:
>   name: sample-app
>   namespace: openshift-gitops
> spec:
>   project: lab-apps
>   source:
>     repoURL: https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
>     targetRevision: main
>     path: apps/sample-app
>   destination:
>     server: https://kubernetes.default.svc
>     namespace: sample-app
>   syncPolicy:
>     automated:
>       prune: true
>       selfHeal: true
>     syncOptions:
>       - CreateNamespace=false
>       - ServerSideApply=true
>     retry:
>       limit: 5
>       backoff:
>         duration: 5s
>         factor: 2
>         maxDuration: 3m
> EOF
>
> git add cluster-configs/argocd/sample-app.yaml
> git commit -m "fix: update sample-app Application CR to HTTPS GitLab URL"
> git push origin main
> ```

| Requirement | Source |
|---|---|
| ArgoCD operator installed and running | Target 3 |
| GitLab repository `openshift-gitops` accessible over HTTPS | Target 2 / Target 4 |
| ArgoCD repo Secret pointing at `https://gitlab.lab.example.internal` | Target 4, Section 6.11 |
| Wildcard certificate on IngressController | Target 4, Section 5.2 |
| Lab Internal CA in cluster proxy trust bundle | Target 4, Section 5.3 |
| Lab Internal CA installed in Windows trust store | Target 4, Section 9.1 |
| Jump VM with `oc` CLI and kubeconfig | Target 1, Section 8.1 |

---

## 2. Step 1: Repository Structure

All manifests for this target live under `apps/static-website/`. Two new files are added to `cluster-configs/argocd/` and one bootstrap resource is added to `cluster-configs/bootstrap/`.

```
openshift-gitops/
├── .githooks/
│   └── pre-commit                   <- enforces restartedAt on configmap updates
├── apps/
│   ├── sample-app/
│   │   └── deployment.yaml          <- unchanged from Target 3
│   └── static-website/              <- new
│       ├── namespace.yaml
│       ├── serviceaccount.yaml
│       ├── configmap.yaml
│       ├── configmap-nginx.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       └── route.yaml
└── cluster-configs/
    ├── argocd/
    │   ├── sample-app.yaml
    │   ├── static-website-app.yaml  <- new
    │   └── root-app.yaml            <- new (App-of-Apps)
    └── bootstrap/
        └── lab-project.yaml       <- new (manual bootstrap, not managed by ArgoCD)
```

Create the directory and activate the Git hooks:

```bash
cd ~/openshift-gitops
mkdir -p apps/static-website
git config core.hooksPath .githooks
```

---

## 3. Step 2: Probe the nginx Image

Before writing any manifests, probe the image to find the correct paths and all writable directories. This prevents filesystem permission errors when `readOnlyRootFilesystem: true` is enabled.

```bash
# Discover environment variables and paths
oc run nginx-probe \
  --image=registry.access.redhat.com/ubi10/nginx-126:latest \
  --restart=Never --rm -it \
  -- env | grep -E 'NGINX|APP_ROOT|CONF'
```

Expected:
```
NGINX_DEFAULT_CONF_PATH=/opt/app-root/etc/nginx.default.d
NGINX_APP_ROOT=/opt/app-root
NGINX_CONF_PATH=/etc/nginx/nginx.conf
NGINX_LOG_PATH=/var/log/nginx
APP_ROOT=/opt/app-root
NGINX_CONFIGURATION_PATH=/opt/app-root/etc/nginx.d
NGINX_VERSION=1.26
```

```bash
# Find the writable paths needed for readOnlyRootFilesystem
oc run nginx-probe \
  --image=registry.access.redhat.com/ubi10/nginx-126:latest \
  --restart=Never --rm -it \
  -- find / -writable -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null
```

Expected writable paths nginx uses at runtime:
```
/tmp
/var/lib/nginx/tmp
/var/log/nginx
/var/run
/var/tmp
```

> [!danger] UBI nginx images are S2I builder images, not runtime images
> All UBI nginx variants (`nginx-120`, `nginx-122`, `nginx-124`, `nginx-126`) are Source-to-Image builder images. They exit immediately when run without the S2I scripts. To use them as runtime servers, override the command with `nginx -g "daemon off;"` and mount content into `/opt/app-root/src`.

Key paths used in the manifests:

| Variable | Path |
|---|---|
| Document root | `/opt/app-root/src` |
| Main nginx config | `/etc/nginx/nginx.conf` |
| PID file | `/var/run/nginx/nginx.pid` |
| Container UID | `1001` / GID `0`, compatible with `restricted-v2` SCC |

Retrieve the exact image digest for pinning in the Deployment manifest. Run a temporary pod and extract the resolved digest from the pod status:

```bash
oc run nginx-probe \
  --image=registry.access.redhat.com/ubi10/nginx-126:latest \
  --restart=Never -- sleep 10

# Wait for the image to be pulled
oc wait pod/nginx-probe --for=condition=Ready --timeout=60s

# Extract the resolved digest
oc get pod nginx-probe \
  -o jsonpath='{.status.containerStatuses[0].imageID}{"\n"}'

# Clean up
oc delete pod nginx-probe
```

Record the digest output: this is used in the Deployment manifest (Section 4.5) to pin the image by content hash rather than by mutable tag.

---

## 4. Step 3: Write the Manifests

### 4.1 Namespace

The `argocd.argoproj.io/managed-by` label triggers the GitOps Operator to automatically create the RBAC RoleBindings that give ArgoCD permission to deploy into this namespace.

```bash
cat > apps/static-website/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: static-website
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
EOF
```

### 4.2 ServiceAccount

A dedicated ServiceAccount with `automountServiceAccountToken: false` prevents the nginx Pod from having Kubernetes API credentials mounted by default. A static file server has no reason to talk to the Kubernetes API.

```bash
cat > apps/static-website/serviceaccount.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: static-website
  namespace: static-website
automountServiceAccountToken: false
EOF
```

### 4.3 HTML ConfigMap

The `index.html` content is declared inline. It makes no CDN requests and can load in an air-gapped environment.

```bash
cat > apps/static-website/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: static-website-html
  namespace: static-website
data:
  index.html: |
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Infrastructure Lab</title>
      <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          min-height: 100vh;
          display: flex;
          align-items: center;
          justify-content: center;
          background: #0d1117;
          font-family: 'Courier New', Courier, monospace;
          color: #c9d1d9;
        }
        .card {
          border: 1px solid #30363d;
          border-radius: 8px;
          padding: 3rem 4rem;
          text-align: center;
          max-width: 520px;
          width: 90%;
        }
        .badge {
          display: inline-block;
          font-size: 0.7rem;
          letter-spacing: 0.15em;
          text-transform: uppercase;
          color: #58a6ff;
          border: 1px solid #58a6ff;
          border-radius: 4px;
          padding: 0.2em 0.6em;
          margin-bottom: 1.5rem;
        }
        h1 { font-size: 1.8rem; font-weight: 400; color: #e6edf3; margin-bottom: 0.75rem; }
        p { font-size: 0.9rem; line-height: 1.7; color: #8b949e; margin-bottom: 1.5rem; }
        .meta {
          font-size: 0.75rem;
          color: #484f58;
          border-top: 1px solid #21262d;
          padding-top: 1.25rem;
          display: flex;
          justify-content: space-between;
        }
        .meta span { color: #58a6ff; }
      </style>
    </head>
    <body>
      <div class="card">
        <div class="badge">OpenShift GitOps</div>
        <h1>Infrastructure Lab</h1>
        <p>Deployed via ArgoCD on Single Node OpenShift 4.21.<br>
           TLS terminated end-to-end. Served by nginx.</p>
        <div class="meta">
          <div>cluster <span>stage-project</span></div>
          <div>namespace <span>static-website</span></div>
          <div>target <span>5</span></div>
        </div>
      </div>
    </body>
    </html>
EOF
```

### 4.4 nginx Configuration ConfigMap

The UBI image's default configuration listens on port 80 with no TLS. A custom `nginx.conf` is required to:
- Listen on port 8443 (non-root processes cannot bind ports below 1024 under `restricted-v2`)
- Serve HTTPS using the service serving certificate
- Redirect logs to stdout/stderr so OpenShift's logging stack collects them

```bash
cat > apps/static-website/configmap-nginx.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: static-website-nginx-conf
  namespace: static-website
data:
  nginx.conf: |
    worker_processes auto;
    error_log /dev/stderr warn;
    pid /var/run/nginx/nginx.pid;

    events {
      worker_connections 1024;
    }

    http {
      include       /etc/nginx/mime.types;
      default_type  application/octet-stream;
      sendfile      on;
      keepalive_timeout 65;
      access_log /dev/stdout;

      server {
        listen 8443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        root  /opt/app-root/src;
        index index.html;

        location / {
          try_files $uri $uri/ =404;
        }
      }
    }
EOF
```

### 4.5 Deployment

The deployment uses several patterns worth understanding:

**Image digest pinning:** The image uses a `sha256` digest instead of the mutable `latest` tag. This makes the exact image version explicit and easier to audit.

**`restartedAt` annotation:** nginx does not reload when a mounted ConfigMap volume changes. The kubelet syncs the volume but nginx worker processes continue serving from cached file descriptors. Adding this annotation to the pod template means bumping the timestamp in the same commit as a ConfigMap change triggers an automatic rolling restart via ArgoCD. The pre-commit hook in `.githooks/pre-commit` enforces this.

**`readOnlyRootFilesystem: true`:** The container filesystem is mounted read-only. All paths nginx writes to at runtime are backed by emptyDir volumes (discovered in Step 3).

**Probes:** Kubernetes does not verify the certificate for an `httpGet` probe with `scheme: HTTPS`. The readiness probe keeps traffic away until nginx responds; the liveness probe restarts the container if nginx stops responding.

```bash
cat > apps/static-website/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: static-website
  namespace: static-website
  labels:
    app: static-website
spec:
  replicas: 1
  selector:
    matchLabels:
      app: static-website
  template:
    metadata:
      labels:
        app: static-website
      annotations:
        kubectl.kubernetes.io/restartedAt: "2026-03-20T00:00:00Z"
    spec:
      serviceAccountName: static-website
      containers:
      - name: nginx
        image: registry.access.redhat.com/ubi10/nginx-126@sha256:5f7981bbd959e58e3fac0b0a1920b3e0954959cc963b495b9a4606a5a09d9dea
        command: ["nginx", "-g", "daemon off;"]
        ports:
        - containerPort: 8443
          name: https
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /
            port: 8443
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 10
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /
            port: 8443
            scheme: HTTPS
          initialDelaySeconds: 15
          periodSeconds: 30
          failureThreshold: 3
        volumeMounts:
        - name: html
          mountPath: /opt/app-root/src
          readOnly: true
        - name: tls
          mountPath: /etc/nginx/tls
          readOnly: true
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
        - name: nginx-run
          mountPath: /var/run/nginx
        - name: nginx-log
          mountPath: /var/log/nginx
        - name: nginx-tmp
          mountPath: /var/lib/nginx/tmp
        - name: var-tmp
          mountPath: /var/tmp
        - name: tmp
          mountPath: /tmp
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "64Mi"
            cpu: "100m"
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          readOnlyRootFilesystem: true
          seccompProfile:
            type: RuntimeDefault
          capabilities:
            drop: ["ALL"]
      volumes:
      - name: html
        configMap:
          name: static-website-html
      - name: tls
        secret:
          secretName: static-website-tls
      - name: nginx-conf
        configMap:
          name: static-website-nginx-conf
      - name: nginx-run
        emptyDir: {}
      - name: nginx-log
        emptyDir: {}
      - name: nginx-tmp
        emptyDir: {}
      - name: var-tmp
        emptyDir: {}
      - name: tmp
        emptyDir: {}
EOF
```

### 4.6 Service

The annotation `service.beta.openshift.io/serving-cert-secret-name` instructs the OpenShift service CA controller to issue a TLS certificate for this Service and write it to the named Secret (`static-website-tls`) in the same namespace. The certificate is issued within seconds of the Service being created and is auto-rotated by OpenShift.

The issued certificate SANs:
```
DNS:static-website.static-website.svc
DNS:static-website.static-website.svc.cluster.local
```

```bash
cat > apps/static-website/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: static-website
  namespace: static-website
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: static-website-tls
spec:
  selector:
    app: static-website
  ports:
  - name: https
    port: 443
    targetPort: 8443
    protocol: TCP
EOF
```

### 4.7 Route

The re-encrypt Route terminates inbound TLS from the client at the IngressController using the wildcard certificate, then establishes a new TLS connection to the backend Pod using the service serving certificate. Both hops are encrypted.

```
Browser → [wildcard cert / Lab Internal CA] → IngressController → [service cert / cluster CA] → nginx Pod
```

The `destinationCACertificate` field needs the cluster service CA, which signed the service certificate and is separate from the Lab Internal CA. This command reads it and writes the complete Route manifest:

```bash
SERVICE_CA=$(oc get configmap openshift-service-ca.crt \
  -n openshift-config-managed \
  -o jsonpath='{.data.service-ca\.crt}')

cat > apps/static-website/route.yaml << EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: static-website
  namespace: static-website
spec:
  host: static-website.apps.lab.example.internal
  to:
    kind: Service
    name: static-website
    weight: 100
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    destinationCACertificate: |
$(echo "$SERVICE_CA" | sed 's/^/      /')
EOF
```

Verify the PEM was injected correctly: the file must contain a valid certificate block:

```bash
grep -c "BEGIN CERTIFICATE" apps/static-website/route.yaml
```

Expected: `1` (or more if the CA bundle contains intermediates).

---

## 5. Step 4: Create the AppProject and App-of-Apps

### 5.1 Why a Dedicated AppProject

The default ArgoCD AppProject (`project: default`) allows Applications to manage resources in any namespace on any cluster from any Git repository. Red Hat's own OpenShift GitOps documentation explicitly recommends against using it outside of demos.

A dedicated AppProject restricts:
- Source repository to your GitLab instance only
- Destination namespaces to the specific namespaces used
- Resource kinds to only what is actually deployed

### 5.2 AppProject bootstrap resource

The AppProject must exist before ArgoCD can validate Application CRs that reference it. Having the same Application create its own project would introduce a circular dependency, so the project is applied during bootstrap.

```bash
mkdir -p cluster-configs/bootstrap

cat > cluster-configs/bootstrap/lab-project.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: lab-apps
  namespace: openshift-gitops
spec:
  description: Infrastructure Lab applications
  sourceRepos:
    - https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
  destinations:
    - namespace: static-website
      server: https://kubernetes.default.svc
    - namespace: sample-app
      server: https://kubernetes.default.svc
    - namespace: openshift-gitops
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: 'apps'
      kind: Deployment
    - group: ''
      kind: Service
    - group: ''
      kind: ConfigMap
    - group: ''
      kind: ServiceAccount
    - group: 'route.openshift.io'
      kind: Route
    - group: 'argoproj.io'
      kind: Application
EOF
```

> [!note] Adding new applications
> When deploying a new application in a future target, add its namespace to `destinations` and any new resource kinds to `namespaceResourceWhitelist` in this file, then re-apply it manually with `oc apply`.

### 5.3 Static Website Application CR

```bash
cat > cluster-configs/argocd/static-website-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: static-website
  namespace: openshift-gitops
spec:
  project: lab-apps
  source:
    repoURL: https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
    targetRevision: main
    path: apps/static-website
  destination:
    server: https://kubernetes.default.svc
    namespace: static-website
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

`CreateNamespace=false` is correct because `namespace.yaml` is already part of the managed manifests.

### 5.4 Root Application CR (App-of-Apps)

The root Application CR watches `cluster-configs/argocd/` in Git. ArgoCD deploys any Application CR committed there, so new applications do not need a manual `oc apply`.

```bash
cat > cluster-configs/argocd/root-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: openshift-gitops
spec:
  project: lab-apps
  source:
    repoURL: https://gitlab.lab.example.internal/YOUR_GITLAB_USER/openshift-gitops.git
    targetRevision: main
    path: cluster-configs/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
```

### 5.5 Pre-Commit Hook

The pre-commit hook enforces the content update workflow. It rejects any commit that modifies `configmap.yaml` without also bumping the `restartedAt` timestamp in `deployment.yaml`.

```bash
mkdir -p .githooks

cat > .githooks/pre-commit << 'EOF'
#!/bin/bash

CONFIGMAP="apps/static-website/configmap.yaml"
DEPLOYMENT="apps/static-website/deployment.yaml"

if git diff --cached --name-only | grep -q "^${CONFIGMAP}$"; then
  if ! git diff --cached --name-only | grep -q "^${DEPLOYMENT}$"; then
    echo "ERROR: ${CONFIGMAP} was modified but ${DEPLOYMENT} was not."
    echo "You must bump the restartedAt timestamp in ${DEPLOYMENT} in the same commit."
    exit 1
  fi
  if ! git diff --cached "${DEPLOYMENT}" | grep -q "restartedAt"; then
    echo "ERROR: ${CONFIGMAP} was modified but restartedAt was not updated in ${DEPLOYMENT}."
    echo "Bump the kubectl.kubernetes.io/restartedAt timestamp to trigger a rolling restart."
    exit 1
  fi
fi

exit 0
EOF

chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
```

---

## 6. Step 5: Commit and Push

Verify the full file tree before committing:

```bash
find apps/static-website cluster-configs .githooks -type f | sort
```

Expected:
```
.githooks/pre-commit
apps/static-website/configmap-nginx.yaml
apps/static-website/configmap.yaml
apps/static-website/deployment.yaml
apps/static-website/namespace.yaml
apps/static-website/route.yaml
apps/static-website/service.yaml
apps/static-website/serviceaccount.yaml
cluster-configs/argocd/root-app.yaml
cluster-configs/argocd/sample-app.yaml
cluster-configs/argocd/static-website-app.yaml
cluster-configs/bootstrap/lab-project.yaml
```

Commit and push:

```bash
git add apps/static-website/ cluster-configs/ .githooks/
git commit -m "feat: add static-website manifests, App-of-Apps root, AppProject (Target 5)"
git push origin main
```

---

## 7. Step 6: Bootstrap

Apply the two bootstrap resources. These are the only manual `oc apply` operations required for this cluster going forward.

```bash
# 1. Apply the AppProject; it must exist before ArgoCD validates Application CRs
oc apply -f cluster-configs/bootstrap/lab-project.yaml

# 2. Apply the root Application CR, which manages the others from Git
oc apply -f cluster-configs/argocd/root-app.yaml
```

Watch ArgoCD sync:

```bash
oc get applications -n openshift-gitops -w
```

Expected:
```
NAME             SYNC STATUS   HEALTH STATUS
root-app         Synced        Healthy
sample-app       Synced        Healthy
static-website   Synced        Healthy
```

> [!note] App-of-Apps sync order
> root-app manages `cluster-configs/argocd/`. When it syncs, it creates `sample-app` and `static-website` Application CRs. Those then sync their respective application manifests. The full chain completes within one ArgoCD poll cycle (3 minutes).

---

## 8. Step 7: Verify

### 8.1 Pod and Resources

```bash
oc get pods,svc,route -n static-website
```

Expected:
```
NAME                                  READY   STATUS    RESTARTS   AGE
pod/static-website-86475b64d9-nwqpz   1/1     Running   0          2m

NAME                     TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)   AGE
service/static-website   ClusterIP   172.30.114.252   <none>        443/TCP   3m

NAME                                      HOST/PORT                                          TERMINATION
route.route.openshift.io/static-website   static-website.apps.lab.example.internal   reencrypt/Redirect
```

### 8.2 Service Serving Certificate

```bash
oc get secret static-website-tls -n static-website \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -text | grep -A2 "Subject Alternative"
```

Expected:
```
X509v3 Subject Alternative Name:
    DNS:static-website.static-website.svc
    DNS:static-website.static-website.svc.cluster.local
```

### 8.3 Security Context

```bash
oc get pod -n static-website -l app=static-website \
  -o jsonpath='{.items[0].spec.containers[0].securityContext}{"\n"}'
```

Expected:
```json
{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}}
```

### 8.4 ServiceAccount

```bash
oc get pod -n static-website -l app=static-website \
  -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
# Expected: static-website
```

### 8.5 AppProject

```bash
oc get applications -n openshift-gitops \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.project}{"\n"}{end}'
```

Expected:
```
root-app: lab-apps
sample-app: lab-apps
static-website: lab-apps
```

### 8.6 Website Access

```bash
curl --cacert $HOME/pki/ca.crt \
  https://static-website.apps.lab.example.internal | grep '<title>'
# Expected: <title>Infrastructure Lab</title>
```

With Tailscale active on the Windows workstation, open:

```
https://static-website.apps.lab.example.internal
```

No certificate warning is shown because the Lab Internal CA is trusted in the Windows certificate store from Target 4.

---

## 9. Step 8: Verify App-of-Apps Self-Healing

Delete the `static-website` Application CR and confirm `root-app` restores it automatically:

```bash
oc delete application static-website -n openshift-gitops

oc get applications -n openshift-gitops
# static-website reappears within seconds
```

Expected after a few seconds:
```
NAME             SYNC STATUS   HEALTH STATUS
root-app         Synced        Healthy
sample-app       Synced        Healthy
static-website   Synced        Healthy
```

---

## 10. Step 9: Verify GitOps Content Update Cycle

Update the HTML content and bump the `restartedAt` timestamp in the same commit:

```bash
# 1. Edit content
vim apps/static-website/configmap.yaml

# 2. Bump timestamp
vim apps/static-website/deployment.yaml
# Change: kubectl.kubernetes.io/restartedAt: "2026-03-20T00:00:00Z"
# To:     kubectl.kubernetes.io/restartedAt: "<new timestamp>"

# 3. Commit both together; the hook validates this
git add apps/static-website/configmap.yaml apps/static-website/deployment.yaml
git commit -m "content: update index.html"
git push origin main
```

If only `configmap.yaml` is staged, the pre-commit hook rejects the commit:

```
ERROR: apps/static-website/configmap.yaml was modified but apps/static-website/deployment.yaml was not.
You must bump the restartedAt timestamp in apps/static-website/deployment.yaml in the same commit.
```

After pushing, ArgoCD detects the commit within 3 minutes and triggers a rolling restart automatically. Watch the zero-downtime rollout:

```bash
oc get pods -n static-website -w
# New pod reaches 1/1 before old pod terminates
```

---

## 11. Architecture Overview

```
  Windows Workstation (Tailscale)
           |
           | https://static-website.apps.lab.example.internal
           | TLS: wildcard cert -- Lab Internal CA
           v
  +----------------------------------------------------------+
  |               SNO Cluster (192.168.50.20)                  |
  |                                                          |
  |  IngressController (router-default)                      |
  |  Terminates inbound TLS (wildcard cert)                  |
  |  Verifies backend cert against cluster service CA        |
  |         |                                                |
  |         | Re-encrypt: new TLS to backend                |
  |         | TLS: static-website.static-website.svc        |
  |         | Signed by: cluster service CA                 |
  |         v                                                |
  |  namespace: static-website                               |
  |  +----------------------------------------------------+  |
  |  |  Service: static-website (port 443 -> 8443)        |  |
  |  |  Annotation: serving-cert-secret-name              |  |
  |  |  -> Secret: static-website-tls (auto-issued)       |  |
  |  |                    |                               |  |
  |  |  ServiceAccount: static-website (no API token)     |  |
  |  |           +--------+---------+                     |  |
  |  |           |  Pod: nginx      |                     |  |
  |  |           |  port 8443       |                     |  |
  |  |           |  readOnly FS     |                     |  |
  |  |           |  readiness probe |                     |  |
  |  |           |  liveness probe  |                     |  |
  |  +----------------------------------------------------+  |
  |                                                          |
  |  namespace: openshift-gitops                             |
  |  AppProject: lab-apps (scoped to this repo/namespaces) |
  |  ArgoCD root-app watches: cluster-configs/argocd/       |
  |  ArgoCD static-website watches: apps/static-website/    |
  +----------------------------------------------------------+
           |
           | Git pull (HTTPS, every 3 min)
           v
  gitlab.lab.example.internal (192.168.50.30)
  /YOUR_GITLAB_USER/openshift-gitops
  apps/static-website/
  cluster-configs/argocd/
  cluster-configs/bootstrap/    <- manual apply only
  .githooks/pre-commit
```

---

## 12. Known Limitations

| # | Limitation | Impact | Resolution Path |
|---|---|---|---|
| 1 | Infrastructure layer (cert-manager, ClusterIssuer, OAuth CR, RBAC, secrets) applied with `oc apply` rather than GitOps | Cluster state can drift from documentation. Rebuild requires re-running all commands manually. | Requires SealedSecrets or external-secrets-operator and sync wave ordering. Deferred to a future target. |
| 2 | Bootstrap resources (`lab-project.yaml`, `root-app.yaml`) require manual `oc apply` | The first deployment is not Git-only. Later applications require only a Git commit. | Apply these two resources once when bootstrapping ArgoCD. |
| 3 | Pre-commit hook is local and can be bypassed with `git commit --no-verify` | Developer discipline is still required. Hook is not enforced server-side. | Requires a GitLab Runner to enforce via CI pipeline. Deferred until runner is configured. |

---

## 13. Troubleshooting Reference

| Issue | Cause | Resolution |
|---|---|---|
| `ComparisonError: dial tcp 192.168.50.30:80` | Application CR `repoURL` still using HTTP | Patch the CR: `oc patch application <n> -n openshift-gitops --type=merge --patch '{"spec":{"source":{"repoURL":"https://..."}}}'` |
| Pod `Status: Completed` cycling to `CrashLoopBackOff` | UBI nginx image is S2I and exits without a command override | Add `command: ["nginx", "-g", "daemon off;"]` to the container spec |
| `nginx: open() error (30: Read-only file system)` | `readOnlyRootFilesystem: true` with missing emptyDir volume | Probe the image with `find / -writable` and add emptyDir for each missing path |
| Secret `static-website-tls` not created | Service annotation missing or incorrect | Verify: `service.beta.openshift.io/serving-cert-secret-name: static-website-tls` |
| `resource argoproj.io:AppProject is not permitted` | Application CR references project that does not yet exist | Apply the AppProject manually first: `oc apply -f cluster-configs/bootstrap/lab-project.yaml` |
| ArgoCD synced but old image still running | ServerSideApply cache not flushed | Force hard refresh: `oc annotate application <n> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite` |
| Content update not served after Git push | `restartedAt` timestamp not bumped in same commit | Update both `configmap.yaml` and `restartedAt` in `deployment.yaml` together |
| Browser shows certificate warning | Lab Internal CA not in Windows trust store | Install `ca.crt` into Trusted Root Certification Authorities (Target 4, Section 9.1) |

---

## 14. Key Resource Reference

| Resource | Name | Namespace | Purpose |
|---|---|---|---|
| Namespace | `static-website` | - | Isolated workload namespace |
| ServiceAccount | `static-website` | `static-website` | Dedicated SA with no API token automounted |
| ConfigMap | `static-website-html` | `static-website` | `index.html` content |
| ConfigMap | `static-website-nginx-conf` | `static-website` | nginx HTTPS configuration |
| Deployment | `static-website` | `static-website` | nginx with a pinned digest, read-only FS, and Guaranteed QoS |
| Service | `static-website` | `static-website` | ClusterIP with serving-cert annotation |
| Secret | `static-website-tls` | `static-website` | Auto-issued service serving certificate |
| Route | `static-website` | `static-website` | Re-encrypt Route for public ingress |
| AppProject | `lab-apps` | `openshift-gitops` | Scoped ArgoCD project that replaces `default` |
| Application CR | `root-app` | `openshift-gitops` | App-of-Apps that manages all Application CRs |
| Application CR | `static-website` | `openshift-gitops` | GitOps sync definition |
| Application CR | `sample-app` | `openshift-gitops` | Target 3 workload managed by `root-app` |
| Bootstrap manifest | `cluster-configs/bootstrap/lab-project.yaml` | Git | Applied once manually before ArgoCD bootstrap |
| Pre-commit hook | `.githooks/pre-commit` | Git | Enforces restartedAt on configmap updates |
| Cluster service CA | `openshift-service-ca.crt` | `openshift-config-managed` | Source of `destinationCACertificate` |
| Public URL | `https://static-website.apps.lab.example.internal` | - | Browser endpoint |
