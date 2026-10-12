# 0001. Geometry is data until export

- **Status:** Accepted (2026-09-10)

## Context

FamilySearch rejected a delivered batch for "image enhancement". The cause was our pipeline, not the camera. LWIP rotated and re-encoded every page as a q90 JPEG, and an early QC design flushed edits into a q100 JPEG at approval. Each step added a compression generation. See [FAMILYSEARCH-FIX.md](../FAMILYSEARCH-FIX.md).

## Decision

Nothing between the camera and the delivered TIFF re-encodes a page.

- LWIP only measures tilt. It records the result as an operation list (`deskew`, `crop`, and later `matfill`) in the manifest, in `files[].qc_ops`.
- QC keeps three lists: the LWIP baseline, the committed reviewer operations (`qc_ops.json`), and the reviewer's draft. Approval writes data, not pixels.
- Export replays the whole chain once, in the order it was recorded (`replay_pending_ops`), and writes the lossless TIFF.
- Luminance correction is the only tool that may change pixels in review. It is off by default.

## Consequences

- Preview, thumbnails and export all use one list, so the geometry is identical. The preview replays on a 1600 px frame and export on the full frame, so the preview is honest about framing, not about sharpness.
- Crop rectangles are normalised, so one list drives both sizes.
- The replay code (`geometry_replay.py`) exists in LWIP and in QC. The two copies must stay byte-identical. A test checks this.
- A page with no operations is pixel-identical to the camera decode.

## Don't change this unless

You can show the client accepts a re-encode, and you have measured the result against the control images (see `verification/`). Order is part of the contract: crop then rotate is not rotate then crop. Never sort the list by kind.
