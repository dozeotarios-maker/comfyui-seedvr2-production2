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
# SeedVR2 node reads models from folder_paths.models_dir/SEEDVR2.
# comfy-cli model download writes to its own workspace (~comfy/ComfyUI) so it would land in the wrong place.
# Download directly to /comfyui/models/SEEDVR2/ instead.
RUN mkdir -p /comfyui/models/SEEDVR2 && \
    BACKOFFS="10 20 30 60 90" && for i in 1 2 3 4 5; do \
      curl -fL --retry 3 -H "Authorization: Bearer $HF_TOKEN" \
           -o /comfyui/models/SEEDVR2/ema_vae_fp16.safetensors \
           "https://huggingface.co/numz/SeedVR2_comfyUI/resolve/main/ema_vae_fp16.safetensors" && break; \
      if [ $i -eq 5 ]; then echo "VAE download failed after 5 attempts" >&2; exit 1; fi; \
      SLEEP=$(echo $BACKOFFS | cut -d " " -f $i) && echo "VAE attempt $i failed; retrying in $SLEEP seconds" >&2; sleep $SLEEP; \
    done
RUN BACKOFFS="10 20 30 60 90" && for i in 1 2 3 4 5; do \
      curl -fL --retry 3 -H "Authorization: Bearer $HF_TOKEN" \
           -o /comfyui/models/SEEDVR2/seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors \
           "https://huggingface.co/AInVFX/SeedVR2_comfyUI/resolve/main/seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors" && break; \
      if [ $i -eq 5 ]; then echo "DiT download failed after 5 attempts" >&2; exit 1; fi; \
      SLEEP=$(echo $BACKOFFS | cut -d " " -f $i) && echo "DiT attempt $i failed; retrying in $SLEEP seconds" >&2; sleep $SLEEP; \
    done

COPY handler.py /handler.py
