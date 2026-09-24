# LWCAM — FamilySearch image-fidelity fix — handoff for station testing

Written 2026-09-09. This file exists so the work can continue on the test PC without
re-deriving anything.

On the `qc-platform` branch it was the repository-root `AGENTS.md` until
2026-09-23, when the apps moved up out of `DEV\All-In-One\apps\` to the root and
the workspace guide took that name. Paths below are updated to the new layout;
`DEV\{app}` is the snapshot extracted from a compiled installer on the build PC
and was never part of this tree. Every other branch still has this file as its
root `AGENTS.md`.

The repo's own developer guides are separate and still authoritative for architecture:
the repository-root `AGENTS.md` (workspace), `LWCAM\AGENTS.md`,
`LWCamAdmin\AGENTS.md`.

---

## 1. Why any of this happened

FamilySearch rejected every folder uploaded for the Taiping All Saints Church project:

> Evidence of image enhancement was identified in all folders uploaded. Per FamilySearch
> standards, images should not contain any image manipulation. Please review your camera
> settings to ensure that any compression, sharpening, or other image enhancement
> features are turned off and recapture/reupload the affected images.

**The camera was not the cause. Our pipeline was.** Established against 99 source/output
pairs in `Control\` (batches `M95K-…000004` and `…000005`):

- Replaying the shipped LWIP over the retained camera originals reproduced **all 99
  delivered images** — 70 bit-exact, 29 within 13 DN (`warpAffine` build nondeterminism),
  0 mismatches. Nothing else in the pipeline had touched them.
- Cropping a source at LWIP's own offset and re-encoding at **JPEG q90 4:4:4** reproduced
  a delivered TIFF **bit-for-bit, max diff 0**. That was the "compression".
- Camera settings were already correct: Xiaomi 14 Ultra, native 6144×8192, `Hdr: off`,
  `AIScene: 0`, no filter, ISO 160, and quantization tables of **all 1s** — visually
  lossless. LWIP threw that away on every page.
- No tonal manipulation had occurred: the delivered tone map is identity to within
  0.05 DN per channel. QC's Luminance Correction was never used on these batches.

---

## 2. What was changed

Twelve source files across three codebases. Full detail in `LWCAM\CHANGELOG.txt`
and `LWCamAdmin\CHANGELOG.txt` (2026-09-09 entries).

### LWIP — `LWCAM\LWIP\backend\deskew_crop_tool\`
| file | change |
|---|---|
| `image_ops.py` | q90 → **q100 4:4:4**; write via Pillow so **EXIF + ICC survive**; **GPS stripped**; illegal `Orientation=0` → 1; deskew `INTER_LINEAR` → **`INTER_LANCZOS4`**; `BORDER_REPLICATE` → `BORDER_CONSTANT` black; new `deskew_min_degrees`; skew now measured by **fitting the outline's straight sides** instead of `cv2.minAreaRect` (**superseded 2026-09-10, see §11**: LWIP no longer rotates or resamples at all — the Lanczos warp described here moved to the QC engine's `export.py`, which applies it once at TIFF export; current `image_ops.py` only measures skew and crops losslessly in coded JPEG blocks) |
| `config.py` | `jpeg_quality` default 100; new `deskew_min_degrees` (0.5 since 2026-09-10, was 0.2; validated 0–10) |
| `orchestrator.py` | passes `deskew_min_degrees` through to the worker |
| `tests/test_deskew_crop_tool.py` | +4 regression tests (`OutputFidelityTests`) |
| `config/deskew_crop_config.json`, `README.txt` | shipped defaults + docs |

### QC engine — `DEV\{app}\QC\backend\app\` (also copied to `LWCam_QC_Platform\`)
| file | change |
|---|---|
| `routers/qc.py` | `apply_pending_ops` q95 → **q100, `subsampling=0`**, carries EXIF/ICC/DPI; new `assert_luminance_enabled()` → 503; deleted dead `apply_rotate` |
| `services/export.py` | exported TIFF now carries capture provenance (`TIFF_PROVENANCE_TAGS`) |
| `core/config.py`, `core/node_config.py` | `luminance_enabled` setting, default True (**flipped to default False on 2026-09-10, see §11** — "Luminance OFF by default everywhere") |
| `tests/test_output_fidelity.py` | **new**, 10 tests |

### Flutter
| file | change |
|---|---|
| `LWCamAdmin\lib\services\lwip_config_writer.dart` | writes `jpeg_quality: 100` + `deskew_min_degrees: 0.5` |
| `LWCamAdmin\lib\models\node_config.dart`, `LWCAM\lib\models\node_config.dart` | new `luminanceEnabled` bool, default true (**flipped to default false on 2026-09-10, see §11**) — **both copies must stay in step** |
| `LWCamAdmin\lib\pages\station_setup_page.dart`, `controllers\station_setup_controller.dart` | "Allow luminance correction in QC" switch |
| `LWCAM\lib\widgets\qc_image_toolbar.dart` | hides the Luminance button when disabled |
| `LWCamAdmin\test\services\lwip_config_writer_test.dart` | golden config updated |

---

## 3. Measurements (so nobody re-measures)

JPEG quality, on a real cropped page:

| setting | quant tables | size | max err | px identical |
|---|---|---|---|---|
| camera original | max 1 / 1 | — | — | — |
| q90 *(old)* | max 24 / 20 | 2.66 MB | 21 DN | 43.5% |
| **q100 4:4:4** | **max 1 / 1** | 10.68 MB | **3 DN** | **87.7%** |

Detail retained after a 2° rotation:

| method | mid-freq | high-freq | lapvar |
|---|---|---|---|
| `INTER_LINEAR` + q90 *(old)* | 0.812 | 0.483 | 0.643 |
| **`INTER_LANCZOS4`** | **0.990** | **0.944** | **0.919** |

Lanczos ringing on a worst-case 1px step edge: **+0.12%** — far below the camera ISP's
own ~3% overshoot, so it cannot be mistaken for sharpening.

Skew: `B4 median 0.735° p90 2.42° max 3.33°` / `B5 median 0.000° p90 0.24° max 1.21°`.

Full patched re-run of batch 4 (24 pages): deskew fired 21/24, high-freq retention
0.664 → 1.224 (same measure), quant table max 1 on every page, 17 EXIF tags on every
page, zero GPS, mean output 11.82 MB (~4× the old size).

Actual capture resolution is **~423 DPI** on A4 (page measures 3520×4924 px). The EXIF
DPI tag still says 72, which is the camera's own claim — deliberately not overwritten
with a fabricated number.

---

## 4. Things I got wrong during the session — do not re-litigate

Recorded because each was stated confidently before being disproved:

1. **"The old deskew was introducing 2° of skew into straight pages."** False. It
   straightened the *paper* correctly (shipped output's paper edge measures +0.32°). My
   Hough measurement had locked onto the printed form's rules, which on that sheet sit
   ~2° askew relative to the paper itself.
2. **"Batch 5 was shipping visibly crooked."** False. Contour-to-bounding-box fill was
   0.9702 before and 0.9703 after — already at the rounded-corner ceiling. The degenerate
   `minAreaRect` is a real latent defect (it *cannot* report tilt on a rounded outline),
   but its practical impact on that batch was small. The fix is insurance.
3. **"Switching LWIP's output to `.tif` is safe on the Dart side."** False, and the most
   dangerous of these. `capture_images.image_name` is written from the *capture* filename
   (`upload_stats_db.dart:2863`) and never rewritten; QC resolves every file as
   `folder_path / image_name` (`qc.py:280`). A renamed output 404s every page. **Output
   stays `.jpg`.**
4. **"70 of 99 pages can be byte-copied."** False. The crop always happens
   (6144×8192 → ~3929×5327 even at zero rotation), so every page is re-encoded.
5. **A Hough-over-the-whole-frame skew estimator was tried and discarded** — it locked
   onto the marbled cover texture and did not converge (residual as large as the original
   tilt, sometimes sign-flipped). The shipped estimator fits the contour's own sides.

---

## 5. Build environment — what it took to compile

All resolved on the build PC; expect the same on any fresh one.

| requirement | how |
|---|---|
| Flutter **3.47.0** stable (Dart 3.13.0) | installed at `C:\dev\flutter`, on PATH |
| Windows **Developer Mode** | `start ms-settings:developers` — Flutter refuses plugin builds without it |
| **C++ ATL** for VS Build Tools | `vs_installer.exe modify --installPath "..." --add Microsoft.VisualStudio.Component.VC.ATL --quiet` — needed by `flutter_local_notifications_windows`; `flutter doctor`'s ✓ does **not** check it |
| **Inno Setup 6** | `winget install --id JRSoftware.InnoSetup -e` |

Two repo-copy defects hit along the way, both fixed in the repository:

- `windows\flutter\CMakeLists.txt` was missing from both apps (my copy exclusion).
  Replaced with the stock Flutter 3.47.0 template — verified project-agnostic. **Use the
  repo's own copy for a production build.**
- `runner.exe.manifest` had arrived renamed to `runner.exe.manifest.xml` in both apps —
  a transfer-time mangling, content byte-identical to stock. Correctly-named copies
  created; the `.xml` files are still there.

Build commands:
```
cd LWCAM      && flutter build windows --release
cd LWCamAdmin && flutter build windows --release
cd installer  && powershell -File build-installer.ps1
```

---

## 6. Deliverables

```
LWSuite.exe                        150.7 MB
postgresql-18.6-1-windows-x64.exe  358.4 MB
```

**Both must sit in the same folder** on the target station or Setup aborts before writing
anything. Since 2026-09-10 the installer accepts any `postgresql-18.*-windows-x64.exe`
beside it (highest name wins), so EDB's 18.6-3 works without renaming. Verified by extracting from inside the compiled installer: `INTER_LANCZOS4`
present and `INTER_LINEAR` gone; `BORDER_CONSTANT`, EXIF passthrough and the side-fit
estimator present; QC `subsampling` and the luminance guard present with the old q95 gone;
`TIFF_PROVENANCE_TAGS` present. Both Dart snapshots contain `luminanceEnabled`, checked
against `exportZipOutput` as a control string.

---

## 7. What to test on the station

1. **Install**, run **LWCam Admin → Station Setup**, save. Then open

   ```
   C:\Users\<capture operator>\LWCAM_DBs\lwip\deskew_crop_config.json
   ```

   and confirm:
   ```json
   "crop_padding": 200,
   "jpeg_quality": 100,
   "deskew_min_degrees": 0.5,
   ```
   If `jpeg_quality` still reads `90`, the rebuilt Admin did not take. This is the single
   clearest signal the new build is live.

   Note the *other* file of the same name —
   `C:\Program Files\LW Suite\LWCAM\LWIP\config\deskew_crop_config.json` — is the
   standalone config for `START_DESKEW_CROP.bat` only. Station Setup never touches it.

2. **Capture → LWIP → QC → export.** Open the final `.tif` and confirm it carries
   Make / Model / DateTime and **no GPS**.

3. **Luminance toggle.** Station Setup → turn "Allow luminance correction in QC" off →
   restart the QC engine → the toolbar button disappears in LWCAM, and the endpoint
   answers 503 if called directly.

4. Watch disk in `2.Batches` — pages are now ~4× larger (≈11.8 MB vs ≈2.7 MB).

Reminder from the workspace guide: **Station Setup's save stops and restarts the QC
engine.** Overwriting a running engine's `.py` by hand leaves it serving the code it
imported at startup, with no error anywhere.

---

## 8. Test baselines

| suite | expected |
|---|---|
| LWIP `python -m unittest discover -s tests` | **34 tests, 1 failure** — the pre-existing `DJCHOY~1` 8.3 short-path artifact in `test_config_resolves_relative_paths_from_project_root` |
| LWCAM `dart analyze` / `flutter test` | 6 issues / **595 pass** |
| LWCamAdmin `dart analyze` / `flutter test` | clean / **132 pass + 4 skipped** |
| QC engine `python -m unittest discover -s tests -t .` | **10 pass** (new `test_output_fidelity.py`) |
| QC platform's own pytest (385 pass / 8 fail) | **NOT RUN** — see gaps |

The QC tests need a venv the shipped wheels can fill:
```
py -3.13 -m venv <venv>
<venv>\Scripts\python -m pip install --no-index --find-links DEV\{app}\QC\backend\wheels -r DEV\{app}\QC\backend\requirements.txt
```

---

## 9. Verification scripts

Preserved at `verification\`. Run from the `Control\` directory (they expect
`Source Images\...` and `Output\...` beside them).

| script | what it answers |
|---|---|
| `replay.py <srcdir> <outdir> <n>` | does LWIP reproduce the delivered files bit-for-bit |
| `final.py` | full-batch: deskew count, HF retention, quant tables, EXIF, GPS, sizes |
| `converge.py <glob> <outdir> <n>` | does deskew converge (residual after processing) |
| `fill.py` | squareness — contour area ÷ bounding-box area |
| `interp.py` | interpolator comparison (LINEAR / CUBIC / LANCZOS4) |
| `tone.py` | tone-map identity check between source and output |
| `sweep.py` | per-pair geometry + sharpness across a whole batch |
| `esf.py`, `halo2.py` | slanted-edge / halo analysis for sharpening claims |

Caution learned the hard way: `truth.py`, `geom.py` and Hough-based measures lock onto
*printed content*, not paper edges, and disagree with edge-based measures by ~2° on at
least one sheet. Prefer `fill.py` and `converge.py` for skew questions.

---

## 10. Known gaps and caveats

- **The QC engine in this build is the shipped build's source plus three patches**, taken
  from the extracted `LWSuite.exe` — not `LWCam_QC_Platform` at current HEAD, which was
  never provided. Fine for testing; **rebase the three changes onto the real repo before
  production.**
- **The QC platform's own 385-test suite has not been run.** The 10 new targeted tests
  cover the three changed functions only.
- **The two rejected batches have not been reprocessed or redelivered.** The route is
  built and understood: the revert endpoint (`qc.py`'s `revert_task` — not
  `revert_to_client_rework` as this was first named here; currently line 2177/2178,
  not 1685) clears `is_exported` and keeps the Group ID, and export republishes with
  `replace=True` (`export.py`, currently around line 1024-1096, not 1715 — `qc.py`
  and `export.py` have both grown a lot since this was written, so treat every line
  number in this file as approximate and grep for the name instead) —
  FamilySearch want the correction under the same Group ID. Sequence: confirm the camera
  originals are still in `1.Images` → re-run fixed LWIP → reopen each folder as client
  rework → push each reprocessed page through QC's **replace image** endpoint (byte-exact,
  `qc_drafts.py:586`) → approve → export → re-upload.
- **`save_draft` silently loses pending edits** — recorded here as pre-existing and
  deliberately left alone. **Does not reproduce as of this writing** (checked in
  both `LWCam_QC_Platform` and the extracted `DEV\{app}\QC`): current
  `save_draft` (`qc.py:2938` in both trees) uses the identical stage/
  `db.commit()`/`finalize_files()` sequence as `approve_task` via
  `commit_current_draft`. Likely fixed incidentally by the 2026-09-10 geometry
  rework (§11) rather than deliberately — re-verify before relying on either
  claim; don't assume this bug is gone on a tree neither of these was checked
  against.
- **Camera noise reduction is not addressed and cannot be.** Flat-paper grain measures
  0.63 DN, ~2.4× below the photon shot-noise floor for that exposure, with ~3% edge
  overshoot. HDR, AI scene and filters are already off — this is the ISP path and no
  setting defeats it. If FamilySearch rejects again *after* this build, that is the next
  suspect, and it needs DNG capture plus a pipeline that ingests it. Do not promise this
  cheaply.
- **The TIFF on/off toggle does not exist in this branch** (searched NodeConfig, Station
  Setup, App Settings, the project model, `export.py`). `is_tif_converted`
  (`models/capture.py:79`) is a result flag set at `export.py:1165`, not a switch. Taiping
  needs `.tif` regardless.

---

## 11. 2026-09-10 additions (after the section above was written)

Full detail in both `CHANGELOG.txt` files and the root `AGENTS.md` ("Geometry is DATA
until export"). The short version:

**Nothing between the camera and the TIFF re-encodes a page any more.**

- LWIP crops the camera JPEG in its own coded blocks (`LWIP\tools\jpegtran.exe`,
  libjpeg-turbo) and never rotates. On the 99 Control pages: 99 of 99 outputs are
  pixel-identical to the camera decode inside the crop window (max diff 0, 1 px
  edge ring excluded), quant tables all 1, 17 EXIF tags, no GPS, ICC carried.
- The measured tilt is recorded as ops in the manifest (`files[].qc_ops`); the
  QC engine layers LWIP baseline + committed QC ops (`qc_ops.json`) + draft, and
  applies them ONCE at export while writing the lossless TIFF (Lanczos via
  OpenCV). 70 of 99 Control pages export a TIFF pixel-identical to the camera
  crop; 29 carry a deferred deskew.
- Skew estimate is iterated on the detection frame and gated: a page whose
  estimate will not settle is left as captured. Residual after replay: median
  0.14 deg, p90 0.37, 2 of 99 pages between 0.5 and 0.8 deg (bound-register
  spreads; the estimator over-reads there). Before: 9-12 of 99.
- `deskew_min_degrees` default 0.5. Luminance OFF by default everywhere.
- Archive Start/End Date are free text, verbatim to the CSV (migration 003).

**Verification scripts** (`verification\`, run from `Control\`):

| script | interpreter | what it proves |
|---|---|---|
| `lossless_replay.py "Source Images"` | LWIP runtime python | crop identity + residual after Pillow replay |
| `export_fidelity.py "Source Images"` | QC engine venv python (needs cv2, sqlalchemy) | real `convert_to_tiff`: no-op TIFF == camera crop, deferred residual, tags |

**Station checks added to section 7:** the LWIP `state.json`/manifest shows
`lossless: true` on every page and `qc_ops` on tilted ones; approve a page with a
rotate in QC and confirm the page .jpg's SHA-256 did not change and `qc_ops.json`
appeared beside the manifest; the exported TIFF is straight.

**Known:** the QC preview and the exported TIFF use different resamplers (Pillow
bicubic at 1600 px vs OpenCV Lanczos at full size) - same geometry, so the
preview is honest about framing, not about pixels.
