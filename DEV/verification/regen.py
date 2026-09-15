import cv2, numpy as np, glob, importlib.util, os, sys
spec=importlib.util.spec_from_file_location('io_', r'C:/Users/operator/Desktop/Taiping All Saints Church/DEV/All-In-One/apps/LWCAM/LWIP/backend/deskew_crop_tool/image_ops.py')
io_=importlib.util.module_from_spec(spec); spec.loader.exec_module(io_)
pat,out,n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def skew(path):
    g=cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    s=cv2.resize(g,None,fx=1600/max(g.shape),fy=1600/max(g.shape),interpolation=cv2.INTER_AREA)
    e=cv2.Canny(cv2.GaussianBlur(s,(5,5),0),40,120)
    L=cv2.HoughLinesP(e,1,np.pi/1440,threshold=150,minLineLength=min(s.shape)//3,maxLineGap=20)
    if L is None: return None
    a=[]
    for x1,y1,x2,y2 in L[:,0]:
        v=np.degrees(np.arctan2(float(y2-y1),float(x2-x1))); v=(v+90)%180-90
        if abs(v)<=12: a.append(v)
        elif abs(abs(v)-90)<=12: a.append(v-90 if v>0 else v+90)
    return float(np.median(a)) if len(a)>=3 else None
print(f'{"file":26s} {"src skew":>9s} {"applied":>8s} {"new out":>8s}')
rows=[]
for f in sorted(glob.glob(pat))[:n]:
    d=os.path.join(out, os.path.basename(f))
    r=io_.deskew_crop_file(f, d, 200, 100)
    s0, s1 = skew(f), skew(d)
    rows.append((abs(s1) if s1 is not None else None, abs(s0) if s0 is not None else None))
    fmt=lambda v: f'{v:+8.3f}' if v is not None else '     n/a'
    print(f'{os.path.basename(f)[7:30]:26s} {fmt(s0)} {r["angle"]:+8.3f} {fmt(s1)}')
ok=[(a,b) for a,b in rows if a is not None and b is not None]
print(f'\nmean |skew| before {np.mean([b for a,b in ok]):.3f} deg -> after {np.mean([a for a,b in ok]):.3f} deg   (n={len(ok)})')
