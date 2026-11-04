# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 AQuantum Reader contributors.
"""Manually refresh lockfile-bound license metadata from installed dependencies.

Run cargo fetch --locked and flutter pub get --enforce-lockfile first.
Does not download or modify third-party source.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]


def main():
    meta = json.loads(subprocess.check_output(
        ['cargo', 'metadata', '--locked', '--offline', '--format-version', '1'], cwd=ROOT))
    rows = []
    permitted = {'0BSD OR MIT OR Apache-2.0', 'Unlicense OR MIT', 'MIT OR Apache-2.0',
        'BSD-3-Clause', 'Apache-2.0/MIT', 'Apache-2.0', 'MIT', 'MIT/Apache-2.0',
        '(Apache-2.0 OR MIT) AND BSD-3-Clause', 'Apache-2.0 OR MIT', 'Zlib', 'ISC',
        'Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT', 'MIT OR Zlib OR Apache-2.0',
        'MIT OR Apache-2.0 OR LGPL-2.1-or-later', '(MIT OR Apache-2.0) AND Unicode-3.0'}
    for p in meta['packages']:
        if p.get('source'):
            if p['license'] not in permitted:
                raise ValueError('New Cargo license requires review: ' + p['name'])
            rows.append({'ecosystem': 'cargo', 'name': p['name'], 'version': p['version'],
                         'license': p['license'], 'source': p['source']})
    config_path = ROOT / 'apps/flutter_reader/.dart_tool/package_config.json'
    config = json.loads(config_path.read_bytes())
    # Resolve Flutter from package_config, never hardcode a developer machine path.
    flutter_pkg = next(p for p in config['packages'] if p['name'] == 'flutter')

    def location(uri):
        if uri.startswith('file:'):
            path = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
            if re.match(r'^/[A-Za-z]:/', path):
                path = path[1:]
            return Path(path)
        return (config_path.parent / urllib.parse.unquote(uri)).resolve()

    flutter_root = location(flutter_pkg['rootUri']).parents[1]
    flutter_version = json.loads((flutter_root / 'bin/cache/flutter.version.json').read_bytes())['frameworkVersion']
    output = ROOT / 'LICENSES'
    output.mkdir(exist_ok=True)
    pending_notices = {'Flutter-LICENSE': (flutter_root / 'LICENSE').read_bytes()}
    lock_text = (ROOT / 'apps/flutter_reader/pubspec.lock').read_text(encoding='utf-8')
    locked_pub = {}
    for name, body in re.findall(r'^  ([A-Za-z0-9_]+):\n(.*?)(?=^  [A-Za-z0-9_]+:|^sdks:|\Z)', lock_text, re.M | re.S):
        match = re.search(r'^    version: ["\']?([^"\'\s]+)', body, re.M)
        if match:
            locked_pub[name] = match[1]
    for p in config['packages']:
        if p['name'] == 'aquantum_reader':
            continue
        directory = location(p['rootUri'])
        version_match = re.search(r'^version:\s*([^\s#]+)', (directory / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
        version = version_match[1] if version_match else 'Flutter-' + flutter_version
        if not directory.is_relative_to(flutter_root) and locked_pub.get(p['name']) != version:
            raise ValueError('Refresh package_config for locked package: ' + p['name'])
        license_files = sorted(q for q in directory.iterdir() if q.is_file() and re.match(r'^(license|copying|notice)', q.name, re.I))
        license_file = license_files[0] if license_files else flutter_root / 'LICENSE'
        content = license_file.read_bytes()
        text = content.decode('utf-8', errors='replace')
        if 'Mozilla Public License Version 2.0' in text:
            if p['name'] != 'dbus':
                raise ValueError('New MPL dependency needs secondary-license review: ' + p['name'])
            # The license's Exhibit B template is not itself a source designation.
            for dart in directory.glob('lib/**/*.dart'):
                if 'Incompatible With Secondary Licenses' in dart.read_text(encoding='utf-8'):
                    raise ValueError('MPL secondary-license restriction requires review')
            kind = 'MPL-2.0'
            pending_notices['dbus-LICENSE'] = content
        elif 'Permission is hereby granted, free of charge' in text:
            kind = 'MIT'
        elif 'Apache License' in text:
            kind = 'Apache-2.0'
        elif 'Redistribution and use in source and binary forms' in text:
            kind = 'BSD-3-Clause' if 'neither the name' in text.lower() else 'BSD-2-Clause'
        else:
            raise ValueError('Unclassified Dart license requires review: ' + p['name'])
        rows.append({'ecosystem': 'pub', 'name': p['name'], 'version': version,
            'license': kind, 'license_text_sha256': hashlib.sha256(content).hexdigest(),
            'source': 'Flutter SDK' if directory.is_relative_to(flutter_root) else 'https://pub.dev/packages/' + p['name']})
    # Reject a package_config created for a different pubspec.lock.
    if not (ROOT / 'apps/flutter_reader/pubspec.lock').exists():
        raise ValueError('Missing pubspec.lock')
    locks = {n: hashlib.sha256(subprocess.check_output(['git', 'show', 'HEAD:' + n], cwd=ROOT)).hexdigest()
             for n in ['Cargo.lock', 'apps/flutter_reader/pubspec.lock']}
    for name, sha in locks.items():
        # Normalize only worktree CRLF; Git blob bytes are the audit binding.
        if hashlib.sha256((ROOT / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest() != sha:
            raise ValueError('Commit/review changed lockfile before audit: ' + name)
    audit = {'lockfiles': locks,
        'scope': 'All resolved Cargo and Dart packages, including build/dev and unsupported-target dependencies; registry source is fetched, not vendored.',
        'cargo_review': 'Reviewed permissive OR branches (MIT/Apache where applicable); AND BSD/Unicode obligations remain. Metadata review is not a source provenance guarantee.',
        'dart_review': 'MIT/BSD/Apache and dbus MPL-2.0; no secondary-license restriction in dbus Dart source. Android/Windows are the exported UI platforms.',
        'packages': sorted(rows, key=lambda p: (p['ecosystem'], p['name'], p['version']))}
    for name, data in pending_notices.items():
        (output / name).write_bytes(data)
    (output / 'dependencies.json').write_text(json.dumps(audit, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'packages': len(rows), 'cargo': sum(p['ecosystem'] == 'cargo' for p in rows),
                      'pub': sum(p['ecosystem'] == 'pub' for p in rows)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
