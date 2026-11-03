// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';
import 'reader_contract.dart';

/// Extensions can populate panels. No registration surface exposes top buttons.
class ReaderExtensions {
  final PluginManager? plugins;
  final ExtensionContext context;
  const ReaderExtensions(this.plugins, this.context);
  List<PluginAction> actions(ReaderPanel panel) {
    final points = switch (panel) {
      ReaderPanel.settings => [ExtensionPoint.readerSettings],
      ReaderPanel.navigation => [ExtensionPoint.readerNavigation],
      ReaderPanel.search => [
        ExtensionPoint.readerSearch,
        ExtensionPoint.search,
      ],
      ReaderPanel.bookmarks => [ExtensionPoint.readerBookmarks],
      ReaderPanel.more => [
        ExtensionPoint.readerMore,
        ExtensionPoint.readerToolbar,
      ],
      ReaderPanel.view => <ExtensionPoint>[],
      // Encoding and direction are core capabilities driven by the reader
      // panels themselves, so extensions cannot add actions to them.
      ReaderPanel.format ||
      ReaderPanel.encoding ||
      ReaderPanel.direction => <ExtensionPoint>[],
    };
    return [for (final point in points) ...?plugins?.actions(point, context)];
  }
}
