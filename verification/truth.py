import cv2, numpy as np, sys
def skew(path):
    g=cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    s=cv2.resize(g,None,fx=1600/max(g.shape),fy=1600/max(g.shape),interpolation=cv2.INTER_AREA)
    e=cv2.Canny(cv2.GaussianBlur(s,(5,5),0),40,120)
    L=cv2.HoughLinesP(e,1,np.pi/1440,threshold=150,minLineLength=min(s.shape)//3,maxLineGap=20)
    if L is None: return None,0
    a=[]
    for x1,y1,x2,y2 in L[:,0]:
        v=np.degrees(np.arctan2(float(y2-y1),float(x2-x1))); v=(v+90)%180-90
        if abs(v)<=12: a.append(v)
        elif abs(abs(v)-90)<=12: a.append(v-90 if v>0 else v+90)
    return (float(np.median(a)), len(a)) if len(a)>=3 else (None,len(a))
for p in sys.argv[1:]:
    m,n=skew(p)
    print(f'  {p.split("/")[-1][:44]:46s} measured skew {("%+.3f"%m) if m is not None else "  n/a ":>8s}  (n={n})')
