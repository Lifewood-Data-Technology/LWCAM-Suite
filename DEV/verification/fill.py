import cv2, numpy as np, glob, os, sys, importlib.util
spec=importlib.util.spec_from_file_location('io_', r'C:/Users/operator/Desktop/Taiping All Saints Church/DEV/All-In-One/apps/LWCAM/LWIP/backend/deskew_crop_tool/image_ops.py')
io_=importlib.util.module_from_spec(spec); spec.loader.exec_module(io_)
def fill(path):
    img=cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None: return None
    c=io_._largest_content_contour(img)
    if c is None: return None
    x,y,w,h=cv2.boundingRect(c.astype(np.float32))
    if w<=0 or h<=0: return None
    return float(cv2.contourArea(c.astype(np.float32))/(w*h))
label=sys.argv[1]
print(f'--- {label}: contour area / axis-aligned bbox area (1.000 = perfectly square to frame) ---')
for name,pat in zip(sys.argv[2::2], sys.argv[3::2]):
    vals=[v for v in (fill(f) for f in sorted(glob.glob(pat))[:8]) if v is not None]
    if vals: print(f'  {name:22s} n={len(vals)}  mean {np.mean(vals):.4f}   worst {min(vals):.4f}')
