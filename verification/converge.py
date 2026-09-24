import cv2, numpy as np, glob, importlib.util, os, sys
spec=importlib.util.spec_from_file_location('io_', r'C:/Users/operator/Desktop/Taiping All Saints Church/DEV/All-In-One/apps/LWCAM/LWIP/backend/deskew_crop_tool/image_ops.py')
io_=importlib.util.module_from_spec(spec); spec.loader.exec_module(io_)
def residual(path):
    img=cv2.imread(path, cv2.IMREAD_COLOR)
    prepared=io_._detection_frame(img)
    c=io_._largest_content_contour(img, prepared)
    if c is None: return None
    return io_._page_angle(c)
pat,out,n = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(out, exist_ok=True)
before=[]; after=[]
for f in sorted(glob.glob(pat))[:n]:
    d=os.path.join(out, os.path.basename(f))
    r=io_.deskew_crop_file(f, d, 200, 100)
    res=residual(d)
    before.append(abs(r['angle'])); after.append(abs(res) if res is not None else float('nan'))
    print(f'{os.path.basename(f)[7:30]:26s} detected {r["angle"]:+7.3f}  residual after {res:+7.3f}' if res is not None else f'{os.path.basename(f)[7:30]:26s} detected {r["angle"]:+7.3f}  residual n/a')
a=np.array(after); b=np.array(before)
print(f'\nmean |detected| {np.nanmean(b):.3f} deg  ->  mean |residual| {np.nanmean(a):.3f} deg   worst residual {np.nanmax(a):.3f}')
