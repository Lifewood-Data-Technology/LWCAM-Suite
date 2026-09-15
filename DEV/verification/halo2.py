import cv2, numpy as np, sys, os
cv2.setNumThreads(4)
def profiles(img, R=16, thr=120, need=1500):
    h,w=img.shape
    c=img[h//2-1400:h//2+1400, w//2-1400:w//2+1400]
    gx=cv2.Sobel(c,cv2.CV_32F,1,0,ksize=3)
    ys,xs=np.where(np.abs(gx)>thr)
    out=[]
    for i in np.random.RandomState(0).permutation(len(ys)):
        y,x=ys[i],xs[i]
        if x<R+2 or x>=c.shape[1]-R-2: continue
        p=c[y, x-R:x+R+1].astype(np.float32)
        if gx[y,x]<0: p=p[::-1]
        lo=p[:6].mean(); hi=p[-6:].mean()
        amp=hi-lo
        if amp<45: continue
        # ISOLATED STEP ONLY: both plateaus flat, monotone-ish core
        if p[:6].std()>0.06*amp or p[-6:].std()>0.06*amp: continue
        out.append((p-lo)/amp)
        if len(out)>=need: break
    return np.array(out)
for path in sys.argv[1:]:
    img=cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    P=profiles(img)
    m=P.mean(0); R=16
    print(f'{os.path.basename(path):48s} n={len(P)}')
    print('   ', ' '.join(f'{v:+.3f}' for v in m))
    print(f'    undershoot={m[:R-2].min():+.4f}  overshoot={m[R+3:].max():+.4f}')
