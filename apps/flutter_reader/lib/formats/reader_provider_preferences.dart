// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:shared_preferences/shared_preferences.dart';
import '../data/models.dart';

/// Global format choices override legacy per-book choices without deleting them.
class ReaderProviderPreferences {
  static String key(String format) => 'reader-provider.v1.$format';
  static const foliateComic = 'core.foliate_comic';

  static bool builtInPaged(String format) =>
      !{'Markdown', 'Pdf', 'Comic'}.contains(format);
  static Future<bool> paged(String format) async {
    final value = (await SharedPreferences.getInstance()).get(
      'reader-mode.v1.$format',
    );
    return value is bool ? value : builtInPaged(format);
  }

  static Future<void> savePaged(String format, bool paged) async {
    if (!await (await SharedPreferences.getInstance()).setBool(
      'reader-mode.v1.$format',
      paged,
    )) {
      throw StateError('默认翻页方式保存失败');
    }
  }

  static Future<String?> read(Book book) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key(book.format)) ??
        prefs.getString('reader-format.v1.${book.id}');
  }

  static Future<void> save(String format, String id) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key(format),
      id,
    )) {
      throw StateError('阅读器选择保存失败');
    }
  }
}
