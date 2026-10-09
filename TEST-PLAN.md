# Test Plan — Storyboard→Video Workflow + Ingredients IC-LoRA

_Written 2026-06-20 for a fresh session. Pairs with `MAINTENANCE.md` (deployment state)._

## Context (where everything is)

- **Instances** (see MAINTENANCE.md §1): `comfy-docker-comfyui-1` (GPU0, the Ideogram/image stage), `comfy-docker-comfyui-video-1` (GPU1, the LTX/video stage). API on internal **:8199** — reach via `docker exec <c> ... http://127.0.0.1:8199`, or the tailnet UIs `comfyui` / `comfyui-video`.
- **All custom nodes for the workflow are installed on both instances** (verified): `JWStringMultiline`, `Ideogram4PromptBuilderKJ`, `Ideogram4Scheduler`/`CFGOverride`/`DualModelGuider` (core), `LTXDirector`/`LTXDirectorGuide`, `AILab_QwenVL`, `LoadImageListFromDir //Inspire`, all `LTXV*` (comfy-core), `VAELoaderKJ`, `UnetLoaderGGUF`, `ShowText|pysssss`. Re-check with MAINTENANCE.md §7.
- **Ingredients IC-LoRA** is downloaded + validated: `models/loras/ltx-2.3-22b-ic-lora-ingredients-0.9.safetensors` (1.3 GB, rank-128 LTX-2.3-22B transformer LoRA, strength **1.4**, bf16).

## ⚠️ Pre-flight gotchas (read first)

1. **HF login is wiped** (the v0.25.1 recreate cleared `/root/.cache/huggingface`). Tier 2 downloads need re-auth: `docker exec -it comfy-docker-comfyui-1 hf auth login` (paste your token). **Tier 1 needs no downloads.**
2. **Disk: only ~33 GB free** (97% full). Tier 2's Ideogram-4 + Qwen3-VL set (~30–40 GB) may not fit — free space first (MAINTENANCE.md §8) or it will fail mid-download.
3. Use the **authed-direct HF download** trick for any model pull (MAINTENANCE.md §9) — `hf_hub_download` stalls ~80 MB on these containers.
4. `ComfyUI-LTXVideo` import-fails (kornia) — irrelevant; the pipeline uses comfy-core/kjnodes/GGUF/WhatDreamsCost LTX nodes.

---

## TIER 1 — Ingredients IC-LoRA smoke test (runnable NOW, no downloads)

**Goal:** confirm the IC-LoRA carries a reference sheet's subject identity into a generated LTX-2.3 clip (the consistency mechanism for the music-video skill).

**Models — all present, verified:**
| Role | File |
|---|---|
| LTX-2.3 22B base | `checkpoints/ltx-2.3-22b-dev-fp8.safetensors` |
| IC-LoRA (under test) | `loras/ltx-2.3-22b-ic-lora-ingredients-0.9.safetensors` @ **1.4** |
| Reference path sibling | `loras/ltx-2.3-22b-ic-lora-union-control-ref0.5.safetensors` (same IC-LoRA family — proves the ComfyUI conditioning wiring) |
| Video VAE / Audio VAE | `vae/LTX2_video_vae_bf16.safetensors` / `vae/LTX2_audio_vae_bf16.safetensors` |
| Text encoder | `text_encoders/gemma_3_12B_it_fp8_e4m3fn.safetensors` |
| Spatial upscaler | `latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.1.safetensors` |

**How it works** (from the official `ltx-community/ltx-2.3-ingredients-distilled` Space):
- Build a **reference sheet** = subject images (characters/props/locations) tiled into a grid on a ~**1536×896** canvas (16 px gutters) — or load a ready-made sheet.
- The sheet is fed as **reference-frame conditioning** (repeated across frames), not a start-frame I2V.
- **Prompt format:** `Reference sheet: {what's in the sheet}\n\nGenerated video: {action / motion / audio}`.
- **Gen:** 768×448 or 960×544, **121 frames @ 24 fps**, LoRA strength **1.4** (bf16).

**Build the graph** (start from a known-good example, don't hand-wire from scratch):
1. Check `custom_nodes/ID-LoRA-LTX2.3-ComfyUI/` for an example workflow / node — it is purpose-built for identity/reference LoRAs on LTX-2.3 and likely exposes the ingredient-conditioning input directly.
2. Failing that, copy the **union-control-ref0.5** reference-conditioning subgraph (same family) and swap in the ingredients LoRA @ 1.4 + your reference sheet.
3. Wire: base + `LoraLoaderModelOnly`(ingredients @1.4) → gemma text encode (prompt in the format above) → reference-sheet conditioning → LTXV sampler → `LTXVSeparateAVLatent` → video+audio VAE decode → `CreateVideo` → `SaveVideo`.

**Run:** load in the `comfyui-video` UI and queue, or POST an API-format graph to `http://127.0.0.1:8199/prompt` inside `comfy-docker-comfyui-video-1`.

**Pass criteria:** the subject(s) from the reference sheet stay **on-model** across the clip (face/wardrobe/prop consistency), audio track present. Compare against a run **without** the LoRA to see the consistency difference.

---

## TIER 2 — Full pasted storyboard→video workflow

The pasted graph: `JWString` JSON prompts → Ideogram-4 contact sheet → 3×3 crop separator → QwenVL image→prompt → LTXDirector segments → dual-pass AV LTX render.

**Step 1 — save the workflow** so it loads in the UI:
drop the workflow JSON into `/home/venetanji/dev/ComfyUI/user/default/workflows/storyboard-ltx-ingredients.json` (the bind-mounted workflows dir) → it appears in both instances' UI.

**Step 2 — download the missing models** (HF re-auth first; mind disk):
- **Ideogram-4 stage** (image instance) — repo `Comfy-Org/Ideogram-4`:
  - `diffusion_models/ideogram4_fp8_scaled.safetensors`
  - `diffusion_models/ideogram4_unconditional_fp8_scaled.safetensors` (workflow widget says `…nvfp4_mixed`; fp8 is the safe default)
  - the `qwen3vl_8b` CLIP/text-encoder it pairs with (same repo)
  - `vae/flux2-vae.safetensors` — **already present**
- **QwenVL node** (`AILab_QwenVL`): `Qwen3-VL-2B-Instruct` — the node auto-downloads on first run, or pre-place it.

**Step 3 — reconcile the LTX-2.3 model names.** The pasted graph's `models` subgraph references files **not installed under those exact names**. Either download the exact files or re-point the loaders to installed equivalents:

| Workflow wants | Installed equivalent (re-point to this) |
|---|---|
| `LTX-2.3-distilled-Q3_K_M.gguf` | `checkpoints/ltx-2.3-22b-dev-fp8.safetensors` (or a distilled gguf if you fetch one) |
| `LTX23_video_vae_bf16.safetensors` | `vae/LTX2_video_vae_bf16.safetensors` |
| `LTX23_audio_vae_bf16.safetensors` | `vae/LTX2_audio_vae_bf16.safetensors` |
| `gemma-3-12b-it-Q4_1.gguf` | `text_encoders/gemma_3_12B_it_fp8_e4m3fn.safetensors` (used by 21 workflows) |
| `ltx-2.3_text_projection_bf16.safetensors` | not installed — fetch from the LTX-2.3 repo if the loader requires it |
| `ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors` | `latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.1.safetensors` |
| LoRAs `Ltx2.3-Licon-VBVR-I2V-96000-R32`, `LTX-2.3-OmniNFT-RL-Lora_bf16` | not installed — fetch, or drop those LoRA loaders |
| `ltx2.3-transition.safetensors` | **present** |

**Step 4 — optionally add the Ingredients LoRA** to the LTXDirector model chain (the graph already stacks 3 `LoraLoaderModelOnly`s) as a 4th loader @ 1.4, plus a reference sheet, to add cross-shot subject consistency on top of the per-panel I2V.

**Pass criteria:** a 16:9 contact sheet renders from a JWString prompt; the 9 panels crop cleanly; QwenVL emits per-panel video prompts; LTXDirector produces a multi-segment AV video.

---

## Suggested order
Run **Tier 1 first** (self-contained, ~1 model load + a short render — proves the LoRA and the LTX-2.3 stack end-to-end), then tackle Tier 2 (downloads + name reconciliation) once disk + HF auth are sorted.
