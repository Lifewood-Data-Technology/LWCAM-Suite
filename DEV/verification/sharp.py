import cv2, numpy as np, glob, os, sys
cv2.setNumThreads(4)
src_dir,out_dir,idx = sys.argv[1],sys.argv[2],int(sys.argv[3])
srcs=sorted(glob.glob(os.path.join(src_dir,'*.jpg'))); outs=sorted(glob.glob(os.path.join(out_dir,'*.tif')))
S=cv2.imread(srcs[idx],cv2.IMREAD_GRAYSCALE); O=cv2.imread(outs[idx],cv2.IMREAD_GRAYSCALE)
DS=4; orb=cv2.ORB_create(6000); bf=cv2.BFMatcher(cv2.NORM_HAMMING,crossCheck=True)
sd=cv2.resize(S,None,fx=1/DS,fy=1/DS,interpolation=cv2.INTER_AREA); od=cv2.resize(O,None,fx=1/DS,fy=1/DS,interpolation=cv2.INTER_AREA)
k1,d1=orb.detectAndCompute(od,None); k2,d2=orb.detectAndCompute(sd,None)
m=sorted(bf.match(d1,d2),key=lambda x:x.distance)[:1500]
p1=np.float32([k1[x.queryIdx].pt for x in m]).reshape(-1,1,2); p2=np.float32([k2[x.trainIdx].pt for x in m]).reshape(-1,1,2)
M,_=cv2.estimateAffinePartial2D(p1,p2,method=cv2.RANSAC,ransacReprojThreshold=2.0); M=M.copy(); M[:,2]*=DS
rot=np.degrees(np.arctan2(M[1,0],M[0,0]))
N=1024
oc=np.array([O.shape[1]/2, O.shape[0]/2])
sc=(M[:, :2]@oc + M[:,2])
ox,oy=int(oc[0]-N/2), int(oc[1]-N/2); sx,sy=int(round(sc[0]-N/2)), int(round(sc[1]-N/2))
po=O[oy:oy+N, ox:ox+N].astype(np.float32); ps=S[sy:sy+N, sx:sx+N].astype(np.float32)
# refine integer shift by phase correlation
sh,_=cv2.phaseCorrelate(ps, po)
print(f'rot={rot:+.3f}deg  residual shift={sh[0]:+.2f},{sh[1]:+.2f}px')
sx2,sy2=sx+int(round(sh[0])), sy+int(round(sh[1]))
ps=S[sy2:sy2+N, sx2:sx2+N].astype(np.float32)
print(f'patch mean src={ps.mean():.2f} out={po.mean():.2f}  std src={ps.std():.2f} out={po.std():.2f}')
def radial_ps(a):
    a=a-a.mean(); w=np.outer(np.hanning(a.shape[0]),np.hanning(a.shape[1]))
    F=np.abs(np.fft.fftshift(np.fft.fft2(a*w)))**2
    cy,cx=np.array(F.shape)//2
    y,x=np.indices(F.shape); r=np.hypot(y-cy,x-cx).astype(int)
    return np.bincount(r.ravel(),F.ravel())/np.bincount(r.ravel())
Ps,Po=radial_ps(ps),radial_ps(po); n=min(len(Ps),len(Po))//1
nyq=N//2
print('\n freq(cyc/px)   src power     out power     ratio out/src')
for frac in (0.05,0.1,0.15,0.2,0.25,0.3,0.35,0.4,0.45,0.5):
    k=int(frac*nyq*2)
    if k>=n: continue
    print(f'   {frac/2:.3f}      {Ps[k]:12.1f} {Po[k]:12.1f}   {Po[k]/max(Ps[k],1e-9):8.3f}')
def blockiness(a):
    v=np.abs(np.diff(a,axis=1)); h=np.abs(np.diff(a,axis=0))
    bv=v[:,7::8].mean(); nv=np.delete(v,np.s_[7::8],axis=1).mean()
    bh=h[7::8,:].mean(); nh=np.delete(h,np.s_[7::8],axis=0).mean()
    return (bv+bh)/2, (nv+nh)/2
bs,ns=blockiness(ps); bo,no=blockiness(po)
print(f'\n blockiness  src: boundary {bs:.3f} interior {ns:.3f} ratio {bs/ns:.4f}')
print(f' blockiness  out: boundary {bo:.3f} interior {no:.3f} ratio {bo/no:.4f}')
lap_s=cv2.Laplacian(ps,cv2.CV_32F).var(); lap_o=cv2.Laplacian(po,cv2.CV_32F).var()
print(f'\n laplacian var  src={lap_s:.1f}  out={lap_o:.1f}  ratio={lap_o/lap_s:.4f}')
