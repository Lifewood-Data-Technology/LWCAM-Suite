import cv2, numpy as np, glob, os, importlib.util, json
from PIL import Image
Image.MAX_IMAGE_PIXELS=None
spec=importlib.util.spec_from_file_location('io_', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'LWIP', 'backend', 'deskew_crop_tool', 'image_ops.py'))
io_=importlib.util.module_from_spec(spec); spec.loader.exec_module(io_)
OUT=r'C:/LWCamDev/scratch/final4'
os.makedirs(OUT, exist_ok=True)
srcs=sorted(glob.glob("Source Images/All Saints' Church Taiping Deceased 2014-2017/*.jpg"))
olds=sorted(glob.glob('Output/M95K-ZMLMY01MYTP01260804000004/artifacts/*.tif'))
def hf(a):
    a=a.astype(np.float32); a=a-a.mean()
    w=np.outer(np.hanning(a.shape[0]),np.hanning(a.shape[1]))
    F=np.abs(np.fft.fftshift(np.fft.fft2(a*w)))**2
    cy,cx=np.array(F.shape)//2; y,x=np.indices(F.shape); r=np.hypot(y-cy,x-cx).astype(int)
    P=np.bincount(r.ravel(),F.ravel())/np.bincount(r.ravel()); n=a.shape[0]//2
    return P[int(0.6*n):int(0.9*n)].mean()
def patch(img, N=1024):
    h,w=img.shape[:2]; return img[h//2-N//2:h//2+N//2, w//2-N//2:w//2+N//2]
rot_old=[]; rot_new=[]; ang=[]; errs=[]; sizes=[]
for s,o in zip(srcs,olds):
    d=os.path.join(OUT, os.path.basename(s))
    r=io_.deskew_crop_file(s,d,200,100)
    ang.append(abs(r['angle']))
    S=cv2.imread(s, cv2.IMREAD_GRAYSCALE)
    N=cv2.imread(d, cv2.IMREAD_GRAYSCALE); O=cv2.imread(o, cv2.IMREAD_GRAYSCALE)
    base=hf(patch(S))
    if base>0:
        rot_new.append(hf(patch(N))/base); rot_old.append(hf(patch(O))/base)
    sizes.append(os.path.getsize(d)/1e6)
    im=Image.open(d)
    errs.append((len(im.getexif()), max(max(v) for v in im.quantization.values()), 0x8825 in im.getexif()))
    im.close()
print(f'pages processed            : {len(srcs)}')
print(f'deskew fired on            : {sum(1 for a in ang if a>0)} / {len(ang)}   (old build: 19/24 at the 0.01 deg threshold)')
print(f'high-freq retention  OLD   : {np.median(rot_old):.3f}')
print(f'high-freq retention  NEW   : {np.median(rot_new):.3f}')
print(f'quantization table max     : {set(e[1] for e in errs)}   (camera writes 1)')
print(f'EXIF tag counts            : {sorted(set(e[0] for e in errs))}')
print(f'any GPS present            : {any(e[2] for e in errs)}')
print(f'output size                : mean {np.mean(sizes):.2f} MB   total {sum(sizes)/1000:.2f} GB per 24 pages')
