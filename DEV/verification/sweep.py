import cv2, numpy as np, glob, os, sys, csv
cv2.setNumThreads(4)
pairs=[("Source Images/All Saints' Church Taiping Deceased 2014-2017","Output/M95K-ZMLMY01MYTP01260804000004/artifacts","B4"),
       ("Source Images/Parish of North Perak All Saints Church Taiping Resurrection Kuala Kangsar St Andrews Parit Buntar Confirmation Register Year 1952-1987","Output/M95K-ZMLMY01MYTP01260804000005/artifacts","B5")]
orb=cv2.ORB_create(6000); bf=cv2.BFMatcher(cv2.NORM_HAMMING,crossCheck=True); DS=4
def radial_hf(a):
    a=a.astype(np.float32); a=a-a.mean()
    w=np.outer(np.hanning(a.shape[0]),np.hanning(a.shape[1]))
    F=np.abs(np.fft.fftshift(np.fft.fft2(a*w)))**2
    cy,cx=np.array(F.shape)//2; y,x=np.indices(F.shape); r=np.hypot(y-cy,x-cx).astype(int)
    P=np.bincount(r.ravel(),F.ravel())/np.bincount(r.ravel())
    n=a.shape[0]//2
    return P[int(0.35*n):int(0.55*n)].mean()
w=csv.writer(open(sys.argv[1],'w',newline=''))
w.writerow(['batch','idx','src','out','sw','sh','ow','oh','scale','rot_deg','hf_ratio','lap_ratio','out_mean','src_mean'])
for sd_,od_,tag in pairs:
    S_=sorted(glob.glob(os.path.join(sd_,'*.jpg'))); O_=sorted(glob.glob(os.path.join(od_,'*.tif')))
    print(tag,len(S_),len(O_),flush=True)
    for i in range(min(len(S_),len(O_))):
        S=cv2.imread(S_[i],cv2.IMREAD_GRAYSCALE); O=cv2.imread(O_[i],cv2.IMREAD_GRAYSCALE)
        sd=cv2.resize(S,None,fx=1/DS,fy=1/DS,interpolation=cv2.INTER_AREA)
        od=cv2.resize(O,None,fx=1/DS,fy=1/DS,interpolation=cv2.INTER_AREA)
        k1,d1=orb.detectAndCompute(od,None); k2,d2=orb.detectAndCompute(sd,None)
        try:
            m=sorted(bf.match(d1,d2),key=lambda x:x.distance)[:1500]
            p1=np.float32([k1[x.queryIdx].pt for x in m]).reshape(-1,1,2)
            p2=np.float32([k2[x.trainIdx].pt for x in m]).reshape(-1,1,2)
            M,_=cv2.estimateAffinePartial2D(p1,p2,method=cv2.RANSAC,ransacReprojThreshold=2.0)
            scale=float(np.hypot(M[0,0],M[1,0])); rot=float(np.degrees(np.arctan2(M[1,0],M[0,0])))
            oc=np.array([O.shape[1]/2,O.shape[0]/2]); sc=(M[:,:2]*DS)@(oc/DS)+M[:,2]*DS
        except Exception as e:
            scale=rot=float('nan'); sc=np.array([S.shape[1]/2,S.shape[0]/2])
        N=1024
        po=O[int(oc[1]-N/2):int(oc[1]+N/2), int(oc[0]-N/2):int(oc[0]+N/2)]
        ps=S[int(sc[1]-N/2):int(sc[1]+N/2), int(sc[0]-N/2):int(sc[0]+N/2)]
        if ps.shape!=(N,N) or po.shape!=(N,N): hf=lp=float('nan')
        else:
            hf=radial_hf(po)/max(radial_hf(ps),1e-9)
            lp=cv2.Laplacian(po.astype(np.float32),cv2.CV_32F).var()/max(cv2.Laplacian(ps.astype(np.float32),cv2.CV_32F).var(),1e-9)
        w.writerow([tag,i+1,os.path.basename(S_[i]),os.path.basename(O_[i]),S.shape[1],S.shape[0],O.shape[1],O.shape[0],
                    f'{scale:.5f}',f'{rot:+.3f}',f'{hf:.4f}',f'{lp:.4f}',f'{O.mean():.2f}',f'{S.mean():.2f}'])
        print(f'{tag} {i+1:3d} scale={scale:.5f} rot={rot:+.3f} hf={hf:.3f} lap={lp:.3f}',flush=True)
