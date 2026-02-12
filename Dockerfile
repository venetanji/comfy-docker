FROM nvidia/cuda:13.1.1-cudnn-runtime-ubuntu24.04

ARG COMFYUI_BRANCH=master
ENV DEBIAN_FRONTEND=noninteractive

RUN --mount=type=cache,target=/var/cache/apt --mount=type=cache,target=/var/lib/apt apt-get update \
    && apt-get install -y --no-install-recommends git gcc \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy the tiny `uv` runtime (used to automatically pick correct PyTorch+CUDA wheels)
ENV UV_COMPILE_BYTECODE=1

RUN mkdir -p /app
WORKDIR /app
RUN uv venv --python 3.12
ENV PATH="/app/.venv/bin:$PATH"
RUN --mount=type=cache,target=/root/.cache/uv uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu130

# Clone ComfyUI (branch configurable) into the build image
RUN git clone https://github.com/Comfy-Org/ComfyUI --depth=1 -b ${COMFYUI_BRANCH} /app/ComfyUI


# Use buildkit cache mounts for faster, cacheable builds.
RUN --mount=type=cache,target=/root/.cache/uv uv pip install -r /app/ComfyUI/requirements.txt \
    && uv pip install --no-cache-dir -r /app/ComfyUI/manager_requirements.txt

COPY requirements.txt /app/requirements.txt

RUN if [ -f /app/requirements.txt ]; then uv pip install -r /app/requirements.txt; fi 

# (optional) precompile/prepare any ComfyUI artifacts if needed
# e.g., build extensions or pre-download models — add commands here if you want them baked into the image

LABEL maintainer="comfy-docker"

# Ensure venv bin is on PATH
# Expose the default ComfyUI port
EXPOSE 8188

CMD ["uv", "run", "/app/ComfyUI/main.py", "--listen", "--port", "8188", "--enable-manager"]

