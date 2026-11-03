// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ReaderBookmark {
  final String locationId, label;
  ReaderBookmark(this.locationId, this.label);
}

/// Device-local personal bookmarks. IDs are renderer anchors, not page numbers.
/// A malformed/unknown record is retained and blocks silent overwrite.
class ReaderBookmarkStore {
  final String documentId;
  ReaderBookmarkStore(this.documentId);
  String get key => 'reader-bookmarks.v1.$documentId';
  Future<List<ReaderBookmark>> load() async {
    final encoded = (await SharedPreferences.getInstance()).getString(key);
    if (encoded == null) return [];
    final data = jsonDecode(encoded);
    if (data is! Map || data['version'] != 1 || data['items'] is! List) {
      throw const FormatException('书签数据无法读取，原记录已保留。');
    }
    final items = <ReaderBookmark>[];
    final ids = <String>{};
    for (final item in data['items']) {
      if (item is! Map ||
          item['id'] is! String ||
          item['label'] is! String ||
          !ids.add(item['id'])) {
        throw const FormatException('书签记录异常，原记录已保留。');
      }
      items.add(ReaderBookmark(item['id'], item['label']));
    }
    return items;
  }

  Future<void> save(List<ReaderBookmark> items) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode({
        'version': 1,
        'items': [
          for (final item in items)
            {'id': item.locationId, 'label': item.label},
        ],
      }),
    )) {
      throw StateError('书签保存失败');
    }
  }
}
