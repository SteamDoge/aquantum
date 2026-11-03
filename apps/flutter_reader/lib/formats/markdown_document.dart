// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:markdown/markdown.dart' as md;

class MarkdownBlock {
  final String source, node, label;
  final int paragraph, level;
  final List<String> tasks;
  MarkdownBlock(
    this.source,
    this.node,
    this.paragraph,
    this.label,
    this.level,
    this.tasks,
  );
}

class MarkdownDocument {
  final String source;
  final List<MarkdownBlock> blocks;
  MarkdownDocument._(this.source, this.blocks);
  factory MarkdownDocument.parse(String source) {
    final lines = const LineSplitter().convert(source);
    final parsedLines = lines.map(md.Line.new).toList();
    final ranges = <md.Node, (int, int)>{};
    void capture(md.BlockParser parser, md.Node node, int start, int end) {
      if (identical(parser.lines, parsedLines)) ranges[node] = (start, end);
    }

    final syntaxes = <md.BlockSyntax>[
      _Fenced(capture),
      _Table(capture),
      _Unordered(capture),
      _Ordered(capture),
      const md.EmptyBlockSyntax(),
      _Html(capture),
      _Setext(capture),
      _Header(capture),
      _Code(capture),
      _Quote(capture),
      _Rule(capture),
      const md.LinkReferenceDefinitionSyntax(),
      _Paragraph(capture),
    ];
    final document = md.Document(
      blockSyntaxes: syntaxes,
      withDefaultBlockSyntaxes: false,
      extensionSet: md.ExtensionSet(
        [],
        md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
      ),
      encodeHtml: false,
    );
    final nodes = document.parseLineList(parsedLines);
    final paragraphStarts = <int>[];
    var offset = 0;
    for (final raw in source.split('\n\n')) {
      if (raw.trim().isNotEmpty) paragraphStarts.add(offset);
      offset += raw.length + 2;
    }
    final lineOffsets = <int>[0];
    for (final line in lines) {
      lineOffsets.add(lineOffsets.last + line.length + 1);
    }
    final blocks = <MarkdownBlock>[];
    var lastEnd = 0;
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final range =
          ranges[node] ?? (lastEnd, (lastEnd + 1).clamp(0, lines.length));
      final start = range.$1.clamp(0, lines.length);
      final end = range.$2.clamp(start, lines.length);
      lastEnd = end;
      final text = lines.sublist(start, end).join('\n');
      if (text.trim().isEmpty) continue;
      final digest = sha256.convert(utf8.encode(text)).toString();
      final identity = 'block:$index:$digest';
      final tasks = <String>[];
      void walk(md.Node n, String path) {
        if (n is! md.Element) return;
        final children = n.children ?? [];
        for (var i = 0; i < children.length; i++) {
          walk(children[i], '$path.$i');
        }
        if (n.tag == 'li' &&
            children.isNotEmpty &&
            children.first is md.Element) {
          final first = children.first as md.Element;
          if (first.tag == 'input' && first.attributes['type'] == 'checkbox') {
            tasks.add('$identity:task:$path.0');
          }
        }
      }

      walk(node, '0');
      final details = RegExp(
        r'^\s*<details(?:\s[^>]*)?>\s*(?:<summary>[\s\S]*?</summary>)?([\s\S]*?)</details>\s*$',
        caseSensitive: false,
      ).firstMatch(text);
      if (details != null) {
        final children = md.Document(
          extensionSet: md.ExtensionSet.gitHubFlavored,
        ).parse(details.group(1) ?? '');
        for (var j = 0; j < children.length; j++) {
          walk(children[j], 'details.$j');
        }
      }

      final sourceOffset = lineOffsets[start];
      var paragraph = 0;
      for (var i = 0; i < paragraphStarts.length; i++) {
        if (paragraphStarts[i] <= sourceOffset) paragraph = i;
      }
      final tag = node is md.Element ? node.tag : '';
      final level = RegExp(r'^h[1-6]$').hasMatch(tag)
          ? int.parse(tag.substring(1))
          : 0;
      blocks.add(
        MarkdownBlock(
          text,
          identity,
          paragraph,
          node.textContent,
          level,
          tasks,
        ),
      );
    }
    return MarkdownDocument._(source, List.unmodifiable(blocks));
  }
  int blockForParagraph(int paragraph) {
    var found = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].paragraph <= paragraph) found = i;
    }
    return found;
  }
}

typedef _Capture = void Function(md.BlockParser, md.Node, int, int);
mixin _Tracked on md.BlockSyntax {
  late _Capture capture;
  @override
  md.Node? parse(md.BlockParser parser) {
    final start = parser.lines.indexOf(parser.linesToConsume.first);
    final node = super.parse(parser);
    final end = parser.isDone
        ? parser.lines.length
        : parser.lines.indexOf(parser.current);
    if (node != null) capture(parser, node, start, end);
    return node;
  }
}

class _Fenced extends md.FencedCodeBlockSyntax with _TrackedRequired {
  _Fenced(_Capture value) {
    capture = value;
  }
}

class _Table extends md.TableSyntax with _Tracked {
  _Table(_Capture value) {
    capture = value;
  }
}

class _Unordered extends md.UnorderedListWithCheckboxSyntax
    with _TrackedRequired {
  _Unordered(_Capture value) {
    capture = value;
  }
}

class _Ordered extends md.OrderedListWithCheckboxSyntax with _TrackedRequired {
  _Ordered(_Capture value) {
    capture = value;
  }
}

class _Setext extends md.SetextHeaderSyntax with _Tracked {
  _Setext(_Capture value) {
    capture = value;
  }
}

class _Header extends md.HeaderSyntax with _TrackedRequired {
  _Header(_Capture value) {
    capture = value;
  }
}

class _Code extends md.CodeBlockSyntax with _TrackedRequired {
  _Code(_Capture value) {
    capture = value;
  }
}

class _Quote extends md.BlockquoteSyntax with _TrackedRequired {
  _Quote(_Capture value) {
    capture = value;
  }
}

class _Rule extends md.HorizontalRuleSyntax with _TrackedRequired {
  _Rule(_Capture value) {
    capture = value;
  }
}

class _Paragraph extends md.ParagraphSyntax with _Tracked {
  _Paragraph(_Capture value) {
    capture = value;
  }
}

mixin _TrackedRequired on md.BlockSyntax {
  late _Capture capture;
  @override
  md.Node parse(md.BlockParser parser) {
    final start = parser.lines.indexOf(parser.linesToConsume.first);
    final node = super.parse(parser)!;
    final end = parser.isDone
        ? parser.lines.length
        : parser.lines.indexOf(parser.current);
    capture(parser, node, start, end);
    return node;
  }
}

class _Html extends md.HtmlBlockSyntax with _TrackedRequired {
  _Html(_Capture value) {
    capture = value;
  }
}
