import sys, glob, os, importlib.util, tempfile
import cv2, numpy as np
spec=importlib.util.spec_from_file_location("image_ops", os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'LWIP', 'backend', 'deskew_crop_tool', 'image_ops.py'))
io_=importlib.util.module_from_spec(spec); spec.loader.exec_module(io_)
src_dir,out_dir=sys.argv[1],sys.argv[2]
S_=sorted(glob.glob(os.path.join(src_dir,'*.jpg'))); O_=sorted(glob.glob(os.path.join(out_dir,'*.tif')))
tmp=tempfile.mkdtemp()
exact=near=bad=0
for i in range(min(int(sys.argv[3]), len(O_))):
    dst=os.path.join(tmp, f'{i}.jpg')
    r=io_.deskew_crop_file(S_[i], dst, 200, 90)
    mine=cv2.imread(dst, cv2.IMREAD_COLOR); theirs=cv2.imread(O_[i], cv2.IMREAD_COLOR)
    if mine.shape!=theirs.shape:
        print(f'{i+1:3d} angle={r["angle"]:+.4f} SHAPE MISMATCH mine{mine.shape[1::-1]} theirs{theirs.shape[1::-1]}'); bad+=1; continue
    d=cv2.absdiff(mine,theirs)
    ident=100*(d.max(2)==0).mean()
    tag='EXACT' if d.max()==0 else ('near' if d.mean()<0.5 else 'DIFF')
    if d.max()==0: exact+=1
    elif d.mean()<0.5: near+=1
    else: bad+=1
    print(f'{i+1:3d} angle={r["angle"]:+.4f} {mine.shape[1]}x{mine.shape[0]}  {tag}  meandiff={d.mean():.4f} max={d.max()} identical_px={ident:.2f}%')
print(f'\nEXACT {exact}  near {near}  diff {bad}')
