// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import '../l10n/l10n.dart';

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
  final String? _author, _publisher;
  final int apiVersion;
  final Set<PluginPermission> permissions;
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    this.apiVersion = pluginApiVersion,
    this.permissions = const {},
    String? author,
    String? publisher,
  }) : _author = author,
       _publisher = publisher;

  /// Undeclared values are described in the current interface language.
  String get author => _author ?? tr('未声明');
  String get publisher => _publisher ?? tr('未声明（未验证）');
}
