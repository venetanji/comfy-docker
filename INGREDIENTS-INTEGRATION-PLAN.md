# Plan — Integrate LTX-2.3 "Ingredients" IC-LoRA into the comfyui + storyboard skills

_Written 2026-06-20 for a fresh session. Successor to `TEST-PLAN.md`. The ingredients
IC-LoRA recipe is now **validated end-to-end** on `comfy-docker-comfyui-video-1`; this
plan is about turning that one-off proof into first-class skill features._

## ✅ STATUS — ALL PHASES COMPLETE (2026-06-20)

Implemented, validated, and pushed to `main` of `github.com/venetanji/creative-skills`:

- **Phase 1** — comfyui `ingredients` command (`ltx2_ingredients_to_video` + node-only
  sheet-loop, gemma-fp8 TE fix). Commit `4ead749`.
- **Phase 2** — `comfyui/scripts/make_reference_sheet.py` PIL tiler (aspect-configurable,
  contain-fit on black). Commit `f13a58e`.
- **Phase 3** — `storyboard/scripts/generate_reference_sheet.py` flux2 panel composer.
  Commit `1845c9f`. Validated: flux2 panels → 768×448 sheet → ingredients render
  reproduced character/wardrobe/prop/location.
- **Phase 4** — `music-video` + `drama-video` project-level `reference_sheet:` + per
  scene/shot `mode: ingredients` (silent; first in dispatch). Commit `630de72`. Validated
  through the real `music_video.py scene 1` and `drama_video.py shot 1` entry points.
- **Phase 5** — ingredients regression entry in `test_all_workflows.py` + SKILL.md docs
  across all four skills. Commit `741bab9`.

Resolved open decisions: distilled 2-pass default kept (reproduced the example); 768×448
default bucket; **node-only sheet loop** (no ffmpeg/mp4 round-trip); per-project sheet.
The deferred ID-LoRA ("A") builders are preserved on branch `wip/idlora`, NOT on main
(runtime-blocked by transformers 5.x; needs comfy-env isolation + node-API verification).

## TL;DR of what was proven (read first)

- **Ingredients IC-LoRA = "Reference Sheet Control"** (repo `Lightricks/LTX-2.3-22b-IC-LoRA-Ingredients`, **gated** — HF token now persisted in `comfy-docker/.env` as `HF_TOKEN`, wired into both comfy services via `compose.yaml`).
- It conditions an LTX-2.3 clip on a **reference sheet** (one clean panel per character/prop/location, black bg, no text) so the generated video keeps those elements consistent.
- **Mechanism**: the sheet is supplied as a **static looped video** at the output resolution (downscale factor **1**), fed through the **video-reference path**: `LoadVideo → GetVideoComponents → ResizeImageMaskNode → LTXAddVideoICLoRAGuide` with `LTXICLoRALoaderModelOnly`. Output is a clean **single-width** clip (the repo's example mp4s are 2× wide only because they're side-by-side `sheet | generated` displays).
- The overlord's `ltx2._build` is already a faithful reimplementation (identical sigmas/samplers/IC-LoRA loader+guide+crop) — it just isn't exposed as a first-class "ingredients" entrypoint yet.

### Validated recipe (the numbers)
| Param | Value |
|---|---|
| base ckpt | `ltx-2.3-22b-dev-fp8.safetensors` |
| ingredients LoRA | `ltx-2.3-22b-ic-lora-ingredients-0.9.safetensors` @ **1.4** (via `LTXICLoRALoaderModelOnly`) |
| distilled LoRA | `ltx-2.3-22b-distilled-lora-384.safetensors` @ 0.5–0.6 (always, on dev-fp8) |
| text encoder | `gemma_3_12B_it_fp8_e4m3fn.safetensors` (override — the `fp4_mixed` default was deleted) |
| reference | static looped video of the sheet, **≥121 frames**, at **exact output WxH** |
| `ic_lora_reference_strength` | 1.0 (the `LTXAddVideoICLoRAGuide` strength) |
| resolution / frames / fps | **768×448 / 121 / 24** (trained bucket; 960×544 also works) |
| steps / guidance | README: 30 steps, cfg 4.0, STG `stg_v` blk29 scale1.0 — BUT `_build` uses the distilled 2-pass (8+4 step `cfg_pp`) and that reproduced the example fine |
| negative | `pc game, console game, video game, cartoon, childish, ugly, worst quality, inconsistent motion, blurry, jittery, distorted` |
| prompt format | training used `Reference sheet: <panels>\n\nGenerated video: <action>`; the official example instead fed ONE rich cinematic description (Gemini-expanded). Both work. |

**Proof artifacts** (on this box): `/workspace/ing_cmp/proper_montage.png` (sheet|official-gen|mine), `/workspace/ing_examples/ex2_prompt.json` + `ex2_workflow.json` (the official embedded workflow, extracted from `examples/ingredients_lora_2.mp4`'s XMP `pDM:logComment`), `/workspace/ing_cmp/ingredients_proper_00001_.mp4`.

---

## Where the code lives
- **comfyui skill** (canonical = overlord tree `~/dev/agentic-media/creative-skills/comfyui/`, = `origin/main` of `github.com/venetanji/creative-skills`; the installed snapshot at `~/.openclaw/workspace/skills/comfyui/` is STALE — pull first):
  - `scripts/ltx2.py` — `_build(...)` has the IC-LoRA params; public `ltx2_image_audio_to_video`/`flf2v`/`transition` expose `ic_loras`/`ic_lora_reference_*`, but **`ltx2_text_to_video`/`i2v` do NOT**.
  - `scripts/comfy_graph.py` — CLI; `ia2v`/`flf2v`/`transition` accept `--ic_loras "name:strength"` + `--ic_lora_reference` (image) / `--ic_lora_reference_video` (mp4) + `--ic_lora_reference_strength` + `--ic_lora_reference_size`. Auto-uploads local refs. Supports `--input-json`.
  - `scripts/core.py` — `WorkflowGraph`, submit/poll/save, `COMFY_URL[_VIDEO]`.
- **storyboard skill** (`~/dev/agentic-media/creative-skills/storyboard/`): `generate_anchor.py` (CLI). Turns a recurring character + scene description into a **scene-specific anchor** via flux2 i2i/i2iN. Music-video + drama-video delegate their anchor stage here. **Read its SKILL.md** — it already documents the "raw sheet as ia2v first frame is wrong" trap, which ingredients solves differently.

---

## Integration target 1 — comfyui skill: first-class `ingredients`

**Goal:** one command that takes a reference **sheet image** + a prompt and produces a consistent clip, hiding the static-video + video-ref wiring.

1. **New builder `ltx2_ingredients_to_video(sheet_image, prompt, ...)`** in `ltx2.py`:
   - Auto-build the static reference video from the sheet image: loop to `length` (≥121) at `fps`, scaled to exact `width×height`. (Do this server-side or with a small ffmpeg helper; `core.py` could gain a `still_to_video()` util, or a node-only path — see open decisions.)
   - Call `_build(..., ic_loras=[(INGREDIENTS_LORA, 1.4)], ic_lora_reference_filename=<that .mp4>, ic_lora_reference_strength=1.0, text_encoder=GEMMA_FP8)`.
   - Default neg + resolution/frames per the recipe table.
2. **New CLI command `ingredients`** in `comfy_graph.py`: `--sheet <img>`, `--prompt`, `--seconds`, `--strength 1.4`, `--width 768 --height 448`, `--fast`. Auto-upload the sheet, auto-make the static video. Wire `--input-json` like the rest.
3. **Reference-sheet assembler** (`scripts/make_reference_sheet.py` or fold into storyboard): tile element panels (character face + turnaround, each prop, one location) on a black bg, no text, at the output aspect. Per the README tips: **bigger panels carry over better**; one clean front-facing close-up + turnaround per character.
4. **Decide distilled-fast vs README-30-step** (see open decisions) and bake the chosen default.
5. Update `comfyui/SKILL.md` with the `ingredients` command + the recipe + "sheet authoring" guidance.

## Integration target 2 — storyboard skill: project-level consistency

**Goal:** keep recurring characters/props/locations consistent across all shots of a music-video / drama-video by conditioning on ONE project reference sheet.

1. **`generate_reference_sheet`** stage in storyboard: from the project's recurring character image(s) + named props/location, build the sheet — likely by composing flux2 outputs:
   - character turnaround via `flux2_multiple_angles` / `i2iNmulti` (front / 3-4 / side / back),
   - prop panels (product-style renders),
   - one location panel,
   - tile on black bg.
2. **New anchor/shot mode `ingredients`** alongside the existing flux2-i2i anchor: instead of (or in addition to) making a per-shot anchor, generate each shot via `ltx2_ingredients_to_video(project_sheet, shot_prompt)`. Compare against the current ia2v-anchor approach for identity stability across a full song.
3. **Wire into music-video / drama-video**: a `reference_sheet:` project field; per-scene prompts in `Reference sheet: …/Generated video: …` form (or rich cinematic). Combine with the overlord's existing multiguide/transition stitching for scene-to-scene continuity.
4. Document in storyboard + music-video SKILL.md.

---

## Open decisions (resolve early in the session)
- **Quality path:** distilled 2-pass (`_build` default, ~fast, reproduced the example) vs README's 30-step / cfg 4.0 / STG `stg_v` non-distilled (may need a new graph variant). A/B on one shot.
- **Sheet authoring:** manual composite vs automated flux2-panel generator. Automated is the real win for the pipeline.
- **Resolution:** 768×448 (trained bucket, lower VRAM) vs 960×544 (example). Both work; 768×448 default.
- **Static-video creation:** ffmpeg helper in the skill (needs ffmpeg in the run env) vs a ComfyUI node-only loop (`RepeatImageBatch` + the video-ref path can take an IMAGE batch — check whether `LTXAddVideoICLoRAGuide` accepts a looped image batch directly, avoiding an mp4 round-trip). The official workflow used `LoadVideo`; a node-only loop would be cleaner for the skill.
- **Per-shot vs per-project sheet:** one global sheet for the whole video vs per-scene sheets when the cast/location changes.

## Suggested phased tasks
1. **Phase 1 (comfyui):** add `ltx2_ingredients_to_video` + `ingredients` CLI + static-video helper; reproduce the validated run through the new command (regression: matches `/workspace/ing_cmp/ingredients_proper_*`).
2. **Phase 2 (sheet authoring):** `make_reference_sheet.py` + a flux2-driven turnaround/prop generator; produce a sheet from a single character ref.
3. **Phase 3 (storyboard):** `generate_reference_sheet` stage + `ingredients` shot mode; A/B vs the flux2-anchor approach on a 2–3 shot sequence for identity stability.
4. **Phase 4 (pipeline):** wire `reference_sheet:` into music-video/drama-video; combine with multiguide/transition; full short-sequence test.
5. **Phase 5:** SKILL.md docs + a regression entry in `test_all_workflows.py`.

## Pre-flight / gotchas
- **Pull creative-skills first** (`~/dev/agentic-media/creative-skills`, = origin/main). The `~/.openclaw/workspace/skills/comfyui` snapshot is stale.
- **Run target = `comfyui-video`** (RTX 3090). From claude-base drive it via `docker exec … http://127.0.0.1:8199`, or set `COMFY_URL_VIDEO=https://comfyui-video.tail9683c.ts.net`.
- **kornia patch** (`ComfyUI-LTXVideo/pyramid_blending.py` → `pad = F.pad`) is in the shared `comfy-docker_custom_nodes` volume; it survives restart/recreate but is **lost if the node is re-cloned/updated** — re-apply (see MAINTENANCE §8). It's what makes the IC-LoRA nodes exist at all.
- **gemma:** always override `text_encoder=gemma_3_12B_it_fp8_e4m3fn.safetensors` (fp4_mixed deleted).
- **Recreating comfy-video on the current v0.25.1 image** drops runtime-installed `soundfile`/`webcolors` (Tier-2 nodes `comfyui-various`/`Inspire-Pack`) until a rebuild bakes `plugin-requirements.txt`. Either rebuild, or keep the volume `comfyui-various/requirements.txt` (soundfile) workaround. IC-LoRA nodes are unaffected.
- **HF token** is in `.env` (gitignored) — back up `.env`; not recoverable from git.
