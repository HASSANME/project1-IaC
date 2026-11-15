Notes of 21/08/2026:

"""

# Terraform + AWS + GitHub Actions — Combined Study Notes

## 1. Problems We Solved

- GitHub Actions couldn't authenticate to AWS — error: `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`
- Terraform init/plan/apply failed because credentials never arrived
- Terraform initialized in an empty directory (config files were in a subfolder, not repo root)
- A strict validator complained about a missing `Resource` field in the trust policy
- Stuck/runaway workflow runs needed to be cancelled

## 2. Root Causes

**OIDC / trust policy problems (the recurring theme across sessions):**

- Trust policy was missing or misconfigured, so AWS never authorized GitHub's OIDC provider to assume the role
- `StringEquals` was used with a `*` wildcard in the `sub` condition — `StringEquals` does not treat `*` as a wildcard, so it silently failed to match; `StringLike` is needed for pattern matching
- Repo used the newer immutable `sub` format (owner/repo IDs), which didn't match the older `repo:owner/repo:*` string the policy expected
- ⚠️ **Conflicting note across sources:** one troubleshooting session identified the root cause as a **thumbprint mismatch** between AWS's stored certificate fingerprint and GitHub's actual current certificate. Another session traced the same symptom to the **trust policy `sub`/`StringEquals` issue** above, with thumbprint ruled out as secondary. Both are real, valid OIDC failure modes — but they're different bugs. When you hit this error again, check both instead of assuming which one it is from memory.
- Missing `permissions: { id-token: write, contents: read }` block at the top of the workflow — without this, GitHub can't generate an OIDC token at all

**Terraform directory problem:**

- GitHub Actions runs from the repo root by default; `terraform init` only looks in its current directory, so it saw "empty directory" when the `.tf` files lived in a subfolder, it was solved using "working-directory: ./terraform"

**Validator / schema problem:**

- IAM trust policies don't normally need a `Resource` field , but IAM permission policy need it


## 3. Fixes Applied

### Delete and recreate the OIDC provider (if thumbprint is suspected)

```bash
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"

aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "<CURRENT_THUMBPRINT>"
```

### Fix the trust policy (StringLike + Resource field + flexible sub)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:<OWNER>/<REPO>:*",
            "repo:<OWNER>@*/<REPO>@*:*"
          ]
        }
      }
    }
  ]
}
```

Notes on this policy:
- `Resource: "*"` is added only to satisfy strict validators — functionally trust policies don't need it, but it's harmless here
- Use `StringLike` (not `StringEquals`) whenever the `sub` condition contains a wildcard
- Include both the classic and immutable `sub` formats if you're not sure which one your repo emits
- Lock `sub` down to an exact branch with `StringEquals` only if you don't need wildcards at all

### Add a permissions policy (separate from trust policy)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

### Fix the workflow YAML

```yaml
permissions:
  id-token: write   # required to generate an OIDC token
  contents: read

jobs:
  terraform:
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ secrets.AWS_REGION }}
          role-to-assume: ${{ secrets.ROLE_TO_ASSUME }}

      - name: Verify identity before touching Terraform
        run: aws sts get-caller-identity

      - name: Terraform Init
        working-directory: ./terraform    # fixes the "empty directory" error
        run: terraform init
```

Or set the working directory once for the whole job:

```yaml
defaults:
  run:
    working-directory: ./terraform
```

### Clean up stuck workflows and dead runners

```bash
# Remove a live self-hosted runner cleanly
sudo ./svc.sh uninstall
./config.sh remove --token <TOKEN>   # token expires fast — generate right before running this
```

- Dead/offline runners with no host left: use **Force remove this runner** in the GitHub repo/org settings UI
- Stuck or runaway workflow runs: cancel from the Actions tab UI; delete history via the `...` menu

### Stop duplicate runs with concurrency control

```yaml
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: true
```

⚠️ Give each workflow a distinct `group` name — if two different workflows share the exact same group string, they'll cancel each other instead of just their own duplicates.

## 4. Key Concepts to Remember

- **Trust Policy vs. Permissions Policy** — this distinction is the single most important thing across every session:
  - **Trust policy** = *who* can assume the role (GitHub's OIDC provider, under what conditions)
  - **Permissions policy** = *what* the role can do once assumed (S3, EC2, etc.)
  - An `AssumeRoleWithWebIdentity` error → look at the trust policy. An `s3:...` or similar permission error → look at the permissions policy.
- **OIDC (OpenID Connect)** lets GitHub Actions trade a short-lived token with AWS instead of storing long-lived AWS access keys as secrets
- **Token claims:**
  - `aud` (audience) — who the token is for, normally `sts.amazonaws.com`
  - `sub` (subject) — which repo/branch/workflow the token came from
- **`StringEquals` vs. `StringLike`** — `StringEquals` is an exact match only; `*` inside it is treated literally, not as a wildcard. Use `StringLike` for pattern matching.
- **`permissions: id-token: write`** at the top of the workflow file is required before GitHub can even generate an OIDC token — this is a separate requirement from the AWS-side trust policy
- **Case sensitivity** — GitHub org/repo names are case-sensitive in AWS trust policy conditions
- **Terraform working directory** — `terraform init/plan/apply` only look at `.tf` files in their current directory; GitHub Actions starts in the repo root unless told otherwise

## 5. Things to Watch Out For Next Time

- ❌ Don't assume `*` works as a wildcard inside `StringEquals` — it doesn't; use `StringLike`
- ❌ Don't forget `permissions: { id-token: write, contents: read }` in the workflow — without it, no OIDC token is generated at all
- ❌ Don't leave workflow jobs inconsistent — if multiple jobs talk to AWS, they all need the same credentials config
- ❌ Don't hardcode an OIDC thumbprint from old notes — regenerate it from GitHub directly, since it can change
- ❌ Don't confuse trust policy problems with permissions policy problems — check `sts:AssumeRoleWithWebIdentity` errors against the trust policy first, not by broadening permissions
- ❌ Don't restrict `sub` to one exact branch with `StringEquals` unless you actually want that; use `StringLike` with a wildcard for flexibility across branches/PRs
- ❌ Don't forget case sensitivity in repo/org names inside trust policy conditions
- ❌ Don't let concurrency groups collide across different workflows — name them uniquely
- ✅ Verify AWS identity first with `aws sts get-caller-identity` before running any Terraform commands, to isolate OIDC issues from Terraform issues
- ✅ Check AWS CloudTrail logs when OIDC fails — they show the exact reason AWS rejected the token

"""

Notes of 05/09/2026:

"""

## 1. SOPS

- **`-i` option** — the `-i` flag in SOPS is mandatory because it writes the output to a temporary file first, then replaces the original file once SOPS finishes reading. This avoids corruption problems that could occur when decrypting a file in-place under the same name.
- **SOPS in GitHub Actions doesn't need AGE** — when running SOPS inside GitHub Actions, AGE is not required

## 2. GitHub Actions Jobs

- Jobs in GitHub Actions are **independent by default** and must use the `needs` keyword to create dependencies between them
- Use `actions/upload-artifact@v4` and `actions/download-artifact@v4` to pass artifacts between jobs

## 3. Terraform

### How to decide the number of `.tf` files

- **Responsibility per file** — each file should have a clear, single responsibility
- **Easy navigation** — splitting by resource type or feature area makes the project easier to navigate
- **Reuse versus copy-paste** — use modules and variables to avoid duplicating code across files

### Terraform State

- Terraform state represents the **current infrastructure status** as tracked by Terraform, stored in memory
- That state can be persisted in **local files** or in **cloud storage** (e.g., S3 + DynamoDB) — cloud is preferred

### Visualising Terraform Files

- Use `terraform graph` to generate a **dependency graph** of your `.tf` resources

"""

Notes of 17/10/2026:

"""

## 1. AWS Availability Zones in Terraform

- **Core Concept** — Never hardcode AZ names (e.g., `us-east-1a`). Use the `aws_availability_zones` data source to discover available zones dynamically.
- **Challenge** — Hardcoded names break if you change regions, or because AWS account-to-physical-AZ mappings vary between different accounts.

### Best Practice Code

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = "10.0.${count.index}.0/24"
}
```

- **Key Takeaway** — Use `count` combined with the dynamic `names` array to cleanly spread resources (like subnets) across multiple zones automatically.

## 2. Terraform `cidrsubnet` Function

### Core Takeaway

- `cidrsubnet("10.0.0.0/16", 8, count.index)` breaks a large `/16` network into smaller `/24` subnets (256 IPs each).
- The index shifts the third octet sequentially (`10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24`).

### AWS Gotcha

- ⚠️ AWS reserves **5 IPs per subnet**, meaning a `/24` provides **251 usable IPs** instead of 256.

### Best Practice

- **Automate, don't hardcode** — using `cidrsubnet` with `count.index` keeps your networking code clean and scalable.

## 3. Subnet Public IPs

- **What it does** — Setting `map_public_ip_on_launch = true` forces any new EC2 instance in that subnet to automatically get a public IPv4 address.
- **When to use it** — Use this only on **public subnets** (e.g., for web servers, load balancers, or bastion hosts). Keep it `false` for **private subnets** (e.g., databases) to secure them.
- **Terraform Behavior** — Terraform sets this to `false` by default. You must explicitly toggle it to `true` in your `aws_subnet` block.
- **Cost factor** — AWS charges for every public IPv4 address, so keeping it disabled on private subnets saves money.

## 4. AWS NAT Gateway

### Concepts Learned

- **Outbound Only** — A NAT Gateway allows instances in a **private subnet** to connect outbound to the internet (e.g., for software patches) while blocking unsolicited inbound connections.
- **Public vs. Private** — Public NAT Gateways live in a public subnet and use an Elastic IP (EIP) to hit the internet. Private NAT Gateways route traffic to other VPCs or on-premises networks without using an EIP.

### Constraints & Best Practices

- **AZ Isolation** — A NAT Gateway is highly available within a single AZ. If that AZ goes down, resources in other zones using it lose connectivity. For production, deploy **one NAT Gateway per AZ**.
- **No Security Groups** — You cannot attach a Security Group directly to a NAT Gateway. Traffic must be controlled at the instance level or via Subnet Network ACLs (NACLs).
- **Cost Factor** — Charges apply per hour and per GB processed. For heavy internal AWS traffic (like pushing to S3 or ECR), use **VPC Endpoints** instead to bypass NAT costs.

### Quick Setup Checklist

1. Deploy the NAT Gateway inside a **Public Subnet**.
2. Allocate and associate an **Elastic IP**.
3. Edit the **Private Subnet's Route Table** and add a route: `0.0.0.0/0` ➡️ `nat-gateway-id`.

## 5. Amazon EKS

### Concepts Learned

- **Amazon EKS Managed Control Plane** — AWS automatically runs and scales the Kubernetes API and etcd across multiple Availability Zones.
- **EKS Auto Mode** — A deployment option that automates node provisioning, updates, and cluster management with minimal overhead.

### Implementation Details

- **Cluster Deployment Command:**

```bash
eksctl create cluster --name my-cluster --region us-east-1 --managed
```

- **Authentication Command** — To connect your local machine to the new cluster:

```bash
aws eks update-kubeconfig --region us-east-1 --name my-cluster
```

### Decisions & Lessons Learned

- **IAM Prerequisites** — Separate IAM roles are strictly required for the cluster control plane (`AmazonEKSClusterPolicy`) and the worker nodes (`AmazonEKSWorkerNodePolicy`).

## 6. Dockerfile vs. Docker Compose

- **Dockerfile vs. Docker Compose** — A Dockerfile acts as a blueprint to build a **single container image**. Docker Compose acts as an orchestrator to link and run **multiple containers** simultaneously using a single YAML configuration.
- **Port Mapping Clarity** — When mapping container ports (e.g., `8080:3000`), the first number is the **external host port** (what you access in your browser) and the second is the **internal container port** (where the app actually runs).
- **Service Coordination** — To prevent an application container from crashing before its database dependency is fully up and running, you use the `depends_on` flag inside the Compose file to dictate startup order.
- **Data Persistence** — To prevent data loss when a database container is destroyed, you must declare dedicated `volumes` in your Compose file to safely map database storage to your host machine.

## 7. Docker Compose to Kubernetes Migration

### Core Takeaways

- **Keep the Dockerfile** — Kubernetes still needs images to run your app, so your Dockerfile never goes away.
- **Drop Compose for Production** — Kubernetes replaces Docker Compose entirely to handle your containers across a cluster.
- **Keep Compose for Local Dev** — It is best practice to keep your Compose file purely so developers can spin up the app instantly on their laptops without needing heavy Kubernetes tools.

### The Quick Translation Guide

When you move from Docker Compose to Kubernetes, your configuration shifts like this:

- `services` ➡️ **Deployments** (manages your app containers)
- `ports` ➡️ **Services** (handles internal/external routing)
- `volumes` ➡️ **PersistentVolumeClaims** (handles cluster storage)

### Key Tool to Remember

- **`kompose convert`** — A handy terminal tool that automatically rewrites your `docker-compose.yml` file into Kubernetes files for you.

## 8. Docker EXPOSE Instruction

- **EXPOSE is just a label** — It is strictly documentation for users and tools. It does **not** actually open or map ports to your host machine.
- **How to open ports** — To actually access your app from your computer, you must explicitly use the `-p host_port:container_port` flag when running the container (e.g., `docker run -p 8080:80`).
- **Default behavior** — If you don't specify a protocol (like `EXPOSE 80`), Docker assumes TCP.
- **Best practice** — Always include it right before your `CMD` or `ENTRYPOINT` line so other developers instantly know which port your app uses.

## 9. Dockerfile Basics & Multi-Stage Builds

- **Dockerfile Basics** — `FROM` sets the base, `WORKDIR` sets the folder, `COPY` moves files, `RUN` builds the setup, and `CMD` starts the app.
- **Multi-Stage Builds** — `as modules` names a build stage, and `COPY --from=modules` pulls the finished file into a clean, final image to remove build bloat.
- **`FROM scratch`** — A completely blank base image. It makes Go containers tiny (10–20MB) and highly secure because it contains no OS or shell for hackers to exploit.

## 10. Terraform + EKS Architecture

- **The Architecture** — Use official AWS VPC and EKS modules in Terraform to build the cluster safely in private subnets.
- **The Manifest Trick** — To handle dozens of raw K8s files without rewriting them to HCL, use the `gavinbunney/kubectl` provider to loop through a `/manifests` folder automatically.
- **The Golden Rule** — Terraform is great for spinning up the infrastructure (VPCs, EKS). For managing dozens of fast-moving app manifests, the industry standard is to hand them off to a **GitOps tool like ArgoCD**.

"""

Notes of 15/11/2026:

"""

# Kubernetes Migration, Multi-Tier Proxy, & Event-Driven Architecture — DevOps Notes


## 3. Multi-Tier Proxy Disambiguation (Edge vs. Gateway vs. Service Mesh)

Do not conflate the three distinct proxy layers across the architecture:

1. **Edge Reverse Proxy / Ingress (Traefik)**:
   - Operates at the cluster/environment perimeter.
   - Handles external client traffic, SSL termination, and path routing/prefix-stripping (e.g., routing `/api` to the Go gateway and `/` to the web frontend).
2. **API Gateway & Protocol Translation (Go Proxy)**:
   - Application-layer gateway listening on port `5000`.
   - **Protocol translation:** Web frontends speak HTTP/JSON; internal microservices (`product` on `5001`, `counter` on `5002`) communicate over internal gRPC (HTTP/2 + Protobuf). The proxy translates inbound HTTP/REST requests to backend gRPC calls, handles CORS preflight, and logs requests.
   - Decouples internal gRPC contracts from client browsers (exposing internal gRPC directly to public browser clients is an antipattern).
3. **Service Mesh Sidecar (Consul Connect / Envoy)**:
   - Infrastructure-layer proxy (configured in Nomad / Service Mesh setups).
   - Manages mutual TLS (mTLS), internal service identity, telemetry, and local upstream port bindings without hardcoded remote IP addresses.

---

## 4. Service Startup Dependencies: `initContainers` vs. `depends_on`

- **Kubernetes Startup Concurrency**:
  - Kubernetes has **no native `depends_on` directive**. All pods in a deployment are scheduled and booted concurrently.
  - Application services (`counter`, `barista`, `kitchen`) starting before backing stores (`postgres`, `rabbitmq`) enter `CrashLoopBackOff`, polluting logs and triggering false monitoring alerts.
- **TCP Health Gates via `initContainers`**:
  - Use lightweight `initContainers` running `busybox:1.36` with Netcat (`nc -z <service> <port>`) TCP polling to gate container startup until upstream dependencies accept connections.
- **Operational Rules**:
  - `initContainers` execute **strictly sequentially**. If an earlier init container hangs, subsequent init containers and the main application container are blocked indefinitely.
  - Never rely on `restartPolicy: Always` as a startup ordering mechanism.

```yaml
initContainers:
  - name: wait-for-postgres
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z postgres 5432; do echo waiting for postgres; sleep 2; done']
  - name: wait-for-rabbitmq
    image: busybox:1.36
    command: ['sh', '-c', 'until nc -z rabbitmq 5672; do echo waiting for rabbitmq; sleep 2; done']
```

## 6. RabbitMQ & Event-Driven Architecture (Production Operations)

- **Architecture Pattern**:
  - Implements a **Choreography Saga** for distributed transactions (`counter` initiates, `barista` and `kitchen` react via event queues).
  - Port **`5672`** handles AMQP application traffic; Port **`15672`** exposes the HTTP Management UI and Prometheus metrics endpoint.
- **Production Hardening & Gotchas**:
  - **Volume Durability:** Docker Compose configs often omit named volumes for RabbitMQ; in Kubernetes, durable queues require persistent storage via StatefulSets.
  - **Default Credentials:** Default `guest/guest` is restricted to localhost in RabbitMQ and must never be used in non-local environments; configure least-privilege users.
  - **At-Least-Once Delivery & Idempotency:** Network partitions and retries mean consumers will occasionally receive duplicate messages. Worker consumers must be idempotent (safe against duplicate processing).
  - **Broker Backpressure & Alarms:** RabbitMQ throttles/blocks upstream publishers when memory or disk watermarks are exceeded.
  - **Core Monitoring Telemetry:** Monitor **Queue Depth**, **Unacknowledged Message Count** (identifies stuck/crashed workers), and **Consumer Count** (detects worker starvation). Always configure Dead Letter Queues (DLQ) with retry limits to catch malformed poison-pill messages.

---