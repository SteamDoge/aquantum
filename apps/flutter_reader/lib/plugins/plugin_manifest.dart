// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
const pluginApiVersion = 1;

enum PluginPermission {
  selectedText,
  documentText,
  derivedFiles,
  network,
  libraryImport,
  libraryRead,
  services,
  clipboard,
  externalFiles,
  secureStorage,
}

class PluginManifest {
  final String id, name, version, description;
  final String author, publisher;
  final int apiVersion;
  final Set<PluginPermission> permissions;
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.apiVersion = pluginApiVersion,
    this.permissions = const {},
    this.author = '未声明',
    this.publisher = '未声明（未验证）',
  });
}
