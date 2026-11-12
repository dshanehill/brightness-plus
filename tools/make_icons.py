"""Draws the Brightness+ lightbulb icon. Run from the repository root:  python3 tools/make_icons.py"""
import os
os.makedirs("docs", exist_ok=True)
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math
S=4; N=1024*S
def sc(v): return int(v*S)
img=Image.new("RGBA",(N,N),(0,0,0,0))
# squircle mask
mask=Image.new("L",(N,N),0)
ImageDraw.Draw(mask).rounded_rectangle([sc(100),sc(100),sc(924),sc(924)],radius=sc(186),fill=255)
# background vertical gradient deep indigo -> navy
bg=Image.new("RGBA",(N,N))
top=(58,72,160); bot=(14,20,58)
px=Image.new("RGBA",(1,N))
for y in range(N):
    t=y/(N-1)
    px.putpixel((0,y),tuple(int(top[i]*(1-t)+bot[i]*t) for i in range(3))+(255,))
bg=px.resize((N,N))
# glow
glow=Image.new("RGBA",(N,N),(0,0,0,0))
gd=ImageDraw.Draw(glow)
cx,cy=512,430
for r,a in [(380,40),(310,60),(250,80)]:
    gd.ellipse([sc(cx-r),sc(cy-r),sc(cx+r),sc(cy+r)],fill=(255,214,110,a))
glow=glow.filter(ImageFilter.GaussianBlur(sc(60)))
bg=Image.alpha_composite(bg,glow)
# bulb glass shape
glass=Image.new("L",(N,N),0)
d=ImageDraw.Draw(glass)
R=205
d.ellipse([sc(cx-R),sc(cy-R),sc(cx+R),sc(cy+R)],fill=255)
# neck: tangent-ish polygon from circle sides down to neck
ang=math.radians(48)
lx=cx-R*math.sin(ang); ly=cy+R*math.cos(ang)
rx=cx+R*math.sin(ang)
d.polygon([(sc(lx),sc(ly)),(sc(rx),sc(ly)),(sc(cx+92),sc(650)),(sc(cx-92),sc(650))],fill=255)
glass=glass.filter(ImageFilter.GaussianBlur(S//2))
# glass fill radial: bright yellow center -> warm amber
gl=Image.new("RGBA",(N,N))
gp=Image.new("RGBA",(N,N),(255,196,46,255))
inner=Image.new("RGBA",(N,N),(0,0,0,0))
ImageDraw.Draw(inner).ellipse([sc(cx-150),sc(cy-170),sc(cx+120),sc(cy+110)],fill=(255,250,205,255))
inner=inner.filter(ImageFilter.GaussianBlur(sc(70)))
gp=Image.alpha_composite(gp,inner)
bulb=Image.new("RGBA",(N,N),(0,0,0,0)); bulb.paste(gp,(0,0),glass)
bg=Image.alpha_composite(bg,bulb)
# highlight
hl=Image.new("RGBA",(N,N),(0,0,0,0))
ImageDraw.Draw(hl).arc([sc(cx-160),sc(cy-160),sc(cx+160),sc(cy+160)],start=200,end=255,fill=(255,255,255,210),width=sc(26))
hl=hl.filter(ImageFilter.GaussianBlur(sc(3)))
bg=Image.alpha_composite(bg,hl)
# filament
fl=Image.new("RGBA",(N,N),(0,0,0,0)); fd=ImageDraw.Draw(fl)
pts=[(cx-55,560),(cx-55,480),(cx-28,440),(cx,480),(cx+28,440),(cx+55,480),(cx+55,560)]
fd.line([(sc(x),sc(y)) for x,y in pts],fill=(200,110,10,255),width=sc(14),joint="curve")
bg=Image.alpha_composite(bg,fl)
# screw base
base=Image.new("RGBA",(N,N),(0,0,0,0)); bd=ImageDraw.Draw(base)
for i,(y0,w) in enumerate([(662,196),(712,190),(762,178)]):
    bd.rounded_rectangle([sc(cx-w/2),sc(y0),sc(cx+w/2),sc(y0+40)],radius=sc(20),fill=(222,226,236,255) if i%2==0 else (190,196,212,255))
bd.rounded_rectangle([sc(cx-56),sc(806),sc(cx+56),sc(846)],radius=sc(20),fill=(150,158,178,255))
bg=Image.alpha_composite(bg,base)
out=Image.new("RGBA",(N,N),(0,0,0,0)); out.paste(bg,(0,0),mask)
# soft shadow under squircle
sh=Image.new("RGBA",(N,N),(0,0,0,0))
ImageDraw.Draw(sh).rounded_rectangle([sc(100),sc(112),sc(924),sc(936)],radius=sc(186),fill=(0,0,0,90))
sh=sh.filter(ImageFilter.GaussianBlur(sc(14)))
final=Image.alpha_composite(sh,out).resize((1024,1024),Image.LANCZOS)
final.save("Brightness+.app/Contents/Resources/AppIcon.icns")
final.resize((256,256),Image.LANCZOS).save("docs/icon.png", optimize=True)
