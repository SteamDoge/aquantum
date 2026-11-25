// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.

import '../l10n/l10n.dart';

/// Shows text produced by the Rust core in the interface language.
///
/// The core writes Simplified Chinese. A message the catalog knows is looked
/// up whole; an error wrapped by the core ("无效操作：…") or a reading
/// direction description is split so the wrapper and its static part both
/// translate. Text with other dynamic parts is shown unchanged.
String coreText(Object? message) {
  final text = '$message';
  if (uiLanguage == UiLanguage.zhHans) return text;
  final whole = tr(text);
  if (whole != text) return whole;
  for (final (pattern, translate) in _wrapped) {
    final match = pattern.firstMatch(text);
    if (match != null) return translate(match);
  }
  return text;
}

// l10n-keep marks the patterns: they match the core's own Chinese wording.
final List<(RegExp, String Function(RegExpMatch))> _wrapped = [
  (
    RegExp(r'^无效操作：(.*)$', dotAll: true), // l10n-keep
    (m) => tr('无效操作：{detail}', {'detail': coreText(m[1])}),
  ),
  (
    RegExp(r'^存储错误：(.*)$', dotAll: true), // l10n-keep
    (m) => tr('存储错误：{detail}', {'detail': coreText(m[1])}),
  ),
  (
    RegExp(r'^版本冲突：(.*)；请刷新后重试$', dotAll: true), // l10n-keep
    (m) => tr('版本冲突：{detail}；请刷新后重试', {'detail': coreText(m[1])}),
  ),
  (
    RegExp(r'^暂不支持：(.*)$', dotAll: true), // l10n-keep
    (m) => tr('暂不支持：{detail}', {'detail': coreText(m[1])}),
  ),
  (
    RegExp(r'^数据版本 (\d+) 不受支持，请使用兼容版本打开$'), // l10n-keep
    (m) => tr('数据版本 {version} 不受支持，请使用兼容版本打开', {'version': m[1]}),
  ),
  (
    RegExp(r'^找不到(.+?)：(.*)$', dotAll: true), // l10n-keep
    (m) => switch (m[1]) {
      '项目' => tr('找不到项目：{id}', {'id': m[2]}), // l10n-keep
      '书籍' => tr('找不到书籍：{id}', {'id': m[2]}), // l10n-keep
      '页面' => tr('找不到页面：{id}', {'id': m[2]}), // l10n-keep
      '操作记录' => tr('找不到操作记录：{id}', {'id': m[2]}), // l10n-keep
      _ => tr('找不到{item}：{id}', {'item': m[1], 'id': m[2]}),
    },
  ),
  (
    RegExp(r'^(.+)（本文件自定义）$'), // l10n-keep
    (m) => tr('{direction}（本文件自定义）', {'direction': coreText(m[1])}),
  ),
  (
    RegExp(r'^默认（(.+)，继承自：全局默认）$'), // l10n-keep
    (m) => tr('默认（{direction}，继承自：全局默认）', {'direction': coreText(m[1])}),
  ),
  (
    RegExp(r'^默认（(.+)，继承自：(.+)）$'), // l10n-keep
    (m) => tr('默认（{direction}，继承自：{project}）', {
      'direction': coreText(m[1]),
      'project': m[2],
    }),
  ),
  (
    RegExp(r'^格式默认（(.+)）$'), // l10n-keep
    (m) => tr('格式默认（{direction}）', {'direction': coreText(m[1])}),
  ),
];
