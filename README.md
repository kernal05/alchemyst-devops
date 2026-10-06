# Alchemyst AI 

A containerised, production-ready deployment of the **iii** multi-worker inference system, running a **Gemma 3 270M GGUF** model exposed as an OpenAI-compatible HTTP endpoint.

---

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

**Request flow:**
1. HTTP POST hits `iii-engine` on port `3111`
2. Engine routes to `caller-worker` → `http::run_inference_over_http`
3. Caller-worker triggers `inference::get_response` (itself)
4. That triggers `inference::run_inference` on inference-worker
5. Python runs Gemma 3 via HuggingFace Transformers, returns the generated text
6. Response bubbles back up as JSON

---

## Quick Start (Ubuntu local)

### Prerequisites
- Docker Engine ≥ 24 + Docker Compose plugin
- 8 GB free RAM (for the GGUF model)
- 20 GB disk (model + images)

### 1. Clone and launch

```bash
git clone https://github.com/YOUR_ORG/alchemyst-devops.git
cd alchemyst-devops
docker compose up --build
```

The first build downloads the `gemma-3-270m-Q8_0.gguf` model (~270 MB). Subsequent starts use the cached layer.

### 2. Verify all containers are up

```bash
docker compose ps
# NAME               STATUS
# iii-engine         Up (healthy)
# inference-worker   Up
# caller-worker      Up
```

### 3. Send a request

```bash
curl -s -X POST http://localhost:3111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "Explain what a transformer model is in 2 sentences."}
    ]
  }' | jq .
```

**Expected response shape:**
```json
{
  "result": {
    "success": "You've connected two workers...",
    "<model_output>": "A transformer model is..."
  }
}
```

### 4. Tear down

```bash
docker compose down -v    # -v also removes the state volume
```

---

## Project Structure

```
alchemyst-devops/
├── docker-compose.yml                  # Local orchestration
├── config.yaml                         # iii engine config (Docker-safe)
├── workers/
│   ├── inference-worker/
│   │   ├── Dockerfile
│   │   ├── inference_worker.py         # Registers inference::run_inference
│   │   ├── requirements.txt
│   │   └── iii.worker.yaml
│   └── caller-worker/
│       ├── Dockerfile
│       ├── src/worker.ts               # Registers http + get_response functions
│       ├── package.json
│       ├── tsconfig.json
│       └── iii.worker.yaml
├── infra/
│   ├── main.tf                         # GCP: VPC, VMs, NAT, firewall
│   ├── variables.tf
│   └── terraform.tfvars.example
├── scripts/
│   ├── setup-gateway.sh               # Cloud-init: installs Docker, starts engine
│   └── setup-worker.sh               # Cloud-init: starts inference worker
└── README.md
```

---

## GCP Deployment (Terraform)

### Prerequisites
- `terraform` ≥ 1.6
- `gcloud` CLI authenticated
- GCP project with Compute Engine API enabled

### Steps

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set your project_id

terraform init
terraform plan
terraform apply
```

After apply, Terraform prints the gateway's public IP:

```
gateway_public_ip = "34.x.x.x"
```

Hit the API:

```bash
curl -X POST http://34.x.x.x:3111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}]}'
```

### Infrastructure overview

| Resource | Purpose |
|---|---|
| `iii-vpc` + `iii-subnet` | Isolated private network `10.10.0.0/24` |
| Cloud Router + NAT | Outbound internet for private VMs (pip/npm/HuggingFace) |
| `iii-gateway` VM (e2-standard-2) | Runs `iii-engine` + `caller-worker`; has public IP |
| `iii-inference` VM (c2-standard-8) | Runs `inference-worker`; private only |
| Firewall `allow-internal` | All TCP within subnet |
| Firewall `allow-http-gateway` | Ports 3111, 22 from internet → gateway only |
| Service Account | Least-privilege SA for both VMs |

---

## Key Design Decisions

### Why Docker Compose for local?
Docker Compose gives a single-command local environment with a shared bridge network, matching the production topology (engine in the middle, workers as peers). The `depends_on: condition: service_healthy` ensures workers don't connect before the engine's WebSocket bus is ready.

### The `host: 0.0.0.0` fix in config.yaml
The original `config.yaml` had `host: 127.0.0.1` for `iii-http`. Inside Docker, this binds only to the container loopback — the port would never be reachable from outside the container. Changed to `0.0.0.0` so the engine accepts connections on all interfaces.

### Worker paths removed from config.yaml
The original config used `worker_path: /Users/anuran/...`. In Docker/GCP those paths don't exist. Workers connect autonomously over WebSocket using the `III_URL` env var — no `worker_path` stanza needed.

### Model pre-downloaded at build time
The `Dockerfile` runs `hf_hub_download` during `docker build`. This means:
- First build is slow but the model is baked into the image layer
- Container starts in seconds (no runtime download)
- Image is portable and reproducible

### GCP split: gateway vs inference VM
The `iii-engine` is lightweight; the inference workload is CPU/RAM intensive. Splitting them allows independent scaling — you can upgrade the inference VM (or add a GPU) without touching the gateway. The inference VM has no public IP (attack surface reduction); it reaches HuggingFace via Cloud NAT.

---

## Production Hardening Checklist

| Area | Recommendation |
|---|---|
| **Auth** | Add an API key / JWT middleware in front of the `iii-http` port; the current setup has no auth |
| **TLS** | Terminate HTTPS at a load balancer (Cloud Load Balancing or nginx) — never expose plain HTTP from a public IP in production |
| **Secrets** | Use GCP Secret Manager for any API keys; inject via env at runtime, not baked into images |
| **Image registry** | Push images to Google Artifact Registry; use digest pinning, not `:latest` |
| **Resource limits** | `docker-compose.yml` already caps inference at 8 GB / 4 CPUs; tune to your VM size |
| **Health checks** | Engine has a `/health` endpoint; add liveness probes to worker containers |
| **Logging** | `iii-observability` is configured with in-memory OTLP; swap `exporter: memory` → `exporter: otlp` and point to Cloud Trace / Grafana in prod |
| **State backup** | The SQLite `state_store.db` lives on a Docker volume; back it up or swap the adapter to a managed DB (e.g., Cloud Spanner, Redis) |
| **Firewall** | Lock port 22 down to your IP range (not `0.0.0.0/0`) in `infra/main.tf` |
| **IAM** | Follow least-privilege; the current SA has `cloud-platform` scope — tighten to only required APIs |

---

## Troubleshooting

**Workers not connecting to engine?**
```bash
docker compose logs iii-engine     # check it's listening on 49134
docker compose logs caller-worker  # look for "WebSocket connected"
```

**Model download fails?**
```bash
# Build with verbose output
docker compose build --progress=plain inference-worker
```

**Port 3111 already in use?**
```bash
sudo lsof -i :3111
# Change the host port in docker-compose.yml: "3112:3111"
```

---

## Production Hardening & Scale Considerations

### What I would harden before production

**Security:** Terminate TLS at an ALB with ACM certificate. Add JWT authentication middleware. Restrict SSH to bastion IP only. Move secrets to AWS Secrets Manager.

**Reliability:** Replace process management with systemd units for auto-restart. Add CloudWatch alarms on CPU and API error rates.

**Data:** Swap SQLite for ElastiCache Redis or RDS.

**Observability:** Ship traces to AWS X-Ray via OTLP exporter. Aggregate logs in CloudWatch.

### What I would do differently if the model were 100x larger

A 27B model in FP16 needs ~54GB VRAM. Changes required:

- Move to GPU instance (g4dn.12xlarge, 4x T4, 64GB VRAM)
- Use vLLM or TGI for serving with continuous batching
- Use FP8/GPTQ quantization to halve memory footprint
- Add iii-queue to buffer requests during GPU saturation
- Autoscale inference fleet via EC2 Auto Scaling Group on queue depth
- Use Spot Instances for ~60% cost reduction

The RPC interface stays identical — only inference_worker.py changes.
