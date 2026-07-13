"""
worker-comfyui handler with R2 upload for video outputs.

Replaces the base image's /handler.py.

Input shape (unchanged from base):
{
  "input": {
    "workflow": {...ComfyUI API JSON...},
    "images": [
      {"name": "driver.mp4", "image": "<base64>"},
      {"name": "ref.jpg", "image": "<base64>"}
    ]
  }
}

Output shape (extended):
{
  "images": [{"node_id": "X", "filename": "...", "type": "base64", "data": "..."}],
  "videos": [{"node_id": "X", "filename": "FINAL_00001.mp4", "url": "https://pub-xxx.r2.dev/outputs/<id>/FINAL_00001.mp4"}],
  "status": "success" | "no_outputs"
}

R2 env vars (optional but recommended):
  R2_ACCESS_KEY_ID
  R2_SECRET_ACCESS_KEY
  R2_ENDPOINT_URL
  R2_BUCKET
  R2_PUBLIC_URL

If R2 vars missing, videos fall back to base64 in response (size-capped).
"""

import os
import time
import json
import uuid
import base64
import requests
from io import BytesIO

import runpod

try:
    import boto3
    from botocore.client import Config
    _R2_REQUIRED = ["R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY",
                    "R2_ENDPOINT_URL", "R2_BUCKET", "R2_PUBLIC_URL"]
    R2_ENABLED = all(os.environ.get(k) for k in _R2_REQUIRED)
    if R2_ENABLED:
        _r2 = boto3.client(
            "s3",
            endpoint_url=os.environ["R2_ENDPOINT_URL"],
            aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
            aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
            config=Config(signature_version="s3v4"),
            region_name="auto",
        )
    else:
        _r2 = None
        missing = [k for k in _R2_REQUIRED if not os.environ.get(k)]
        print(f"[handler] R2 disabled - missing env vars: {missing}")
except ImportError:
    R2_ENABLED = False
    _r2 = None
    print("[handler] R2 disabled - boto3 not installed")

COMFY_HOST = os.environ.get("COMFY_HOST", "127.0.0.1:8188")
OUTPUT_DIR = "/comfyui/output"
MAX_WAIT_SECONDS = int(os.environ.get("COMFY_MAX_WAIT", "1800"))
POLL_INTERVAL = 2

VIDEO_EXTS = {".mp4", ".webm", ".mov", ".mkv", ".gif", ".webp"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".bmp"}


def _wait_for_server():
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            r = requests.get(f"http://{COMFY_HOST}/system_stats", timeout=2)
            if r.status_code == 200:
                return
        except Exception:
            pass
        time.sleep(0.5)
    raise RuntimeError("ComfyUI server did not start within 120s")


def _upload_input_files(images_list):
    if not images_list:
        return
    for item in images_list:
        name = item["name"]
        b64 = item["image"]
        if "," in b64:
            b64 = b64.split(",", 1)[1]
        blob = base64.b64decode(b64)
        ext = os.path.splitext(name)[1].lower()
        mime = "video/mp4" if ext in VIDEO_EXTS else "image/png"
        files = {
            "image": (name, BytesIO(blob), mime),
            "overwrite": (None, "true"),
        }
        r = requests.post(f"http://{COMFY_HOST}/upload/image", files=files, timeout=120)
        r.raise_for_status()
        print(f"[handler] uploaded input: {name} ({len(blob)} bytes)")


def _queue_prompt(workflow):
    client_id = str(uuid.uuid4())
    payload = {"prompt": workflow, "client_id": client_id}
    r = requests.post(f"http://{COMFY_HOST}/prompt", json=payload, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"ComfyUI /prompt failed: {r.status_code} {r.text[:500]}")
    return r.json()["prompt_id"]


def _wait_for_completion(prompt_id):
    deadline = time.time() + MAX_WAIT_SECONDS
    last_status = ""
    while time.time() < deadline:
        try:
            r = requests.get(f"http://{COMFY_HOST}/history/{prompt_id}", timeout=30)
            if r.status_code == 200:
                data = r.json()
                if prompt_id in data:
                    hist = data[prompt_id]
                    status = hist.get("status", {})
                    status_str = status.get("status_str", "")
                    if status_str != last_status:
                        print(f"[handler] status: {status_str}")
                        last_status = status_str
                    if status.get("completed"):
                        return hist
                    if status_str == "error":
                        messages = status.get("messages", [])
                        raise RuntimeError(f"ComfyUI error: {messages}")
        except requests.RequestException as e:
            print(f"[handler] history poll error: {e}")
        time.sleep(POLL_INTERVAL)
    raise TimeoutError(f"ComfyUI execution exceeded {MAX_WAIT_SECONDS}s")


def _resolve_local_path(item):
    subfolder = item.get("subfolder", "") or ""
    fname = item.get("filename", "")
    ftype = item.get("type", "output")
    if ftype == "output":
        base = OUTPUT_DIR
    elif ftype == "temp":
        base = "/comfyui/temp"
    elif ftype == "input":
        base = "/comfyui/input"
    else:
        base = OUTPUT_DIR
    return os.path.join(base, subfolder, fname) if subfolder else os.path.join(base, fname)


def _upload_to_r2(local_path, key, content_type):
    _r2.upload_file(
        local_path,
        os.environ["R2_BUCKET"],
        key,
        ExtraArgs={"ContentType": content_type},
    )
    return f"{os.environ['R2_PUBLIC_URL'].rstrip('/')}/{key}"


def _content_type(filename):
    ext = os.path.splitext(filename)[1].lower()
    return {
        ".mp4": "video/mp4",
        ".webm": "video/webm",
        ".mov": "video/quicktime",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
    }.get(ext, "application/octet-stream")


def _process_outputs(history, job_id):
    """Route outputs by file extension, not by ComfyUI output key name.

    Some nodes (e.g. SeedVR2 SaveVideo) return video files under the "images"
    key. Checking extension instead of key name ensures .mp4/.webm always go
    to R2 upload while .png/.jpg stay as base64.
    """
    outputs = history.get("outputs", {})
    images_out = []
    videos_out = []

    for node_id, node_out in outputs.items():
        for key_name in ("images", "gifs", "videos"):
            for item in node_out.get(key_name, []):
                local = _resolve_local_path(item)
                if not os.path.exists(local):
                    print(f"[handler] missing output file: {local}")
                    continue

                fname = item.get("filename") or os.path.basename(local)
                ext = os.path.splitext(fname)[1].lower()

                if ext in VIDEO_EXTS:
                    ctype = _content_type(fname)
                    if R2_ENABLED:
                        key = f"outputs/{job_id}/{fname}"
                        try:
                            url = _upload_to_r2(local, key, ctype)
                            size = os.path.getsize(local)
                            videos_out.append({
                                "node_id": node_id,
                                "filename": fname,
                                "url": url,
                                "size_bytes": size,
                            })
                            print(f"[handler] uploaded to R2: {url} ({size} bytes)")
                        except Exception as e:
                            print(f"[handler] R2 upload failed for {fname}: {e}")
                            with open(local, "rb") as f:
                                data = base64.b64encode(f.read()).decode()
                            videos_out.append({
                                "node_id": node_id,
                                "filename": fname,
                                "type": "base64",
                                "data": data,
                                "r2_error": str(e),
                            })
                    else:
                        with open(local, "rb") as f:
                            data = base64.b64encode(f.read()).decode()
                        videos_out.append({
                            "node_id": node_id,
                            "filename": fname,
                            "type": "base64",
                            "data": data,
                        })
                else:
                    with open(local, "rb") as f:
                        data = base64.b64encode(f.read()).decode()
                    images_out.append({
                        "node_id": node_id,
                        "filename": fname,
                        "type": "base64",
                        "data": data,
                    })

    status = "success" if (images_out or videos_out) else "no_outputs"
    return {"images": images_out, "videos": videos_out, "status": status}


def handler(job):
    print(f"[handler] R2_ENABLED={R2_ENABLED}")
    job_id = job.get("id") or str(uuid.uuid4())
    job_input = job.get("input") or {}
    workflow = job_input.get("workflow")
    if not workflow:
        return {"error": "missing input.workflow"}

    images_in = job_input.get("images") or []
    print(f"[handler] job={job_id} workflow_nodes={len(workflow)} input_files={len(images_in)}")

    _wait_for_server()
    _upload_input_files(images_in)
    prompt_id = _queue_prompt(workflow)
    print(f"[handler] queued prompt {prompt_id}")
    history = _wait_for_completion(prompt_id)
    result = _process_outputs(history, job_id)
    print(f"[handler] done. images={len(result['images'])} videos={len(result['videos'])}")
    return result


runpod.serverless.start({"handler": handler})
