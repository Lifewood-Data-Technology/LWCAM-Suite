import cv2, numpy as np, glob, os, sys
cv2.setNumThreads(4)
src_dir, out_dir = sys.argv[1], sys.argv[2]
idx = int(sys.argv[3])
srcs = sorted(glob.glob(os.path.join(src_dir,'*.jpg')))
outs = sorted(glob.glob(os.path.join(out_dir,'*.tif')))
sp, op = srcs[idx], outs[idx]
S = cv2.imread(sp, cv2.IMREAD_COLOR)   # BGR
O = cv2.imread(op, cv2.IMREAD_COLOR)
DS=4
orb = cv2.ORB_create(6000); bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
sd = cv2.resize(cv2.cvtColor(S,cv2.COLOR_BGR2GRAY),None,fx=1/DS,fy=1/DS,interpolation=cv2.INTER_AREA)
od = cv2.resize(cv2.cvtColor(O,cv2.COLOR_BGR2GRAY),None,fx=1/DS,fy=1/DS,interpolation=cv2.INTER_AREA)
k1,d1 = orb.detectAndCompute(od,None); k2,d2 = orb.detectAndCompute(sd,None)
m = sorted(bf.match(d1,d2), key=lambda x:x.distance)[:1500]
p1 = np.float32([k1[x.queryIdx].pt for x in m]).reshape(-1,1,2)
p2 = np.float32([k2[x.trainIdx].pt for x in m]).reshape(-1,1,2)
M,_ = cv2.estimateAffinePartial2D(p1,p2,method=cv2.RANSAC,ransacReprojThreshold=2.0)
M = M.copy(); M[:,2] *= DS                       # output(full) -> source(full)
Minv = cv2.invertAffineTransform(M)              # source -> output frame
Sa = cv2.warpAffine(S, Minv, (O.shape[1], O.shape[0]), flags=cv2.INTER_CUBIC, borderValue=(0,0,0))
mgn = 250
Sc = Sa[mgn:-mgn, mgn:-mgn]; Oc = O[mgn:-mgn, mgn:-mgn]
print(f'pair {os.path.basename(sp)} -> {os.path.basename(op)}  region {Sc.shape}')
ok = (Sc.sum(2) > 0)
print('valid px %.1f%%' % (100*ok.mean()))
for ci,cn in enumerate('BGR'):
    a = Sc[...,ci][ok].astype(np.float32); b = Oc[...,ci][ok].astype(np.float32)
    print(f'  {cn}: src mean {a.mean():7.2f}  out mean {b.mean():7.2f}  delta {b.mean()-a.mean():+7.2f}')
gs = cv2.cvtColor(Sc, cv2.COLOR_BGR2GRAY).astype(np.float32)
go = cv2.cvtColor(Oc, cv2.COLOR_BGR2GRAY).astype(np.float32)
v = ok
print('\n tone map (source luma -> median output luma):')
for lo in range(0,256,16):
    sel = v & (gs>=lo) & (gs<lo+16)
    if sel.sum() < 500: continue
    print(f'   src {lo:3d}-{lo+15:3d}  n={sel.sum():9d}  out median {np.median(go[sel]):6.1f}  mean {go[sel].mean():6.1f}')
print('\n percentiles  src / out')
for q in (1,5,25,50,75,95,99,99.9):
    print(f'   p{q:<5} {np.percentile(gs[v],q):6.1f} / {np.percentile(go[v],q):6.1f}')
