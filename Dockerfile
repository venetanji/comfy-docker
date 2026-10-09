# Stage 0: CUDA runtime base
FROM nvidia/cuda:13.1.1-cudnn-devel-ubuntu24.04 AS cuda_base

# Stage 1: obtain the `uv` binary from its distroless image
FROM ghcr.io/astral-sh/uv:latest AS uv_installer

# Stage 2: final image based on CUDA runtime
FROM cuda_base

ARG COMFYUI_BRANCH=master
ARG INSTALL_PLUGIN_DEPS=1
ENV DEBIAN_FRONTEND=noninteractive

# Install Python, pip and basic build tools
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       python3 python3-pip python3-dev git gcc build-essential ca-certificates ffmpeg sudo \
    && rm -rf /var/lib/apt/lists/*

# Copy the uv binary into the final image
COPY --from=uv_installer /uv /bin/uv
RUN chmod +x /bin/uv

WORKDIR /app

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# List of custom-node git URLs auto-cloned on container start (entrypoint).
COPY custom_nodes.txt /app/custom_nodes.txt

# Clone ComfyUI (branch/tag/commit ref configurable via build arg)
RUN git clone https://github.com/Comfy-Org/ComfyUI --depth=1 -b ${COMFYUI_BRANCH} /app/ComfyUI

# Create a dedicated virtual environment and use it for all installs/runtime.
RUN uv venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Use uv to install PyTorch wheels (CUDA 13.0 index) and ComfyUI requirements
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /opt/venv/bin/python --no-cache-dir \
    torch torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu130

# Some custom nodes still call `python -m pip`; install pip into the venv.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /opt/venv/bin/python --no-cache-dir pip

RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /opt/venv/bin/python --no-cache-dir -r /app/ComfyUI/requirements.txt \
    && uv pip install --python /opt/venv/bin/python --no-cache-dir -r /app/ComfyUI/manager_requirements.txt

# Allow the project to add extra requirements via the repository root
COPY requirements.txt /app/requirements.txt
RUN --mount=type=cache,target=/root/.cache/uv \
    if [ -s /app/requirements.txt ]; then \
      uv pip install --python /opt/venv/bin/python --no-cache-dir -r /app/requirements.txt; \
    fi

# Optional plugin dependencies (kept separate from base image requirements).
# Disable with: --build-arg INSTALL_PLUGIN_DEPS=0
COPY plugin-requirements.txt /app/plugin-requirements.txt
# Vendored wheels for packages no longer resolvable on PyPI (e.g. comfy-dynamic-widgets)
COPY wheels /app/wheels
RUN --mount=type=cache,target=/root/.cache/uv \
    if [ "${INSTALL_PLUGIN_DEPS}" = "1" ] && [ -s /app/plugin-requirements.txt ]; then \
      uv pip install --python /opt/venv/bin/python --no-cache-dir -r /app/plugin-requirements.txt; \
    else \
      echo "Skipping optional plugin dependencies"; \
    fi

LABEL maintainer="comfy-docker"

# Expose default ComfyUI port
EXPOSE 8188

# Run ComfyUI with the venv Python where dependencies were installed
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["python", "/app/ComfyUI/main.py", "--listen", "--port", "8188", "--enable-manager"]
