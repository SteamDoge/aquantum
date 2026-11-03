// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = new URL('../', import.meta.url);
const read = name => fs.readFileSync(new URL(name, root), 'utf8').replaceAll('\r\n', '\n');
const display = read('VERSION').trim();
const match = /^rc\.(\d+)\.(\d+)\.(\d+)$/.exec(display);
if (!match) throw new Error('VERSION must use rc.<major>.<minor>.<patch>');
const semver = `${match[1]}.${match[2]}.${match[3]}-rc.0`;
const cargo = /^version = "([^"]+)"$/m.exec(read('Cargo.toml'))?.[1];
const flutter = /^version: (.+)$/m.exec(read('apps/flutter_reader/pubspec.yaml'))?.[1];
if (cargo !== semver || flutter !== `${semver}+${Number(match[3])}`) {
  throw new Error(`Version mismatch at ${fileURLToPath(root)}: expected ${semver}, Flutter +${Number(match[3])}`);
}
const lock = read('Cargo.lock');
for (const name of ['aq-domain', 'aq-application', 'aq-local', 'aq-bridge', 'aq-cli']) {
  if (!lock.includes(`name = "${name}"\nversion = "${semver}"`)) throw new Error(`Cargo.lock version mismatch: ${name}`);
}
console.log(`Version consistent: ${display} / ${semver} / ${flutter}`);
