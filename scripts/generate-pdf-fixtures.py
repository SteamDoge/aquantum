# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Generate labelled synthetic PDF performance fixtures; refuse to overwrite."""
import argparse, io, json, hashlib
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.pdfencrypt import StandardEncryption
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.utils import ImageReader
from PIL import Image, ImageDraw

parser=argparse.ArgumentParser()
parser.add_argument('--out',required=True)
args=parser.parse_args()
root=Path(args.out); root.mkdir(parents=True,exist_ok=False)
image=Image.new('RGB',(1024,1448),'white'); draw=ImageDraw.Draw(image)
for y in range(30,1400,32): draw.text((32,y),'Synthetic scanned page / RC005 performance fixture',fill='black')
for x in range(80,900,180): draw.rectangle((x,400,x+100,700),outline='navy',width=4)
jpeg=io.BytesIO(); image.save(jpeg,format='JPEG',quality=85); jpeg.seek(0)
font=Path('C:/Windows/Fonts/msyh.ttc')
if not font.exists(): raise SystemExit('Required local CJK font is missing')
pdfmetrics.registerFont(TTFont('fixture-cjk',str(font),subfontIndex=0))
fixtures=[]
for kind,count,size in [('ordinary',20,(595,842)),('scan1000',1000,(595,842)),('large-drawing',4,(10000,5000)),('complex-font',12,(595,842)),('encrypted',8,(595,842))]:
 path=root/(kind+'.pdf')
 options={'encrypt':StandardEncryption('rc005-sample',ownerPassword='rc005-owner',strength=128)} if kind=='encrypted' else {}
 c=canvas.Canvas(str(path),pagesize=size,**options)
 for i in range(count):
  c.bookmarkPage(str(i));
  if i<12: c.addOutlineEntry('Chapter '+str(i+1),str(i),level=0)
  if kind=='scan1000': c.drawImage(ImageReader(jpeg),0,0,width=size[0],height=size[1])
  elif kind=='large-drawing':
   for x in range(0,10000,50): c.line(x,0,10000-x,5000)
   c.setFont('Helvetica',40); c.drawString(300,2500,'Large synthetic drawing')
  elif kind=='complex-font':
   c.setFont('fixture-cjk',16)
   for y in range(80,800,32): c.drawString(32,y,'复杂字体排版与阅读性能测试：章节、目录、混合 ABC 123。')
  else:
   c.setFont('Helvetica',20); c.drawString(32,740,'Hello PDF sample page '+str(i+1))
   c.drawImage(ImageReader(jpeg),40,40,width=200,height=280)
  c.showPage()
 c.save()
 fixtures.append({'file':path.name,'kind':kind,'pages':count,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'password':'rc005-sample' if kind=='encrypted' else None})
(root/'manifest.json').write_text(json.dumps({'synthetic':True,'fixtures':fixtures},indent=2),encoding='utf-8')
print(root.resolve())
