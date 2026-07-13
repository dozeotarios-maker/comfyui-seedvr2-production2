# SeedVR2 video upscale endpoint
# Mirrors arcflow WAN worker-comfyui endpoint structure. handler.py unchanged
# (generic ComfyUI runner with R2 video upload). Only node set + R2 bucket differ.
# rebuild trigger 2026-07-12
FROM runpod/worker-comfyui:5.8.4-base

# Build-time HF token — public models today, arg kept for future gated weights.
# Pass via: docker build --build-arg HF_TOKEN=$HF_TOKEN ...
ARG HF_TOKEN=""

# ── R2 output store (separate bucket from WAN's arcflow1) ──────────────────
ENV R2_ACCESS_KEY_ID="3db290fd14ad4fa9d38bfc7df1a66f44"
ENV R2_SECRET_ACCESS_KEY="1cc5e183327586382cd999d522bfb64989e2c1bbfba5a6acc3e750eefd0c5289"
ENV R2_ENDPOINT_URL="https://5f09a7d129e0b4fbc3b2a271354f0c30.r2.cloudflarestorage.com"
ENV R2_BUCKET="arcflow-seedvr2"
ENV R2_PUBLIC_URL="https://pub-5ee5c2593b854b58a6116671ba6dfe60.r2.dev"

# ── Custom nodes ───────────────────────────────────────────────────────────
# SeedVR2: provides SeedVR2VideoUpscaler / SeedVR2LoadVAEModel /
# SeedVR2LoadDiTModel / CreateVideo / SaveVideo
RUN git clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler /comfyui/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler  && cd /comfyui/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler  && (git checkout 690cc39379c1481159ddd451368dbf2295930fc6 2>/dev/null      || (git fetch origin 690cc39379c1481159ddd451368dbf2295930fc6 --depth=1          && git checkout 690cc39379c1481159ddd451368dbf2295930fc6)      || echo "WARN: commit 690cc39379c1481159ddd451368dbf2295930fc6 unreachable, falling back to default branch HEAD")

# VideoHelperSuite: provides VHS_LoadVideoPath / VHS_VideoInfo
RUN git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite /comfyui/custom_nodes/ComfyUI-VideoHelperSuite  && cd /comfyui/custom_nodes/ComfyUI-VideoHelperSuite  && git checkout 993082e4f2473bf4acaf06f51e33877a7eb38960 || true

RUN comfy node install --exit-on-fail comfyui-workflow-encrypt@1.0.0 --mode remote  || comfy node install --exit-on-fail comfyui-workflow-encrypt --mode remote

# Build deps for node extensions (gcc/g++ needed by some requirements builds)
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ build-essential python3-dev && rm -rf /var/lib/apt/lists/*

# Install Python deps for all custom nodes
# (SeedVR2 needs diffusers>=0.33.1, peft>=0.17.0, einops, gguf, rotary_embedding_torch, omegaconf, opencv-python)
RUN for f in /comfyui/custom_nodes/*/requirements.txt; do pip install --no-cache-dir -r "$f" || true; done

RUN pip install --no-cache-dir runpod boto3 requests

# ── Models baked into image (fp8 7B DiT + fp16 VAE, ~7GB) ──────────────────
# Both repos are public/ungated today; HF_TOKEN kept for resilience.
# Download SeedVR2 model weights directly to /comfyui/models/SEEDVR2/ (the path the node reads from).
# Uses huggingface_hub (already installed via comfy-cli) — respects HF_TOKEN, handles retries,
# and writes to an explicit local_dir so we avoid comfy-cli workspace path resolution issues.
RUN mkdir -p /comfyui/models/SEEDVR2 && \
    python3 -c "\"\
from huggingface_hub import hf_hub_download\
hf_hub_download(repo_id=\"numz/SeedVR2_comfyUI\", filename=\"ema_vae_fp16.safetensors\", local_dir=\"/comfyui/models/SEEDVR2\")\
hf_hub_download(repo_id=\"AInVFX/SeedVR2_comfyUI\", filename=\"seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors\", local_dir=\"/comfyui/models/SEEDVR2\")\
\"


COPY handler.py /handler.py
