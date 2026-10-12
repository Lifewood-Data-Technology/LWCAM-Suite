# 0002. LWIP crops JPEGs losslessly and never rotates

- **Status:** Accepted (2026-09-10; padding rules revised 2026-09-24)

## Context

Phone cameras write JPEGs with quantisation tables of all 1s: visually lossless. Re-encoding at q90 made the tables four times coarser and made the output a second compression generation. See [FAMILYSEARCH-FIX.md](../FAMILYSEARCH-FIX.md). ADR [0001](0001-geometry-is-data-until-export.md) explains why rotation moved out of LWIP.

## Decision

- LWIP crops a JPEG in its own coded blocks with `jpegtran`, so the page file in `2.Batches` holds the camera's bytes.
- Only a JPEG with a page found is rewritten. PNG, TIFF, BMP, JPEG XL and a JPEG with no page found keep the source bytes. Their crop is recorded as operations.
- `jpeg_quality` defaults to 100 with 4:4:4 chroma, for the files that are still encoded.
- For a tilted page, `crop_padding` is measured around the straightened page. LWIP maps that rectangle back into the camera frame and adds a small reach (8 px) for the export's Lanczos resample. It shortens only the side that would cross the photo edge.
- `mat_fill` (default true) records a `matfill` operation for the empty corners that remain. This is the one place pixels are synthesised, and only outside the photo.

## Consequences

- Crops are aligned to JPEG blocks. A tilted page's file is slightly larger on disk.
- Upgrade QC before you turn on `mat_fill` at a site. An older QC ignores `matfill` and shows black corners.
- Page detection uses OpenCV's Triangle threshold, not Otsu. Otsu filed a dark cover board with the backdrop.

## Don't change this unless

You are replacing `jpegtran`, lowering `jpeg_quality`, or making LWIP rotate. Any of these brings back the generation loss that caused the client rejection. Run the fidelity checks first.
