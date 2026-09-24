import cv2, numpy as np, sys, os
cv2.setNumThreads(4)
path=sys.argv[1]; band_y=int(sys.argv[2]); x0=int(sys.argv[3]); x1=int(sys.argv[4]); rows=int(sys.argv[5])
img=cv2.imread(path, cv2.IMREAD_GRAYSCALE).astype(np.float32)
band=img[band_y:band_y+rows, x0:x1]
W=x1-x0
cent=[]
for r in band:
    g=np.abs(np.gradient(r))
    if g.sum()<1e-6: cent.append(np.nan); continue
    cent.append(float((g*np.arange(W)).sum()/g.sum()))
cent=np.array(cent)
ok=~np.isnan(cent)
A=np.vstack([np.arange(rows)[ok], np.ones(ok.sum())]).T
slope,intercept=np.linalg.lstsq(A, cent[ok], rcond=None)[0]
print(f'{os.path.basename(path)}  edge slope {slope:.5f} px/row  ({np.degrees(np.arctan(slope)):+.2f} deg from vertical)')
BINS=8
acc={}
for i in range(rows):
    e=slope*i+intercept
    for j in range(W):
        d=j-e
        if abs(d)>14: continue
        k=int(round(d*BINS))
        acc.setdefault(k,[]).append(band[i,j])
ks=sorted(acc)
esf=np.array([np.mean(acc[k]) for k in ks]); pos=np.array(ks)/BINS
lo=esf[:BINS*4].mean(); hi=esf[-BINS*4:].mean()
if lo>hi: esf=esf[::-1]; pos=-pos[::-1]; lo,hi=hi,lo
n=(esf-lo)/(hi-lo)
print('  normalised ESF, -14..+14 px in 1px steps:')
for p in range(-14,15):
    idx=np.argmin(np.abs(pos-p))
    print(f'    {p:+3d}px  {n[idx]:+.4f}')
print(f'  dark plateau min  {n[pos<-3].min():+.4f}   bright plateau max {n[pos>3].max():+.4f}')
