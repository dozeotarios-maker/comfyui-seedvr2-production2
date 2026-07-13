# clean base image containing only comfyui, comfy-cli and comfyui-manager
FROM runpod/worker-comfyui:5.8.4-base

# build-time tokens for gated downloads — never baked into final image.
# pass via: docker build --build-arg HF_TOKEN=$HF_TOKEN ...
ARG HF_TOKEN=""

# install custom nodes into comfyui
RUN git clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler /comfyui/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler && cd /comfyui/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler && (git checkout 690cc39379c1481159ddd451368dbf2295930fc6 2>/dev/null || (git fetch origin 690cc39379c1481159ddd451368dbf2295930fc6 --depth=1 && git checkout 690cc39379c1481159ddd451368dbf2295930fc6) || echo "WARN: commit 690cc39379c1481159ddd451368dbf2295930fc6 unreachable in https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler, falling back to default branch HEAD")
RUN comfy node install --exit-on-fail comfyui-workflow-encrypt@1.0.0 --mode remote || (echo "WARN: comfyui-workflow-encrypt@1.0.0 unavailable in registry, falling back to latest" >&2 && comfy node install --exit-on-fail comfyui-workflow-encrypt --mode remote)

# download models into comfyui
RUN BACKOFFS="10 20 30 60 90" && for i in 1 2 3 4 5; do HF_TOKEN=$HF_TOKEN comfy model download --url 'https://huggingface.co/numz/SeedVR2_comfyUI/resolve/main/ema_vae_fp16.safetensors' --relative-path models/Unknown --filename 'ema_vae_fp16.safetensors' && break; if [ $i -eq 5 ]; then echo "model-download failed after 5 attempts" >&2; exit 1; fi; SLEEP=$(echo $BACKOFFS | cut -d ' ' -f $i) && echo "model-download attempt $i failed; retrying in $SLEEP seconds" >&2; sleep $SLEEP; done
RUN BACKOFFS="10 20 30 60 90" && for i in 1 2 3 4 5; do HF_TOKEN=$HF_TOKEN comfy model download --url 'https://huggingface.co/AInVFX/SeedVR2_comfyUI/resolve/main/seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors' --relative-path models/Unknown --filename 'seedvr2_ema_7b_sharp_fp8_e4m3fn_mixed_block35_fp16.safetensors' && break; if [ $i -eq 5 ]; then echo "model-download failed after 5 attempts" >&2; exit 1; fi; SLEEP=$(echo $BACKOFFS | cut -d ' ' -f $i) && echo "model-download attempt $i failed; retrying in $SLEEP seconds" >&2; sleep $SLEEP; done
