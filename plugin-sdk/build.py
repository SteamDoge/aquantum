# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Build already-compiled JavaScript + static assets. No package installation."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def build(project, output=None):
    root = Path(project).resolve()
    manifest = json.loads((root / 'aquantum.plugin.json').read_text(encoding='utf-8'))
    if manifest.get('runtime') != 'javascript-v1':
        raise ValueError('Only javascript-v1 is supported')
    source = root / 'package'
    if not (source / manifest['entry']).is_file():
        raise ValueError('Missing compiled JavaScript entry')
    out = Path(output).resolve() if output else root / 'dist' / f"{manifest['id']}-{manifest['version']}.aqplugin.zip"
    out.parent.mkdir(parents=True, exist_ok=True)
    entries = {'aquantum.plugin.json': json.dumps(manifest, ensure_ascii=False, indent=2).encode('utf-8')}
    for file in sorted(source.rglob('*')):
        if file.is_symlink():
            raise ValueError(f'Symlink is not a package resource: {file}')
        if file.is_file():
            name = file.relative_to(source).as_posix()
            if name in entries or file.suffix.lower() not in {'.js', '.mjs', '.html', '.css', '.json', '.png', '.jpg', '.jpeg', '.webp', '.gif', '.svg', '.ttf', '.otf', '.woff', '.woff2', '.txt', '.md'}:
                raise ValueError(f'Unsupported or duplicate resource: {name}')
            data = file.read_bytes()
            # Git/Windows checkouts may use CRLF. Canonicalize source code only;
            # downloadable documents, images, fonts and other assets retain bytes.
            if file.suffix.lower() in {'.js', '.mjs', '.html', '.css'}:
                data = data.replace(b'\r\n', b'\n')
            entries[name] = data
    with zipfile.ZipFile(out, 'x', zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, (2026, 10, 25, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    receipt = {'file': str(out), 'id': manifest['id'], 'version': manifest['version'], 'sha256': hashlib.sha256(out.read_bytes()).hexdigest(), 'bytes': out.stat().st_size}
    out.with_suffix('.receipt.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project')
    parser.add_argument('--output')
    options = parser.parse_args()
    print(json.dumps(build(options.project, options.output), ensure_ascii=False))
