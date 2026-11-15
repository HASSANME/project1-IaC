# Kubernetes Migration Documentation

## 1. Migration Overview and Architecture

This document describes the complete migration of the **Go Coffeeshop** application from Docker Compose to Kubernetes. The application is a microservices-based coffeeshop ordering system with the following architecture:

```
┌─────────┐     ┌─────────┐     ┌──────────┐
│   Web   │────▶│  Proxy  │────▶│ Product  │
│ :8888   │     │ :5000   │────▶│ :5001    │
└─────────┘     └─────────┘     └──────────┘
                     │
                     ▼
                ┌──────────┐     ┌──────────┐     ┌──────────┐
                │ Counter  │────▶│ RabbitMQ │◀────│ Barista  │
                │ :5002    │     │ :5672    │     │ (worker) │
                └──────────┘     │ :15672   │     └──────────┘
                     │           └──────────┘          │
                     │                │                │
                     ▼                │                ▼
                ┌──────────┐     ┌──────────┐     ┌──────────┐
                │PostgreSQL│     │ Kitchen  │     │PostgreSQL│
                │ :5432    │     │ (worker) │     │ (shared) │
                └──────────┘     └──────────┘     └──────────┘
```

**Source:** `project1-IaC/application/docker-compose.yaml`  
**Target:** `project1-IaC/kubernetes/`

### Migration Principles

- Preserve the existing PostgreSQL implementation without modification
- Use Kubernetes-native patterns instead of blindly translating Docker Compose
- Separate sensitive credentials (Secrets) from configuration (ConfigMaps)
- Use init containers to replace Docker Compose `depends_on` health checks
- Use Kubernetes Service DNS for inter-service communication
- Apply resource requests and limits to all containers
- Add health probes where services expose ports

---

## 2. Migrated Services and Kubernetes Resources

| Docker Compose Service | K8s Workload | Reason | Resources Created |
|------------------------|-------------|--------|-------------------|
| **postgres** | StatefulSet | Pre-existing — stateful database | Secret, Service, StatefulSet (preserved) |
| **rabbitmq** | StatefulSet | Stateful message broker requiring persistent storage for queues and stable identity | Secret, Service, StatefulSet, PVC |
| **proxy** | Deployment | Stateless API gateway / reverse proxy | ConfigMap, Service, Deployment |
| **product** | Deployment | Stateless gRPC product catalog service | ConfigMap, Service, Deployment |
| **counter** | Deployment | Stateless order counter, connects to PG/RabbitMQ/Product | ConfigMap, Secret, Service, Deployment |
| **barista** | Deployment | Stateless RabbitMQ consumer (background worker) | ConfigMap, Secret, Deployment |
| **kitchen** | Deployment | Stateless RabbitMQ consumer (background worker) | ConfigMap, Secret, Deployment |
| **web** | Deployment | Stateless web frontend | ConfigMap, Service (NodePort), Deployment |

### Total: 8 services, 25 manifest files

---

## 3. Workload Type Decisions

### StatefulSet (postgres, rabbitmq)

- **PostgreSQL:** Database requiring persistent storage and stable network identity. Pre-existing implementation with `volumeClaimTemplates` for data persistence.
- **RabbitMQ:** Message broker that maintains queue state, message persistence, and cluster identity. Requires stable hostname for reconnection and persistent volume for queue durability.

### Deployment (proxy, product, counter, barista, kitchen, web)

All application services are **stateless** — they don't store local data that must survive pod restarts:
- **proxy, product, web:** Pure request handlers with no state
- **counter:** Stores orders in PostgreSQL (external state), publishes to RabbitMQ
- **barista, kitchen:** Consume messages from RabbitMQ, write to PostgreSQL — no local state

---

## 4. ConfigMaps and Secrets Management

### ConfigMaps (non-sensitive configuration)

| ConfigMap | Service | Keys |
|-----------|---------|------|
| `proxy-config` | proxy | `APP_NAME`, `GRPC_PRODUCT_HOST`, `GRPC_PRODUCT_PORT`, `GRPC_COUNTER_HOST`, `GRPC_COUNTER_PORT` |
| `product-config` | product | `APP_NAME` |
| `counter-config` | counter | `APP_NAME`, `IN_DOCKER`, `PRODUCT_CLIENT_URL` |
| `barista-config` | barista | `APP_NAME`, `IN_DOCKER` |
| `kitchen-config` | kitchen | `APP_NAME`, `IN_DOCKER` |
| `web-config` | web | `REVERSE_PROXY_URL`, `WEB_PORT` |

### Secrets (sensitive credentials)

| Secret | Service | Keys |
|--------|---------|------|
| `postgres-secret` | postgres | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| `rabbitmq-secret` | rabbitmq | `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS` |
| `counter-secret` | counter | `PG_URL`, `PG_DSN_URL`, `RABBITMQ_URL` |
| `barista-secret` | barista | `PG_URL`, `PG_DSN_URL`, `RABBITMQ_URL` |
| `kitchen-secret` | kitchen | `PG_URL`, `PG_DSN_URL`, `RABBITMQ_URL` |

> [!IMPORTANT]
> All Secrets use `stringData` (plain text in manifests, base64-encoded by Kubernetes at apply time). In production, use a secret management solution (e.g., Sealed Secrets, External Secrets, Vault) instead of storing credentials in manifest files.

### Environment Variable Injection

All services use `envFrom` to inject environment variables:
- `configMapRef` for non-sensitive configuration
- `secretRef` for credentials

This approach injects all keys from the referenced resource as environment variables, matching the Docker Compose `environment` pattern.

---

## 5. Networking, Ports, DNS, and Inter-Service Communication

### Service DNS Resolution

In Kubernetes, services communicate via DNS. Within the same namespace, services are reachable at `<service-name>:<port>`.

| Service | DNS Name | Port(s) | Type |
|---------|----------|---------|------|
| postgres | `postgres` | 5432 | ClusterIP |
| rabbitmq | `rabbitmq` | 5672 (AMQP), 15672 (Management) | ClusterIP |
| proxy | `proxy` | 5000 | ClusterIP |
| product | `product` | 5001 | ClusterIP |
| counter | `counter` | 5002 | ClusterIP |
| web | `web` | 8888 | NodePort |

### Key DNS Translations from Docker Compose

| Docker Compose | Kubernetes |
|----------------|-----------|
| `postgres:5432` | `postgres:5432` (same — service names match) |
| `rabbitmq:5672` | `rabbitmq:5672` (same) |
| `product:5001` (gRPC) | `product:5001` (same) |
| `counter:5002` (gRPC) | `counter:5002` (same) |
| `http://localhost:5000` (web→proxy) | `http://proxy:5000` (uses K8s DNS) |

> [!NOTE]
> The Web service's `REVERSE_PROXY_URL` was changed from `http://localhost:5000` to `http://proxy:5000` because in Kubernetes, containers don't share a network namespace with other services. Kubernetes DNS (`proxy:5000`) correctly routes to the proxy service.

### Services Without Exposed Ports

**Barista** and **Kitchen** are background workers that only consume from RabbitMQ and write to PostgreSQL. They don't expose any ports, so they have no Kubernetes Service resource. They are still reachable within the cluster via their pod IPs if needed.

### External Access

- **Web** uses `NodePort` type service for external access on port 8888
- **RabbitMQ Management** UI is accessible on port 15672 (ClusterIP, port-forward for access)

---

## 6. Persistent Storage Configurations

| Service | Volume Mount | Storage | Access Mode |
|---------|-------------|---------|-------------|
| **postgres** | `/var/lib/postgresql/data` | 5Gi | ReadWriteOnce |
| **rabbitmq** | `/var/lib/rabbitmq` | 2Gi | ReadWriteOnce |

Both use `volumeClaimTemplates` in their StatefulSets, which automatically create PersistentVolumeClaims per replica. This ensures:
- Data survives pod restarts and rescheduling
- Each replica gets its own dedicated volume
- Volumes are named `data-<statefulset>-<ordinal>`

No other services require persistent storage — they are stateless applications.

---

## 7. Dependencies and Health Checks

### Init Containers (Dependency Management)

Docker Compose `depends_on` with `condition: service_healthy` is translated to Kubernetes init containers that wait for dependencies to be available:

| Service | Init Containers | Wait For |
|---------|----------------|----------|
| counter | `wait-for-postgres`, `wait-for-rabbitmq` | `postgres:5432`, `rabbitmq:5672` |
| barista | `wait-for-postgres`, `wait-for-rabbitmq` | `postgres:5432`, `rabbitmq:5672` |
| kitchen | `wait-for-postgres`, `wait-for-rabbitmq` | `postgres:5432`, `rabbitmq:5672` |

Init containers use `busybox:1.36` with `nc -z` to check TCP connectivity, polling every 2 seconds until the dependency is reachable.

> [!NOTE]
> The proxy and web services had Docker Compose `depends_on` without health check conditions. In Kubernetes, the init container pattern combined with readiness probes on their dependencies provides equivalent behavior. Since these are soft dependencies (the services will retry connections), explicit init containers were omitted to avoid unnecessary complexity.

### Liveness and Readiness Probes

| Service | Liveness Probe | Readiness Probe |
|---------|---------------|-----------------|
| **postgres** | `exec: pg_isready` | — |
| **rabbitmq** | `exec: rabbitmq-diagnostics -q ping` (30s interval) | `exec: rabbitmq-diagnostics -q ping` (10s interval) |
| **proxy** | `tcpSocket: 5000` (20s interval) | `tcpSocket: 5000` (10s interval) |
| **product** | `tcpSocket: 5001` (20s interval) | `tcpSocket: 5001` (10s interval) |
| **counter** | `tcpSocket: 5002` (20s interval) | `tcpSocket: 5002` (10s interval) |
| **web** | `tcpSocket: 8888` (20s interval) | `tcpSocket: 8888` (10s interval) |
| **barista** | — | — |
| **kitchen** | — | — |

- **postgres** preserves the original `pg_isready` liveness probe from the existing implementation
- **rabbitmq** uses the same `rabbitmq-diagnostics -q ping` command from the Docker Compose health check
- **Application services** use TCP socket probes since they serve on known ports
- **barista/kitchen** have no probes because they don't expose ports (they're background workers)

### Resource Requests and Limits

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---------|------------|-----------|---------------|-------------|
| rabbitmq | 250m | 500m | 256Mi | 512Mi |
| proxy | 100m | 250m | 64Mi | 128Mi |
| product | 100m | 250m | 64Mi | 128Mi |
| counter | 100m | 250m | 64Mi | 128Mi |
| barista | 100m | 250m | 64Mi | 128Mi |
| kitchen | 100m | 250m | 64Mi | 128Mi |
| web | 100m | 250m | 64Mi | 128Mi |

> [!TIP]
> Resource limits should be tuned based on actual usage in your environment. Use `kubectl top pods` to observe real resource consumption and adjust accordingly.

---

## 8. Kubernetes Directory Structure

```
kubernetes/
├── barista/
│   ├── configmap.yaml          # APP_NAME, IN_DOCKER
│   ├── deployment.yaml         # Deployment with init containers
│   └── secret.yaml             # PG_URL, PG_DSN_URL, RABBITMQ_URL
├── counter/
│   ├── configmap.yaml          # APP_NAME, IN_DOCKER, PRODUCT_CLIENT_URL
│   ├── deployment.yaml         # Deployment with init containers
│   ├── secret.yaml             # PG_URL, PG_DSN_URL, RABBITMQ_URL
│   └── service.yaml            # ClusterIP on port 5002
├── kitchen/
│   ├── configmap.yaml          # APP_NAME, IN_DOCKER
│   ├── deployment.yaml         # Deployment with init containers
│   └── secret.yaml             # PG_URL, PG_DSN_URL, RABBITMQ_URL
├── postgres/                   # ← PRESERVED (pre-existing)
│   ├── secret.yaml             # POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
│   ├── service.yaml            # ClusterIP on port 5432
│   └── statefull.yaml          # StatefulSet with PVC
├── product/
│   ├── configmap.yaml          # APP_NAME
│   ├── deployment.yaml         # Deployment
│   └── service.yaml            # ClusterIP on port 5001
├── proxy/
│   ├── configmap.yaml          # APP_NAME, gRPC hosts/ports
│   ├── deployment.yaml         # Deployment
│   └── service.yaml            # ClusterIP on port 5000
├── rabbitmq/
│   ├── secret.yaml             # RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASS
│   ├── service.yaml            # ClusterIP on ports 5672, 15672
│   └── statefulset.yaml        # StatefulSet with PVC
├── web/
│   ├── configmap.yaml          # REVERSE_PROXY_URL, WEB_PORT
│   ├── deployment.yaml         # Deployment
│   └── service.yaml            # NodePort on port 8888
└── KUBERNETES_MIGRATION.md     # This file
```

**Total: 25 manifest files across 8 service directories**

---

## 9. Validation Procedures and Results

### Validation Performed

1. **YAML Syntax Validation:** All 25 files parsed successfully with no syntax errors
2. **Required Fields Check:** Every manifest has `apiVersion`, `kind`, `metadata.name`
3. **Selector/Label Matching:** All Deployments, StatefulSets, and Services have matching `app: <name>` selectors and labels
4. **Cross-Reference Verification:** All `configMapRef` and `secretRef` names reference existing ConfigMap and Secret resources
5. **Port Consistency:** Container ports match Service target ports for all services
6. **Indentation Check:** All files use consistent 2-space YAML indentation with no tab characters

### Validation Results

```
=== YAML STRUCTURE VALIDATION ===
  25/25 manifests: OK (0 issues)

=== SELECTOR/LABEL MATCHING ===
  14/14 workloads and services: OK (all selectors match labels)

=== PORT VERIFICATION ===
  postgres  : 5432
  rabbitmq  : 5672, 15672
  proxy     : 5000
  product   : 5001
  counter   : 5002
  web       : 8888
```

### Manual Validation Commands

```bash
# Dry-run apply to validate against K8s API
kubectl apply --dry-run=client -R -f kubernetes/

# Validate with kubeval (if installed)
kubeval --strict -d kubernetes/

# Check specific service
kubectl apply --dry-run=client -f kubernetes/rabbitmq/
```

---

## 10. Deployment, Inspection, and Cleanup Commands

### Deployment Order

Deploy infrastructure services first, then application services:

```bash
# Step 1: Infrastructure — PostgreSQL and RabbitMQ (and their Secrets)
kubectl apply -f kubernetes/postgres/
kubectl apply -f kubernetes/rabbitmq/

# Step 2: Wait for infrastructure readiness
kubectl wait --for=condition=ready pod -l app=postgres --timeout=120s
kubectl wait --for=condition=ready pod -l app=rabbitmq --timeout=120s

# Step 3: Independent application services
kubectl apply -f kubernetes/product/

# Step 4: Services depending on infrastructure
kubectl apply -f kubernetes/counter/
kubectl apply -f kubernetes/barista/
kubectl apply -f kubernetes/kitchen/

# Step 5: Frontend
kubectl apply -f kubernetes/proxy/
kubectl apply -f kubernetes/web/
```

Or deploy everything at once (init containers handle ordering):

```bash
kubectl apply -R -f kubernetes/
```

### Inspection Commands

```bash
# Check all pods
kubectl get pods -o wide

# Check all services
kubectl get svc

# Check all configmaps and secrets
kubectl get configmaps
kubectl get secrets

# Check PVCs
kubectl get pvc

# View logs for a service
kubectl logs -l app=counter --tail=50
kubectl logs -l app=barista --tail=50

# Describe a pod for troubleshooting
kubectl describe pod -l app=counter

# Check init container status
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.initContainerStatuses[*].name}{"\t"}{.status.initContainerStatuses[*].ready}{"\n"}{end}'

# Port-forward to access services locally
kubectl port-forward svc/web 8888:8888              # Web UI
kubectl port-forward svc/proxy 5000:5000            # API proxy
kubectl port-forward svc/rabbitmq 15672:15672       # RabbitMQ Management UI

# Check resource usage
kubectl top pods
```

### Cleanup Commands

```bash
# Delete all resources
kubectl delete -R -f kubernetes/

# Delete specific service
kubectl delete -f kubernetes/rabbitmq/

# Delete PVCs (data will be lost!)
kubectl delete pvc -l app=postgres
kubectl delete pvc -l app=rabbitmq
```

---

## Assumptions and Limitations

### Assumptions

1. **Container images are pre-built and available.** The Docker Compose file uses `build:` directives with Dockerfiles. In Kubernetes, images must be pre-built and pushed to a registry (or loaded locally for minikube/kind). The `imagePullPolicy: IfNotPresent` is set for application images to support local development.

2. **Single namespace deployment.** All services deploy to the same namespace. DNS references use short names (e.g., `postgres` instead of `postgres.default.svc.cluster.local`).

3. **PostgreSQL credentials alignment.** The existing PostgreSQL Secret uses `appdb`/`appuser`/`ChangeMeToAStrongPassword!` which differs from the Docker Compose values (`postgres`/`postgres`/`P@ssw0rd`). The migration Secrets for counter, barista, and kitchen use the Kubernetes PostgreSQL Secret values to maintain consistency within the Kubernetes environment.

4. **Default StorageClass.** PersistentVolumeClaims don't specify a `storageClassName`, relying on the cluster's default StorageClass.

### Limitations

1. **No Ingress resource.** The web service uses NodePort for external access. For production, configure an Ingress controller with proper routing rules.

2. **No TLS/mTLS.** Inter-service communication is unencrypted. For production, consider a service mesh (Istio, Linkerd) for mTLS.

3. **No NetworkPolicies.** All pods can communicate freely. Consider adding NetworkPolicies to restrict traffic to only required paths.

4. **No pod disruption budgets.** For production, add PodDisruptionBudgets for critical services (postgres, rabbitmq).

5. **Single replicas.** All services run with 1 replica. Scale based on load requirements. Note: PostgreSQL's existing configuration has 2 replicas but lacks proper replication setup.

### Decisions Requiring Attention

> [!WARNING]
> 1. **PostgreSQL replica count:** The existing StatefulSet has `replicas: 2`, but PostgreSQL doesn't automatically handle replication — this creates two independent databases. Consider either reducing to 1 replica or implementing proper streaming replication.
> 2. **Image registry:** Application images (`go-coffeeshop-*`) need to be built and pushed to an accessible registry before deployment.
> 3. **Credential management:** Secrets are stored in plain text in YAML files. Implement a proper secret management solution before production use.
> 4. **`IN_DOCKER` environment variable:** This is preserved from Docker Compose but may need to be renamed/removed for Kubernetes clarity — it likely controls connection behavior in the application code.
