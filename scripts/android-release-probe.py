# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Inspect one explicitly selected Android device; all evidence uses a fresh directory."""
import argparse,subprocess,time,json,xml.etree.ElementTree as ET
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--device',required=True);p.add_argument('action',choices=['inspect','tap','long','type','back','swipe']);p.add_argument('value',nargs='?',default='');p.add_argument('--out',default='output/rc4-android-release');a=p.parse_args()
cfg=json.loads(Path('.tools/toolchains.json').read_text(encoding='utf-8-sig'));adb=str(Path(cfg['androidSdk'])/'platform-tools/adb.exe')
def run(*args): return subprocess.run([adb,'-s',a.device,*args],check=True,capture_output=True).stdout
out=Path(a.out)/(time.strftime('%Y%m%d-%H%M%S')+'-'+str(time.time_ns()%1000000));out.mkdir(parents=True,exist_ok=False)
remote_xml='/sdcard/aq-rc005-'+out.name+'.xml'
def nodes():
 run('shell','uiautomator','dump',remote_xml);return ET.fromstring(run('exec-out','cat',remote_xml))
if a.action in ['tap','long']:
 root=nodes();matches=[n for n in root.iter('node') if a.value in [n.get('text'),n.get('content-desc')]]
 if not matches: raise SystemExit('Label not found; inspect the current UI before choosing another action')
 import re
 bounds=list(map(int,re.findall(r'\d+',matches[0].get('bounds'))));x=(bounds[0]+bounds[2])//2;y=(bounds[1]+bounds[3])//2
 if a.action=='tap':run('shell','input','tap',str(x),str(y))
 else:run('shell','input','swipe',str(x),str(y),str(x),str(y),'700')
elif a.action=='type':run('shell','input','text',a.value)
elif a.action=='back':run('shell','input','keyevent','4')
elif a.action=='swipe':run('shell','input','swipe',*a.value.split(','))
time.sleep(.8)
root=nodes();ET.ElementTree(root).write(out/'ui.xml',encoding='utf-8')
with (out/'screen.png').open('wb') as f:subprocess.run([adb,'-s',a.device,'exec-out','screencap','-p'],stdout=f,check=True)
for n in root.iter('node'):
 if n.get('text') or n.get('content-desc'):print(json.dumps({k:n.get(k) for k in ['text','content-desc','bounds','clickable','selected']},ensure_ascii=False))
print(str(out.resolve()))
