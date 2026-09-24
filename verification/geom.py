import cv2, numpy as np, glob, os, sys
cv2.setNumThreads(4)
src_dir, out_dir, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
srcs = sorted(glob.glob(os.path.join(src_dir,'*.jpg')))
outs = sorted(glob.glob(os.path.join(out_dir,'*.tif')))
print(f'{len(srcs)} src / {len(outs)} out')
DS = 4
orb = cv2.ORB_create(6000)
bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
for i in range(min(n, len(outs))):
    s = cv2.imread(srcs[i], cv2.IMREAD_GRAYSCALE)
    o = cv2.imread(outs[i], cv2.IMREAD_GRAYSCALE)
    sd = cv2.resize(s, None, fx=1/DS, fy=1/DS, interpolation=cv2.INTER_AREA)
    od = cv2.resize(o, None, fx=1/DS, fy=1/DS, interpolation=cv2.INTER_AREA)
    k1,d1 = orb.detectAndCompute(od, None)   # output -> source
    k2,d2 = orb.detectAndCompute(sd, None)
    m = sorted(bf.match(d1,d2), key=lambda x:x.distance)[:1500]
    p1 = np.float32([k1[x.queryIdx].pt for x in m]).reshape(-1,1,2)
    p2 = np.float32([k2[x.trainIdx].pt for x in m]).reshape(-1,1,2)
    M, inl = cv2.estimateAffinePartial2D(p1, p2, method=cv2.RANSAC, ransacReprojThreshold=2.0)
    scale = float(np.hypot(M[0,0], M[1,0]))
    theta = float(np.degrees(np.arctan2(M[1,0], M[0,0])))
    print(f'{os.path.basename(outs[i])[-13:]:14s} src{s.shape[::-1]} out{o.shape[::-1]} '
          f'scale={scale:.5f} rot={theta:+.3f}deg inliers={int(inl.sum())}/{len(m)} '
          f'meanY src={s.mean():.2f} out={o.mean():.2f}')
