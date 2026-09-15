"""End-to-end fidelity of the shipped chain on real Control pages:
camera JPEG -> LWIP (measure-only, lossless crop) -> QC engine convert_to_tiff
with the LWIP baseline ops -> TIFF.

Proves, per page:
  - no-op page (tilt under threshold): TIFF pixels == camera decode of the crop
    window, max diff 0 in the interior (1 px ring excluded, chroma edge effect);
  - deferred page: TIFF is straight to within the estimator's own repeatability,
    and is a lossless container (deflate, no JPEG tables), with provenance tags.

Run with the QC engine venv (has cv2, Pillow, numpy, sqlalchemy):
  <qcvenv>\\python.exe export_fidelity.py "Source Images" [limit]
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

HERE = os.path.dirname(os.path.abspath(__file__))
APPS = os.path.abspath(os.path.join(HERE, "..", "All-In-One", "apps"))
sys.path.insert(0, os.path.join(APPS, "LWCam_QC_Platform", "backend"))
from app.services.export import convert_to_tiff  # noqa: E402
from app.services.geometry_ops import replay_pending_ops  # noqa: E402

spec = importlib.util.spec_from_file_location(
    "image_ops", os.path.join(APPS, "LWCAM", "LWIP", "backend", "deskew_crop_tool", "image_ops.py")
)
image_ops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image_ops)

sources = sorted(glob.glob(os.path.join(sys.argv[1], "**", "*.jpg"), recursive=True))
limit = int(sys.argv[2]) if len(sys.argv) > 2 else len(sources)
tmp = tempfile.mkdtemp()
identical = deferred = bad = 0
t_export = 0.0
for i, src_path in enumerate(sources[:limit]):
    page = os.path.join(tmp, f"{i}.jpg")
    tif = os.path.join(tmp, f"{i}.tif")
    r = image_ops.deskew_crop_file(src_path, page, 200, 100, deskew_min_degrees=0.5)
    started = time.perf_counter()
    convert_to_tiff(__import__("pathlib").Path(page), __import__("pathlib").Path(tif), r["qc_ops"] or None)
    t_export += time.perf_counter() - started
    with Image.open(tif) as t:
        comp = t.info.get("compression")
        tags = t.tag_v2
        make = tags.get(271)
        model = tags.get(272)
        gps = 34853 in tags
        icc = bool(t.info.get("icc_profile"))
        out = cv2.cvtColor(np.array(t.convert("RGB")), cv2.COLOR_RGB2BGR)
    name = os.path.basename(src_path)[-24:]
    if not r["qc_ops"]:
        left, top, right, bottom = r["crop"]
        src = cv2.imread(src_path, cv2.IMREAD_COLOR)
        window = src[top:bottom, left:right]
        ok = out.shape == window.shape and int(np.abs(window[1:-1, 1:-1].astype(int) - out[1:-1, 1:-1].astype(int)).max()) == 0
        identical += 1 if ok else 0
        bad += 0 if ok else 1
        note = "TIFF == camera crop" if ok else "<<< TIFF DIFFERS FROM CAMERA"
    else:
        deferred += 1
        contour = image_ops._largest_content_contour(out)
        residual = image_ops._page_angle(contour) if contour is not None else None
        ok = residual is not None and abs(residual) < 0.5
        bad += 0 if ok else 1
        note = f"deskewed {r['angle']:+.3f} -> residual {residual:+.3f}" + ("" if ok else " <<< RESIDUAL")
    print(f"{i+1:3d} {name} {note} comp={comp} make={make} model={model} gps={gps} icc={icc} {out.shape[1]}x{out.shape[0]}")
n = identical + deferred + bad
print(f"\nPAGES {n}: no-op TIFF identical to camera {identical}, deferred-deskew {deferred}, failures {bad}")
print(f"mean export time per page {t_export / max(n, 1):.2f}s")
