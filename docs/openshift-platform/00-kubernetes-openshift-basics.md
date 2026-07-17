> [!NOTE]
> This document is a sanitized portfolio version of work completed in an internship lab. Internal hostnames, IP addresses, usernames, organization-specific identifiers, credentials, and private infrastructure details have been replaced with examples. Commands must be adapted and reviewed before use in another environment.

#### Kubernetes
_Picture Kubernetes as a datacenter operating system
You stop managing machines directly, instead, you describe what you want and Kubernetes keeps the system in that state_

### 1. **Pods:**
_Smallest deployable unit in Kubernetes_

Contains:
	- One or more containers
	- Shared network namespace
	- Shared storage volumes

All containers in a pod:
	_share the same IP address_
	_communicate via localhost_
	start and stop together
e.g.
```
Pod
 ├─ nginx container
 └─ sidecar container (log collector)
```

### 2. **ReplicaSet:**
_Ensures a specific number of identical pods exist
You can compare it to an autopilot redundancy controller_
e.g.
```
replicas: 3
```
--> Kubernetes guarantees 3 pods always running
	--> If one crashes, Kubernetes will relaunch the pod.

### 3. **Deployment:**
_A deployment manages various processes like ReplicaSets, rolling updates, rollbacks
You can compare it to a software release manager_
```
Deployment
  └─ ReplicaSet
       └─ Pods
```
When you update an image like nginx:v1 -> nginx:v2
Deployments performs a rolling update
	- It starts new pods
	- Stops old pods gradually

### 4. **DaemonSet:**

_A DaemonSet runs one pod per node
It's like an agent installed on every server_

### 5. **StatefulSet:**

_Used for stateful applications_
e.g.
1) Databases
2) Kafka
3) etcd
Provides:
--> stable hostnames
--> stable storage
--> prdered startup
(db-0, db-1, db-2)


### 6. **Services:**
_Pods are ephemeral, their IPs change
A service gives a stable network endpoint_
e.g.
**ClusterIP:**
_Internal service only
it's like an internal DNS name_

**NodePort:**
_Opens a port on every node
External users can connect via node IP_
``NodeIP: 30007``


**LoadBalancer:**
_Uses cload load balancer
Traffic is distributed across nodes
LoadBalancer = public entry gateway_


### 7. **OpenShift Routes**
_Routes expose services via ``HTTP/HTTPS Hostnames``
A route is comparable to a reverse proxy + DNS entry_
e.g.
```
Internet
   ↓
OpenShift Router
   ↓
Service
   ↓
Pods
```

### 8. **Namespace vs Project**

**Namespace (Kubernetes):**
Logical isolation:
```
dev
prod
monitoring
```
--> Resources are grouped inside

**Project (OpenShift)**
	_Project = namespace + extra policies_
OpenShift adds:
- quotas
- RBAC
- UI integration