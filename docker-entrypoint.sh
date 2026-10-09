#!/usr/bin/env bash
set -euo pipefail

COMFYUI_DIR=${COMFYUI_DIR:-/app/ComfyUI}
CUSTOM_NODES_DIR="${COMFYUI_DIR}/custom_nodes"
CUSTOM_NODES_LIST="${CUSTOM_NODES_LIST:-/app/custom_nodes.txt}"
# Per-instance stamp dir: both comfyui services share the user/ mount but have
# SEPARATE venvs. A shared stamp dir made the 2nd instance to boot skip dep
# installs the 1st already stamped -> missing-module import failures. Key by
# hostname (compose sets distinct hostnames: comfyui / comfyui-video).
STATE_DIR="${COMFYUI_DIR}/user/.custom-node-bootstrap-$(hostname)"
LOCK_DIR="${STATE_DIR}.lock"

mkdir -p "${STATE_DIR}"

clone_listed_custom_nodes() {
  if [[ ! -s "${CUSTOM_NODES_LIST}" ]]; then
    return
  fi

  mkdir -p "${CUSTOM_NODES_DIR}"

  local line repo_url node_name target
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="$(echo "${line}" | tr -d '[:space:]')"
    [[ -z "${line}" ]] && continue

    repo_url="${line}"
    node_name="$(basename "${repo_url}")"
    node_name="${node_name%.git}"
    target="${CUSTOM_NODES_DIR}/${node_name}"

    if [[ -d "${target}" ]]; then
      continue
    fi

    echo "[bootstrap] cloning ${repo_url} -> ${node_name}"
    if ! git clone --depth=1 "${repo_url}" "${target}"; then
      echo "[bootstrap] failed to clone ${repo_url}; continuing"
    fi
  done < "${CUSTOM_NODES_LIST}"
}

cleanup_lock() {
  if [[ -d "${LOCK_DIR}" ]]; then
    rmdir "${LOCK_DIR}"
  fi
}

has_working_comfy_env_link() {
  local node_dir=$1
  local env_link

  while IFS= read -r env_link; do
    if [[ -x "${env_link}/bin/python" ]]; then
      return 0
    fi
  done < <(find "${node_dir}" -type l -name '_env_*' | sort)

  return 1
}

apply_comfy_env_compat_fixes() {
  python - <<'PY'
from pathlib import Path

targets = [
    Path("/app/ComfyUI/custom_nodes/ComfyUI-GeometryPack/nodes/gpu/comfy-env.toml"),
    Path("/app/ComfyUI/custom_nodes/ComfyUI-TRELLIS2/nodes/comfy-env.toml"),
]
drop = {"torch", "torchvision", "torchaudio"}

for path in targets:
    if not path.exists():
        continue

    text = path.read_text()
    marker = "packages = ["
    start = text.find(marker)
    if start == -1:
        continue

    end = text.find("]", start)
    if end == -1:
        continue

    body = text[start + len(marker):end]
    items = [item.strip() for item in body.split(",") if item.strip()]
    filtered = [item for item in items if item.strip("'\"") not in drop]
    if filtered == items:
        continue

    backup = path.with_name(path.name + ".bak-comfy-env-compat")
    if not backup.exists():
        backup.write_text(text)

    path.write_text(text[:start + len(marker)] + ", ".join(filtered) + text[end:])
    print(f"[bootstrap] patched comfy-env config: {path}")
PY
}

trap cleanup_lock EXIT

while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
  echo "[bootstrap] waiting for custom-node bootstrap lock..."
  sleep 2
done

bootstrap_custom_nodes() {
  if [[ ! -d "${CUSTOM_NODES_DIR}" ]]; then
    echo "[bootstrap] no custom_nodes directory at ${CUSTOM_NODES_DIR}"
    return
  fi

  while IFS= read -r node_dir; do
    local node_name req_file install_file root_config isolated_config stamp_req stamp_install req_hash install_hash comfy_env_ready

    node_name=$(basename "${node_dir}")
    req_file="${node_dir}/requirements.txt"
    install_file="${node_dir}/install.py"
    root_config="${node_dir}/comfy-env-root.toml"
    isolated_config="${node_dir}/comfy-env.toml"
    stamp_req="${STATE_DIR}/${node_name}.requirements.sha256"
    stamp_install="${STATE_DIR}/${node_name}.install.sha256"
    comfy_env_ready=1

    if [[ -s "${req_file}" ]]; then
      req_hash=$(sha256sum "${req_file}" | awk '{print $1}')
      if [[ ! -f "${stamp_req}" || "$(cat "${stamp_req}")" != "${req_hash}" ]]; then
        echo "[bootstrap] installing ${node_name} requirements"
        if python -m pip install --no-cache-dir --no-build-isolation -r "${req_file}"; then
          printf '%s\n' "${req_hash}" > "${stamp_req}"
        else
          echo "[bootstrap] failed to install ${node_name} requirements; continuing"
        fi
      fi
    fi

    if [[ -f "${install_file}" || -f "${root_config}" || -f "${isolated_config}" ]]; then
      install_hash=$(
        {
          [[ -f "${install_file}" ]] && sha256sum "${install_file}"
          find "${node_dir}" -maxdepth 2 -type f \( -name 'comfy-env*.toml' -o -name 'pyproject.toml' \) -print0 \
            | sort -z \
            | xargs -0r sha256sum
        } | sha256sum | awk '{print $1}'
      )
      if [[ -f "${root_config}" || -f "${isolated_config}" ]]; then
        if has_working_comfy_env_link "${node_dir}"; then
          comfy_env_ready=0
        fi
        if [[ ! -f "${stamp_install}" || "$(cat "${stamp_install}")" != "${install_hash}" || "${comfy_env_ready}" -ne 0 ]]; then
          echo "[bootstrap] running comfy-env install for ${node_name}"
          if (
            cd "${node_dir}"
            comfy-env install
          ); then
            printf '%s\n' "${install_hash}" > "${stamp_install}"
          else
            echo "[bootstrap] comfy-env install failed for ${node_name}; continuing"
          fi
        fi
      elif [[ ! -f "${stamp_install}" || "$(cat "${stamp_install}")" != "${install_hash}" ]]; then
        if [[ -f "${root_config}" || -f "${isolated_config}" ]]; then
          :
        elif [[ -f "${install_file}" ]]; then
          echo "[bootstrap] running ${node_name} install.py"
          if (
            cd "${node_dir}"
            python "${install_file}"
          ); then
            printf '%s\n' "${install_hash}" > "${stamp_install}"
          else
            echo "[bootstrap] install.py failed for ${node_name}; continuing"
          fi
        fi
      fi
    fi
  done < <(find "${CUSTOM_NODES_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name '__pycache__' | sort)
}

clone_listed_custom_nodes
apply_comfy_env_compat_fixes
bootstrap_custom_nodes

trap - EXIT
cleanup_lock

exec "$@"
