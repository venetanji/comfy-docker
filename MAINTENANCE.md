# comfy-docker — State & Rebuild Guide

_Last updated: 2026-09-19. Authoritative operating notes for this ComfyUI deployment on **thor**. Verified against the live system._

> ⚠️ **The build depends on UNTRACKED files.** Only `Dockerfile`, `compose.yaml`, `manager.ini`, `requirements.txt`, `serve.json`, `.gitignore` are git-tracked. The Dockerfile `COPY`s `docker-entrypoint.sh`, `custom_nodes.txt`, `plugin-requirements.txt`, `wheels/`, the build needs `.dockerignore` (allow-list — without it the ~27 GB working dir is shipped as build context), the sidecars build from `Dockerfile.tailscale`, and compose mounts `nginx.conf` — **all currently untracked**. A fresh `git clone` or `git clean -fdx` loses them and the build fails at `COPY docker-entrypoint.sh`. The **working tree at `/home/venetanji/dev/comfy-docker` is the source of truth** — back it up / commit the build files before relying on git.

## 0. First-time bring-up on a new host

The in-place rebuild (§4) assumes an already-provisioned host. From scratch you also need:

1. **External docker network** (compose declares `tailscale-mesh` as `external: true`):
   `docker network create tailscale-mesh`
2. **`.env`** from `.env.example`, with **two distinct Tailscale auth keys**: `TS_AUTHKEY` (for `comfyui`) and `TS_AUTHKEY_VIDEO` (for `comfyui-video`). `.env` holds secrets, is gitignored, and **must be recreated** on a new host (not recovered from git). `COMFYUI_BRANCH` in `.env`/`.env.example` is wired into the image build and selects the ComfyUI git ref (see §4).
3. **Two NVIDIA GPUs** + the nvidia container runtime (compose pins `device_ids: 0` / `1`).
4. The **host model dir** `/home/venetanji/dev/ComfyUI/models` (~384 GB) must exist (bind-mounted).
5. The build-critical untracked files (see banner) must be present in the working tree.

Then `docker compose up -d`.

## 1. Architecture

One Dockerfile builds the image for **two ComfyUI instances** sharing a model store + custom-node volume, on different GPUs with their own DBs/venvs:

| Service | Container | GPU | Hostname | DB | Extra flag |
|---|---|---|---|---|---|
| `comfyui` | `comfy-docker-comfyui-1` | 0 (RTX 3080 Ti) | `comfyui` | `comfyui-primary.db` | `--use-sage-attention` |
| `comfyui-video` | `comfy-docker-comfyui-video-1` | 1 (RTX 3090) | `comfyui-video` | `comfyui-video.db` | — |

**Sidecar image (since 2026-09-19):** `comfy-docker-tailscale:local` = `tailscale/tailscale:latest` + `ethtool` (`Dockerfile.tailscale`). The compose anchor wraps `containerboot` in `/bin/sh -c` (under `init: true`) that waits for `tailscale0` and runs `ethtool -K tailscale0 tso off gso off gro off`, logging `[tso-fix] …` — the TSO fix (§8) is therefore applied at every sidecar start. Update tailscale with `docker compose build --pull tailscale-serve tailscale-serve-video` then recreate the sidecars **and** their netns dependents (`up -d --force-recreate tailscale-serve tailscale-serve-video comfyui nginx comfyui-video nginx-video`).

**Request path:** host `:8189`/`:8190` → `tailscale-serve` sidecar (HTTPS :443, `serve.json`) → **nginx :8188** (`nginx.conf`: asset cache, `/ws` upgrade, SSE no-buffering) → **ComfyUI :8199**. The comfyui container uses `network_mode: service:tailscale-serve`, so it shares the sidecar's network namespace **and hostname**. ComfyUI itself listens only on **8199**; reach it for diagnostics via `docker exec <c> ... http://127.0.0.1:8199`.

**Per-service image tags (gotcha):** the two services build SEPARATE tags — `comfy-docker-comfyui` and `comfy-docker-comfyui-video`. `docker compose build comfyui` only rebuilds the first; build both, or build one and retag the other.

## 2. Current state (2026-09-19)

- **ComfyUI git ref is build-configurable** via `COMFYUI_BRANCH` (defaults to `master`; was previously pinned to `v0.36.0` in the Dockerfile).
- **torch 2.14.0+cu130**, frontend 1.52.7, Python 3.12.3, kornia 0.8.3, **comfy-env pinned 0.4.3** (§8), CUDA-13 base.
- Node types loaded: **2159 on both** (v0.25.1 had 1902/1886).
- **kjnodes 1.4.7** (from 1.3.1, for `Ideogram4PromptBuilderKJ` / `Ideogram4OptimizationsKJ`). Old copy tarballed at `user/.node-backups/comfyui-kjnodes-1.3.1.tar.gz`.
- Storyboard→video pipeline is **node-complete on both instances**; still needs the Ideogram-4 + Qwen3-VL **model** downloads to actually generate.

## 3. What is baked vs mounted (persists across recreation)

ComfyUI **code is baked into the image** (git clone at build) — an in-place `git pull` is lost on recreation. Persists:

| Host source | → container | Type |
|---|---|---|
| `/home/venetanji/dev/ComfyUI/models` | `/app/ComfyUI/models` | bind (~384 GB, shared) |
| `comfy-docker/user` | `/app/ComfyUI/user` | bind (DBs, bootstrap stamps, node-backups) |
| `/home/venetanji/dev/ComfyUI/user/default/workflows` | `…/user/default/workflows` | bind |
| `comfy-docker/input`, `comfy-docker/output` | `…/input`, `…/output` | bind |
| `comfy-docker/.ce` | `/root/.ce` | bind (comfy-env workspace) |
| `comfy-docker/manager.ini` | `/app/ComfyUI/user/__manager/config.ini` (ro) | bind (Manager: security_level=normal, network_mode=personal_cloud, update_policy=stable-comfyui) |
| named volume `comfy-docker_custom_nodes` | `/app/ComfyUI/custom_nodes` | **named volume (~30 nodes — see §5)** |

**NOT persisted (ephemeral, reset on every `--force-recreate`):** the container writable layer, incl. `/root/.cache/huggingface` → **HF login is lost on recreate** (see §9).

## 4. Build / rebuild procedure (version bumps)

The version lives in **`COMFYUI_BRANCH`** (forwarded by compose to the Docker build). Set it in `.env` / `.env.example` to a branch, tag, or other git ref before rebuilding.

> Pre-flight: confirm the target tag ships the nodes you need, e.g.
> `curl -s https://api.github.com/repos/Comfy-Org/ComfyUI/git/trees/vX.Y.Z?recursive=1 | grep -i <node-or-file>`

```bash
cd /home/venetanji/dev/comfy-docker
V=0.25.1   # the version you are LEAVING — used to name rollback assets

# 0. SAFETY — version-stamp rollback assets so create/restore names match (see Rollback)
docker exec comfy-docker-comfyui-1 sh -lc "cd /app/ComfyUI/user; for d in comfyui-primary comfyui-video; do cp -a \$d.db \$d.db.pre-v$V.bak; done"
docker tag comfy-docker-comfyui:latest        comfy-docker-comfyui:rollback-v$V
docker tag comfy-docker-comfyui-video:latest  comfy-docker-comfyui-video:rollback-v$V

# 1. Bump the ref
sed -i 's/^COMFYUI_BRANCH=.*/COMFYUI_BRANCH=vX.Y.Z/' .env

# 2. Build (old containers keep serving). Build the comfyui image, then retag for the video service.
docker compose build comfyui
docker tag comfy-docker-comfyui:latest comfy-docker-comfyui-video:latest   # same build, second tag

# 3. Clear bootstrap stamps so custom-node deps reinstall into the FRESH venv (§5).
#    Glob matches both the legacy shared dir and the new per-hostname dirs.
rm -rf user/.custom-node-bootstrap*

# 4. Staggered recreate: canary first, verify (§7), then video.
docker compose up -d --no-deps --force-recreate comfyui
#   …verify §7…
docker compose up -d --no-deps --force-recreate comfyui-video
```

First boot after a rebuild is slow (~100 s+): the entrypoint reinstalls every custom-node's requirements into the new venv. **After recreate, re-auth HF if you'll download models (§9).**

### Rollback (to the version you left)
```bash
V=0.25.1   # the version you rolled back FROM is gone; restore the pre-bump assets named below
docker tag comfy-docker-comfyui:rollback-v$V        comfy-docker-comfyui:latest
docker tag comfy-docker-comfyui-video:rollback-v$V  comfy-docker-comfyui-video:latest
# if the new version migrated the sqlite schema (forward-only), restore the DBs first:
docker exec comfy-docker-comfyui-1 sh -lc "cd /app/ComfyUI/user; for d in comfyui-primary comfyui-video; do cp -a \$d.db.pre-v$V.bak \$d.db; done"
docker compose up -d --force-recreate comfyui comfyui-video
```
**Current materialized assets** (from the v0.25.1→v0.36.0 upgrade, 2026-09-19): images `comfy-docker-comfyui{,-video}:rollback-v0.25.1`; DB backups `user/{comfyui-primary,comfyui-video}.db.pre-v0.25.1.bak`. The older `:rollback-v0.20` images (2×22.5 GB) and `…pre-v0.25.bak` DBs are obsolete (two versions back) — delete them to reclaim disk: `docker rmi comfy-docker-comfyui:rollback-v0.20 comfy-docker-comfyui-video:rollback-v0.20`.

## 5. Custom nodes

- **`custom_nodes.txt`** = git URLs the entrypoint **clones on container start** (`#` comments incl. inline are stripped; **clone-if-missing only**, never updates). Lists 5: `ID-LoRA-LTX2.3-ComfyUI`, `comfyui-various` (JWStringMultiline), `WhatDreamsCost-ComfyUI` (LTXDirector), `ComfyUI-QwenVL`, `ComfyUI-Inspire-Pack`.
- ⚠️ **`custom_nodes.txt` is NOT a complete recovery manifest.** The named volume `comfy-docker_custom_nodes` holds **~30 node dirs** — most installed via ComfyUI-Manager and absent from `custom_nodes.txt`, with no declarative source. **If the volume is lost, they're unrecoverable**, including load-bearing **kjnodes** (provides `Ideogram4PromptBuilderKJ`/`VAELoaderKJ` that §7 checks). Current volume contents:
  `ComfyMath, ComfyUI-Env-Manager, ComfyUI-FFmpeg, ComfyUI-GGUF, ComfyUI-GeometryPack, ComfyUI-Inspire-Pack, ComfyUI-LTXVideo, ComfyUI-MelBandRoFormer, ComfyUI-Pulse-MeshAudit, ComfyUI-QwenTTS, ComfyUI-QwenVL, ComfyUI-TRELLIS2, ComfyUI-Whisper, ID-LoRA-LTX2.3-ComfyUI, WhatDreamsCost-ComfyUI, comfy-mtb, comfyui-custom-scripts, comfyui-easy-use, comfyui-kjnodes, comfyui-rtx-video-suite, comfyui-sam3dobjects, comfyui-simple-prompt-batcher, comfyui-videohelpersuite, comfyui_essentials, comfyui_queue_manager, derfuu_comfyui_moddednodes, promptmodels`.
  **Back it up:** `docker run --rm -v comfy-docker_custom_nodes:/cn -v "$PWD":/out alpine tar czf /out/custom_nodes-backup.tgz -C /cn .`
- **Add a node:** add its URL to `custom_nodes.txt` (persists), optionally `git clone` into the volume now (needs a restart to import). Resolve a repo from a `cnr_id`: `curl -s https://api.comfy.org/nodes/<cnr_id>` → `.repository`.
- **Update an existing node** (`custom_nodes.txt` won't): re-clone it or use ComfyUI-Manager (`--enable-manager` is on; behavior governed by `manager.ini`). Manager-installed nodes are flat copies (no `.git`); tarball the old dir to `user/.node-backups/` (NOT inside `custom_nodes/`, or it double-loads) then `git clone` the latest.

### ⚠️ Shared-stamp / per-venv gotcha (fixed, active next rebuild)
Both services share `user/` but have **separate venvs**. Bootstrap install **stamps** lived in `user/.custom-node-bootstrap/` (shared) — so the *2nd* instance to boot saw the *1st*'s stamps and **skipped installing those deps into its own venv** → `ModuleNotFoundError` (hit `comfyui-various`→`soundfile`, `Inspire-Pack`→`webcolors`).
**Fixes in repo (apply on next rebuild):**
- `docker-entrypoint.sh`: per-instance stamp dir `…/.custom-node-bootstrap-$(hostname)` (hostnames `comfyui`/`comfyui-video`).
- `plugin-requirements.txt`: baked `soundfile` (comfyui-various has **no** requirements.txt — undeclared dep), `webcolors`, `matplotlib`, `cachetools`.
(Running containers still have the old shared-stamp entrypoint; they were patched manually after the upgrade.)

## 6. Vendored wheels

`plugin-requirements.txt` can reference local wheels under `wheels/` (Dockerfile `COPY wheels /app/wheels`). Used for **`comfy-dynamic-widgets`** 0.1.6, **unpublished from PyPI (404)** — reconstructed wheel at `wheels/comfy_dynamic_widgets-0.1.6-py3-none-any.whl` (consumed by ComfyUI-GeometryPack). To vendor another dead-from-PyPI pkg: extract from the old image's venv, zip `pkg/` + `pkg-*.dist-info/` into a `…-py3-none-any.whl`, drop in `wheels/`, reference its `/app/wheels/…whl` path.

## 7. Verification after a (re)build

```bash
docker exec comfy-docker-comfyui-1 python3 -c '
import json,urllib.request
d=json.load(urllib.request.urlopen("http://127.0.0.1:8199/object_info",timeout=30))
print("nodes:",len(d))
for n in ["Ideogram4Scheduler","Ideogram4PromptBuilderKJ","JWStringMultiline","LTXDirector",
          "AILab_QwenVL","LoadImageListFromDir //Inspire","VAELoaderKJ","UnetLoaderGGUF"]:
    print(("OK " if n in d else "MISS ")+n)'
docker logs --since 5m comfy-docker-comfyui-1 2>&1 | grep -iE "IMPORT FAILED|ModuleNotFound"
# Repeat for comfy-docker-comfyui-video-1 — the 2nd instance is where shared-stamp dep-skips surface.
```

## 8. Known issues

- **`ComfyUI-LTXVideo` import failure (FIXED 2026-06-20)** — v0.25.1's kornia 0.8.3 removed `pad` from `kornia.geometry.transform.pyramid`, so `pyramid_blending.py:7` raised `ImportError` and the **whole pack failed to register** — taking down the IC-LoRA nodes (`LTXICLoRALoaderModelOnly`, `LTXAddVideoICLoRAGuide`) the creative-skills `ltx2.py` ingredients/HDR/union-control pipeline depends on. (It is NOT unused — the earlier "not used" note was wrong.) **Fix applied:** in the shared `comfy-docker_custom_nodes` volume, edited `ComfyUI-LTXVideo/pyramid_blending.py` — dropped `pad` from the kornia import and aliased `pad = F.pad` (torch's `F.pad` has the same `(input, pad, mode)` signature; "reflect"/"replicate"/"constant" map 1:1). Original backed up to `pyramid_blending.py.bak-kornia083`. The volume is **shared** by both instances, but only `comfy-docker-comfyui-video-1` was restarted to reload it — restart `comfy-docker-comfyui-1` to pick it up there too. **This patch lives in the volume and survives restart/recreate, but is lost if the node is re-cloned/updated or the volume is destroyed** — re-apply then (or upstream it / pin kornia).
- **`ComfyUI-LTXVideo` broke again on v0.36.0 (FIXED 2026-09-19)** — core PR #15056 replaced `interleaved_freqs_cis`/`split_freqs_cis` with `freqs_cis_matrix` in `comfy/ldm/lightricks/model.py`, so the May checkout (229437c) failed import and the IC-LoRA nodes vanished. Fix: `git pull` the volume checkout to upstream `dfb2786` (2026-09-17, has a try/except for both cores). Upstream still imports `pad` from kornia, so the `pad = F.pad` patch above was **re-applied** (backup `pyramid_blending.py.bak-upstream-dfb2786`). The new upstream requirements (`colour-science`, `openimageio`, `ninja`, `transformers[timm]`) were installed by the boot bootstrap on both instances.
- **`comfy-env` / 3D-pack bootstrap compatibility** — the image still pins **`comfy_env==0.4.3`** because newer releases reject the old root-config format shipped by `ComfyUI-GeometryPack` / `ComfyUI-TRELLIS2`. On newer node checkouts, those packs also place plain `torch` / `torchvision` in `[cuda].packages`, which current `comfy-env` rejects because bootstrap torch is already workspace-pinned. `docker-entrypoint.sh` now strips `torch` / `torchvision` / `torchaudio` from the known GeometryPack/TRELLIS2 CUDA package lists before running `comfy-env install`, so the bootstrap pass can complete without disabling the packs.
- **Host nvidia driver upgrade → comfy dies at next boot with Exited (127)** (seen 2026-09-19): Docker injects the GPU via the CDI spec `/etc/cdi/nvidia.yaml`; Arch's pacman hook cannot regenerate it while the old kernel module is loaded and leaves stale library paths. After the reboot run `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` on the host, then `docker start` the dead comfy container (no recreate needed).
- **Sidecar TSO/GSO/GRO regression (FIXED PERSISTENTLY 2026-09-19)** — kernel-TUN offloads on the sidecars' `tailscale0` produce super-packets that die after WireGuard encapsulation; outbound TCP from the sidecar stalls, so tailnet HTTPS to comfy times out (it was dead for weeks in Sep 2026, unnoticed because agents use `media-relay`). `ethtool -K` is per-device and lost on every restart, so it is now applied by the sidecar entrypoint wrapper (§1) from the local image that ships ethtool. Verify after any sidecar restart: `docker logs comfy-docker-tailscale-serve-1 | grep tso-fix` shows `off off off`.
- **3D-node bootstrap failures** (`GeometryPack`, `TRELLIS2`, `Pulse-MeshAudit`, `ID-LoRA` requirements) are **pre-existing & non-fatal** — strict pins (`comfy-env==…`) / cuda-wheel probing; the nodes still register (GeometryPack 2, TRELLIS2 17, Pulse-MeshAudit 1). `ID-LoRA` only fails on its training-only `ltx-trainer` line.
- **Shared-netns orphan after recreate → tailnet 502 (seen 2026-06-20).** `comfyui*` + `nginx*` use `network_mode: service:tailscale-serve*` (share the sidecar's netns). A `docker compose ... up --force-recreate` of the **sidecar** (e.g. during the v0.25.1 upgrade) can leave comfy/nginx in their OWN netns (only `lo`), so the tailnet path 502s (`nginx connect() failed (111) upstream 127.0.0.1:8199`) even though comfy answers fine via `docker exec … 127.0.0.1:8199`. **Diagnose:** `docker exec <c> sh -lc 'cat /proc/net/dev'` — a healthy member shows `eth0/eth1/tailscale0`, an orphan shows only `lo`; or from the sidecar `wget 127.0.0.1:8199` / `:8188`. **Fix:** `docker compose --env-file .env up -d --no-deps --force-recreate <comfyui-video|nginx-video>` to re-join the live sidecar netns (recreate joins reliably; a plain `docker restart` also preserves the join + the writable layer). Verify each has `tailscale0` and the tailnet returns 200. ⚠️ A **`--force-recreate` of comfy resets the writable layer** → runtime-installed custom-node deps (`soundfile` for `comfyui-various`, `webcolors`/`matplotlib`/`cachetools` for `Inspire-Pack`) are lost until a rebuild bakes `plugin-requirements.txt`; stop-gap on the current image: a volume `comfyui-various/requirements.txt` holding `soundfile`, and `Inspire-Pack`'s own requirements.txt already lists the rest (the boot install is occasionally flaky — re-run it or `docker restart`). Prefer `docker restart` over `--force-recreate` when you just need to reload (keeps both netns and deps).
- **Disk pressure:** host `/dev/nvme0n1p3` (912 G) ~**97% full** (33 G free); models are ~384 G. _History (2026-06-20): the v0.25.1 build hit 0 free; `docker builder prune -af` reclaimed ~17 G; further cleanup removed ~32 G of dup/unused models (gemma fp4, flux2 gguf, `.1` re-downloads)._

## 9. Operational tricks

- **HF auth — now PERSISTENT via `.env` (2026-06-20).** Previously ephemeral (`/root/.cache/huggingface/token` is wiped on `--force-recreate`). Fixed: a **read-only `HF_TOKEN`** lives in `.env` (gitignored) and compose injects it into both comfy services as `HF_TOKEN` + `HUGGING_FACE_HUB_TOKEN` (env on the `x-comfyui-service` anchor), so `huggingface_hub`/`hf` CLI auto-auth and **gated downloads survive recreate/rebuild**. Takes effect on the next `docker compose up` (running containers from before the edit don't have the env until recreated). ⚠️ `.env` is gitignored, so the token (like the TS authkeys) is **NOT recoverable from git** — back up `.env` / re-add the token on a new host (see top banner).
- **HF downloads:** `hf_hub_download`/`hf_transfer` stall ~80 MB from these containers; an **authed direct `resolve` URL** pulls at 100+ MB/s. For big/gated files use a resumable loop (`Authorization: Bearer <token>`, `Range: bytes=N-`, 30 s timeout, retry on stall) writing straight into `models/…`.
- **Reconstruct a wheel** from an installed package: zip `pkg/` + `pkg-*.dist-info/` from `/opt/venv/lib/python3.12/site-packages`.
- **`ts-monitor.py`** (repo root) — per-sidecar Tailscale traffic/connection dashboard (`python3 ts-monitor.py --interval N`; needs `rich`, `ss`, tailscale CLI). Use when debugging sidecar throughput/TSO issues.
