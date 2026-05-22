FROM python:3.11-slim
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY inference_worker.py .
COPY iii.worker.yaml .

# Pre-download GGUF model at build time for fast container startup
RUN python -c "
from huggingface_hub import hf_hub_download
hf_hub_download(
    repo_id='ggml-org/gemma-3-270m-GGUF',
    filename='gemma-3-270m-Q8_0.gguf',
    local_dir='/app/models',
)
"

ENV III_URL=ws://iii-engine:49134
ENV HF_HOME=/app/models

CMD ["python", "inference_worker.py"]
