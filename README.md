# Alchemyst AI — Containerised Inference Deployment

A containerised deployment of the **iii** multi-worker inference system, running a Gemma 3 270M GGUF model exposed as an OpenAI-compatible HTTP endpoint. It runs locally with Docker Compose and is deployed to **AWS** with Terraform.

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │            Docker Network: iii-net       │
                        │                                          │
  curl / client         │  ┌──────────────────────────────────┐   │
  POST :3111 ──────────►│  │         iii-engine               │   │
  /v1/chat/completions  │  │  • WebSocket RPC bus  (:49134)   │   │
                        │  │  • HTTP API gateway   (:3111)    │   │
                        │  │  • iii-state  (KV / SQLite)      │   │
                        │  │  • iii-queue  (builtin)          │   │
                        │  │  • iii-observability (OTLP)      │   │
                        │  └──────────┬──────────┬────────────┘   │
                        │             │ RPC call │                 │
                        │  ┌──────────▼──────┐  │                 │
                        │  │  caller-worker  │  │                 │
                        │  │  (TypeScript)   │  │                 │
                        │  │  registers:     │  │                 │
                        │  │  • inference::  │  │                 │
                        │  │    get_response │  │                 │
                        │  │  • http::run_   │  │                 │
                        │  │    inference_   │  │                 │
                        │  │    over_http    │  │                 │
                        │  └──────────┬──────┘  │                 │
                        │             │ RPC call │                 │
                        │  ┌──────────▼──────────────────────┐   │
                        │  │      inference-worker (Python)   │   │
                        │  │  • loads Gemma 3 270M Q8 GGUF   │   │
                        │  │  • registers:                    │   │
                        │  │    inference::run_inference      │   │
                        │  └──────────────────────────────────┘   │
                        └─────────────────────────────────────────┘
```

**Request flow**

1. An HTTP POST hits `iii-engine` on port 3111.
2. The engine routes it to `caller-worker` → `http::run_inference_over_http`.
3. The caller worker triggers `inference::get_response` (itself).
4. That triggers `inference::run_inference` on the `inference-worker`.
5. The Python worker generates the text and returns it.
6. The response bubbles back up as JSON.

## Quick start (local, Docker Compose)

**Prerequisites:** Docker Engine ≥ 24 with the Compose plugin, about 8 GB of free RAM, and about 20 GB of disk (model plus images).

```bash
git clone https://github.com/kernal05/alchemyst-devops.git
cd alchemyst-devops
docker compose up --build
```

The first build downloads the `gemma-3-270m-Q8_0.gguf` model (~270 MB) and bakes it into the image layer, so later starts are fast.

Check that the containers are up:

```bash
docker compose ps
```

Send a request:

```bash
curl -s -X POST http://localhost:3111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Explain what a transformer model is in 2 sentences."}
    ]
  }' | jq .
```

The response is a JSON object with a `result` field containing the generated text.

Tear down (the `-v` flag also removes the state volume):

```bash
docker compose down -v
```

## Project structure

```
alchemyst-devops/
├── docker-compose.yml                  # Local orchestration
├── config.yaml                         # iii engine config (Docker-safe)
├── workers/
│   ├── inference-worker/               # Python worker: inference::run_inference
│   └── caller-worker/                  # TypeScript worker: HTTP + get_response
├── infra/
│   ├── main.tf                         # AWS: VPC, subnets, NAT, security groups, EC2
│   ├── variables.tf
│   └── terraform.tfvars.example
├── scripts/
│   ├── setup-gateway.sh                # Instance bootstrap: installs Docker, starts engine
│   └── setup-worker.sh                 # Instance bootstrap: starts inference worker
└── README.md
```

## AWS deployment (Terraform)

**Prerequisites:** Terraform ≥ 1.6, the AWS CLI configured with valid credentials, and permission to create VPC and EC2 resources.

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set your region, key pair and instance types

terraform init
terraform plan
terraform apply
```

`terraform.tfvars` and `*.tfstate` are git-ignored and must never be committed.

### What Terraform creates

| Resource | Purpose |
|---|---|
| VPC (`10.10.0.0/16`) | Isolated network |
| Public subnet + Internet Gateway | Hosts the gateway instance |
| Private subnet | Hosts the inference instance, no public IP |
| Elastic IP + NAT Gateway | Outbound internet for the private subnet (package installs, model downloads) |
| Public and private route tables | Route traffic for each subnet |
| Security group: gateway | Controls inbound access to the gateway |
| Security group: inference | Controls inbound access to the inference instance |
| Key pair | SSH access |
| EC2 instance: gateway | Runs `iii-engine` and `caller-worker` |
| EC2 instance: inference | Runs `inference-worker` |

Instance sizes are set in `variables.tf` (`gateway_instance_type`, `inference_instance_type`).

### Design note: AWS to GCP mapping (not built)

The application itself is cloud-agnostic, since it is Docker plus a WebSocket bus. Only `infra/` is AWS-specific. A GCP port would map like this. This is a design note and has not been implemented or tested.

| AWS (deployed) | GCP equivalent |
|---|---|
| VPC + subnets | VPC + subnets |
| NAT Gateway | Cloud NAT |
| Security groups | Firewall rules |
| EC2 instances | Compute Engine VMs |
| IAM role / instance profile | Service account |
| ALB + ACM | Cloud Load Balancing + managed certificate |
| Secrets Manager | Secret Manager |
| CloudWatch / X-Ray | Cloud Monitoring / Cloud Trace |

## Key design decisions

**Docker Compose for local.** One command gives a shared bridge network that mirrors the deployed topology, with the engine in the middle and workers as peers. `depends_on: condition: service_healthy` stops workers from connecting before the engine's WebSocket bus is ready.

**`host: 0.0.0.0` in `config.yaml`.** The original config bound the HTTP server to `127.0.0.1`. Inside Docker that is the container's own loopback, so the port was unreachable from outside. Changing it to `0.0.0.0` makes the engine accept connections on all interfaces.

**Worker paths removed from `config.yaml`.** The original config contained absolute paths from the author's machine. Workers connect over WebSocket using the `III_URL` environment variable, so no `worker_path` entries are needed.

**Model downloaded at build time.** The Dockerfile fetches the model during `docker build`. The first build is slower, but the image is portable and reproducible, and containers start in seconds with no runtime download.

**Gateway and inference split.** The engine is lightweight, while inference is CPU and RAM heavy. Separate instances let them scale independently, and the inference instance has no public IP, which reduces the attack surface. It reaches the internet only through the NAT Gateway.

## Production hardening (not yet implemented)

This is a working deployment, not a hardened one. Before production I would add:

| Area | What I would change |
|---|---|
| Auth | API key or JWT validation in front of port 3111. There is currently none. |
| TLS | Terminate HTTPS at an Application Load Balancer with an ACM certificate. Never expose plain HTTP publicly. |
| SSH | Restrict port 22 to a known IP range or remove it and use SSM Session Manager. |
| IAM | Least-privilege instance role scoped to the APIs actually needed. |
| Secrets | AWS Secrets Manager, injected at runtime and never baked into images. |
| Images | Push to ECR and pin by digest instead of `:latest`. |
| Reliability | Run containers under systemd or an orchestrator for restarts. Add liveness checks for workers and CloudWatch alarms on CPU and error rate. |
| State | Replace the SQLite volume with a managed store (for example ElastiCache Redis) or back the volume up. |
| Observability | Switch `exporter: memory` to an OTLP exporter and send traces to X-Ray or Grafana. Aggregate logs in CloudWatch. |

## If the model were 100x larger

A 100x larger model (about 27B parameters) needs roughly 54 GB of memory in FP16, so the serving layer changes:

- Move inference to a multi-GPU instance (for example `g5.12xlarge`, 4x A10G, or `g4dn.12xlarge`, 4x T4).
- Serve with vLLM or TGI for continuous batching.
- Use FP8 or GPTQ quantization to roughly halve the memory footprint.
- Use `iii-queue` to buffer requests while GPUs are saturated.
- Autoscale the inference fleet with an Auto Scaling Group driven by queue depth.
- Use Spot Instances for non-critical load to cut cost.

The RPC interface stays the same. Only the inference worker changes.

## Troubleshooting

Workers not connecting to the engine:

```bash
docker compose logs iii-engine       # check it is listening on 49134
docker compose logs caller-worker    # look for a WebSocket connection message
```

Model download fails:

```bash
docker compose build --progress=plain inference-worker
```

Port 3111 already in use:

```bash
sudo lsof -i :3111
# Change the host port in docker-compose.yml, for example "3112:3111"
```
