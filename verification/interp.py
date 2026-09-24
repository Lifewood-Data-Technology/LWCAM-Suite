import cv2, numpy as np
cv2.setNumThreads(4)
S=cv2.imread("Source Images/All Saints' Church Taiping Deceased 2014-2017/MYTP01_IMG_20260804_143044_001.jpg", cv2.IMREAD_GRAYSCALE)
# dense-text region
P=S[4300:6348, 1600:3648].astype(np.float32)
print('patch', P.shape, 'mean %.1f std %.1f'%(P.mean(),P.std()))
def rps(a):
    a=a-a.mean(); w=np.outer(np.hanning(a.shape[0]),np.hanning(a.shape[1]))
    F=np.abs(np.fft.fftshift(np.fft.fft2(a*w)))**2
    cy,cx=np.array(F.shape)//2; y,x=np.indices(F.shape); r=np.hypot(y-cy,x-cx).astype(int)
    return np.bincount(r.ravel(),F.ravel())/np.bincount(r.ravel())
base=rps(P); n=P.shape[0]//2
def band(p,a,b): return p[int(a*n):int(b*n)].mean()
def rot(img, ang, flag):
    M=cv2.getRotationMatrix2D((img.shape[1]/2,img.shape[0]/2), ang, 1.0)
    return cv2.warpAffine(img, M, (img.shape[1],img.shape[0]), flags=flag, borderMode=cv2.BORDER_REPLICATE)
def jpg(img,q,s444=True):
    p=[cv2.IMWRITE_JPEG_QUALITY,q]+([cv2.IMWRITE_JPEG_SAMPLING_FACTOR,cv2.IMWRITE_JPEG_SAMPLING_FACTOR_444] if s444 else [])
    ok,b=cv2.imencode('.jpg',np.clip(img,0,255).astype(np.uint8),p); return cv2.imdecode(b,cv2.IMREAD_GRAYSCALE).astype(np.float32)
ANG=2.0
cases=[
 ('no rotation, no encode (reference)', P),
 ('CURRENT: LINEAR rot + JPEG q90',      jpg(rot(P,ANG,cv2.INTER_LINEAR),90)),
 ('LINEAR rot, lossless',                rot(P,ANG,cv2.INTER_LINEAR)),
 ('CUBIC rot, lossless',                 rot(P,ANG,cv2.INTER_CUBIC)),
 ('LANCZOS4 rot, lossless',              rot(P,ANG,cv2.INTER_LANCZOS4)),
 ('LANCZOS4 rot + JPEG q90',             jpg(rot(P,ANG,cv2.INTER_LANCZOS4),90)),
 ('no rotation, JPEG q90 only',          jpg(P,90)),
]
print(f'\nrotation angle {ANG} deg.  detail retained vs reference (1.000 = nothing lost)')
print(f'{"":38s} {"mid 0.15-0.25":>14s} {"high 0.30-0.45":>15s} {"lapvar":>9s}')
for name,img in cases:
    p=rps(img)
    print(f'{name:38s} {band(p,.30,.50)/band(base,.30,.50):14.3f} {band(p,.60,.90)/band(base,.60,.90):15.3f} '
          f'{cv2.Laplacian(img,cv2.CV_32F).var()/cv2.Laplacian(P,cv2.CV_32F).var():9.3f}')
