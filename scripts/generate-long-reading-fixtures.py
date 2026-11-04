# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Generate reproducible long-reading inputs. Never overwrite existing output."""
import argparse
import hashlib
import io
import json
import struct
import zipfile
from pathlib import Path
from PIL import Image, ImageDraw
from reportlab.pdfgen import canvas

parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True)
parser.add_argument('--kf8', help='Optional genuine unencrypted KF8 source; bytes are copied unchanged')
args = parser.parse_args()
root = Path(args.out)
root.mkdir(parents=True, exist_ok=False)
source_kf8 = None
if args.kf8:
    original = Path(args.kf8)
    data = original.read_bytes()
    record = struct.unpack_from('>I', data, 78)[0]
    version = struct.unpack_from('>I', data, record + 36)[0]
    if data[60:68] != b'BOOKMOBI' or data[record + 16:record + 20] != b'MOBI' or version < 8 or struct.unpack_from('>H', data, record + 12)[0] != 0:
        raise ValueError('KF8 source must have a genuine unencrypted MOBI version >= 8 header')
    (root / 'long.azw3').write_bytes(data)
    source_kf8 = {'source': str(original.resolve()), 'mobi_version': version,
                  'sha256': hashlib.sha256(data).hexdigest(), 'note': 'Same KF8 bytes, AZW3 import entry; not an independent publication'}
sentence = '长文阅读测试：滚动应当跟手，翻页保持整页，修改字号后继续读同一处文字。'
paragraphs = [f'第{i:05d}段 LONGMARK{i:05d} ' + sentence * 8 for i in range(2400)]
paragraphs[1200] += sentence * 1200
(root / 'long.txt').write_text('\n\n'.join(paragraphs), encoding='utf-8')
markdown = []
for i, paragraph in enumerate(paragraphs):
    if i % 30 == 0:
        markdown.append(f'# 第{i // 30 + 1}章 长文阅读')
    markdown.append(paragraph)
    if i % 120 == 0:
        markdown.extend(['| 项目 | 内容 |\n| --- | --- |\n| 长文 | 表格仍须可读 |',
                         '- [ ] 只读正文独立交互状态\n- [x] 保留原文',
                         '```text\ncode block for long document\n```'])
(root / 'long.md').write_text('\n\n'.join(markdown), encoding='utf-8')

chapters = [paragraphs[i:i + 30] for i in range(0, len(paragraphs), 30)]
with zipfile.ZipFile(root / 'long.epub', 'x', compression=zipfile.ZIP_DEFLATED) as book:
    book.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
    book.writestr('META-INF/container.xml', '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    items = ''.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(len(chapters)))
    spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(len(chapters)))
    book.writestr('book.opf', '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">aq-long-20261022</dc:identifier><dc:title>Long EPUB 80 chapters</dc:title><dc:language>zh</dc:language></metadata><manifest><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>' + items + '</manifest><spine>' + spine + '</spine></package>')
    nav = ''.join(f'<li><a href="c{i}.xhtml">Chapter {i + 1}</a></li>' for i in range(len(chapters)))
    book.writestr('nav.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>' + nav + '</ol></nav></body></html>')
    for i, content in enumerate(chapters):
        body = ''.join(f'<p>{p}</p>' for p in content)
        book.writestr(f'c{i}.xhtml', f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter {i + 1}</title></head><body><h1>Chapter {i + 1}</h1>{body}</body></html>')
sections = ''.join(f'<section id="chapter{i}"><title><p>Chapter {i + 1}</p></title>' + ''.join(f'<p>{p}</p>' for p in content) + '</section>' for i, content in enumerate(chapters))
(root / 'long.fb2').write_text('<?xml version="1.0" encoding="UTF-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><genre>science</genre><author><first-name>QA</first-name><last-name>Reader</last-name></author><book-title>Long FB2 80 chapters</book-title><lang>zh</lang></title-info></description><body>' + sections + '</body></FictionBook>', encoding='utf-8')

c = canvas.Canvas(str(root / 'long.pdf'), pagesize=(595, 842))
for i in range(600):
    if i % 40 == 0:
        c.bookmarkPage(str(i))
        c.addOutlineEntry(f'Chapter {i // 40 + 1}', str(i), level=0)
    c.setPageSize((842, 595) if i % 71 == 0 else (595, 842))
    c.setFont('Helvetica', 18)
    c.drawString(30, 540, f'Long PDF - page {i + 1} / 600')
    c.setFont('Helvetica', 12)
    for row in range(30):
        c.drawString(30, 510 - row * 15, f'LONGMARK{i:05d} Row {row} Continuous reading and page alignment.')
    c.showPage()
c.save()
with zipfile.ZipFile(root / 'long.cbz', 'x', compression=zipfile.ZIP_STORED) as comic:
    for i in range(320):
        height = 6000 if i % 79 == 0 else 720 + (i % 4) * 120
        image = Image.new('RGB', (480, height), (225 + i % 25, 235, 245))
        draw = ImageDraw.Draw(image)
        for y in range(30, height, 100):
            draw.text((30, y), f'PAGE {i + 1:03d} / 320 - PANEL {y // 100}', fill='black')
            draw.rectangle((20, y + 25, 450, y + 80), outline='navy', width=3)
        data = io.BytesIO()
        image.save(data, format='JPEG', quality=85)
        comic.writestr(f'{i + 1:04d}.jpg', data.getvalue())
manifest = {'synthetic': True, 'paragraphs': 2400, 'long_paragraph_chars': len(paragraphs[1200]),
            'text_chars': sum(map(len, paragraphs)), 'chapters': 80, 'pdf_pages': 600,
            'comic_pages': 320, 'fixtures': []}
if source_kf8:
    manifest['kf8_source'] = source_kf8
for path in sorted(root.iterdir()):
    manifest['fixtures'].append({'name': path.name, 'path': str(path.resolve()), 'bytes': path.stat().st_size,
                                 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
(root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(manifest, ensure_ascii=False))
