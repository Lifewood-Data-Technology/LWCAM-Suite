"""Runs the patched LWIP worker over every Control source page and proves two
things now that LWIP never rotates a pixel itself:

1. The lossless path: for a page whose crop qualifies (jpg, orientation 1,
   jpegtran available), the delivered pixels inside the crop window must be
   IDENTICAL to the camera decode (max diff 0, excluding the outermost 1 px
   ring, which chroma upsampling renders differently once the neighbouring
   blocks are gone). This is now true regardless of measured tilt, since a
   tilted page is cropped exactly like a straight one.
2. The deferred deskew: for a page whose tilt was above threshold (non-empty
   `qc_ops`), replaying those ops with Pillow against the delivered .jpg must
   straighten it — checked here via `image_ops._page_angle` on the replayed
   result, the same measurement LWIP used to detect the tilt in the first
   place. Pass bar 0.5 deg: the estimator itself repeats to only ~0.3 deg on
   bound-register spreads.

Usage (from Control\\):
  "<runtime python>" lossless_replay.py "Source Images" [limit]
"""
import glob
import importlib.util
import os
import sys
import tempfile
import time

import cv2
import numpy as np
from PIL import Image

IMAGE_OPS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "LWCAM", "LWIP", "backend", "deskew_crop_tool", "image_ops.py",
)
spec = importlib.util.spec_from_file_location("image_ops", os.path.abspath(IMAGE_OPS))
image_ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image_ops)

sources = sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.jpg"), recursive=True))
limit = int(sys.argv[2]) if len(sys.argv) > 2 else len(sources)
tmp = tempfile.mkdtemp()
lossless = broken = encoded = deferred = residual_bad = 0
t_lossless = t_encoded = 0.0
size_src = size_out = 0
for i, src_path in enumerate(sources[:limit]):
    dst = os.path.join(tmp, f"{i}.jpg")
    started = time.perf_counter()
    r = image_ops.deskew_crop_file(src_path, dst, 200, 100, deskew_min_degrees=0.5)
    elapsed = time.perf_counter() - started
    out = cv2.imread(dst, cv2.IMREAD_COLOR)
    with Image.open(dst) as im:
        qmax = max(max(t) for t in im.quantization.values())
        exif = im.getexif()
        gps = 0x8825 in exif
        tags = len(exif)
        icc = bool(im.info.get("icc_profile"))
    size_src += os.path.getsize(src_path)
    size_out += os.path.getsize(dst)
    name = os.path.basename(src_path)[-24:]

    # (1) Lossless crop, independent of tilt now: every page is a candidate.
    ok = True
    if r["lossless"]:
        t_lossless += elapsed
        left, top, right, bottom = r["crop"]
        src = cv2.imread(src_path, cv2.IMREAD_COLOR)
        window = src[top:bottom, left:right]
        d = np.abs(window[1:-1, 1:-1].astype(int) - out[1:-1, 1:-1].astype(int)).max()
        ok = d == 0 and out.shape[:2] == (bottom - top, right - left)
        lossless += 1 if ok else 0
        broken += 0 if ok else 1
        lossless_note = f"interior_maxdiff={d}" + ("" if ok else " <<< NOT IDENTICAL")
    else:
        t_encoded += elapsed
        encoded += 1
        lossless_note = "reencoded"

    # (2) Deferred deskew: replay qc_ops with Pillow and re-measure the tilt.
    residual_note = "-"
    if r["qc_ops"]:
        deferred += 1
        with Image.open(dst) as opened:
            replayed = image_ops.apply_qc_ops(opened.copy(), r["qc_ops"])
        arr = cv2.cvtColor(np.array(replayed.convert("RGB")), cv2.COLOR_RGB2BGR)
        contour = image_ops._largest_content_contour(arr)
        residual = image_ops._page_angle(contour) if contour is not None else None
        # 0.5: the side-fit estimator repeats to about +-0.3 deg on bound-register
        # spreads (measured 2026-09-10, identical with the old cv2 rotation), so
        # a tighter bar flags estimator noise, not replay error.
        if residual is None or abs(residual) >= 0.5:
            residual_bad += 1
            residual_note = f"{residual!r} <<< RESIDUAL TOO LARGE"
        else:
            residual_note = f"{residual:+.3f}"

    print(
        f"{i+1:3d} {name} lossless={r['lossless']!s:5} angle={r['angle']:+.3f} "
        f"residual={residual_note} {lossless_note} {out.shape[1]}x{out.shape[0]} "
        f"qmax={qmax} exif={tags} gps={gps} icc={icc} {elapsed:.2f}s"
    )

n = lossless + broken + encoded
print(
    f"\nPAGES {n}: lossless-identical {lossless}, lossless-BROKEN {broken}, "
    f"re-encoded (not lossless) {encoded}, deferred-deskew (qc_ops) {deferred}, "
    f"residual-too-large {residual_bad}"
)
if lossless:
    print(f"mean time lossless {t_lossless/(lossless+broken):.2f}s")
if encoded:
    print(f"mean time encoded  {t_encoded/encoded:.2f}s")
print(f"mean size source {size_src/n/1e6:.2f} MB -> output {size_out/n/1e6:.2f} MB")
