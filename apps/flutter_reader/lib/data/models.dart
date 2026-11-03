// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
class Project {
  final String id;
  final String? parent;
  final String name;
  final int color;
  Project(Map<String, dynamic> json)
    : id = json['id'],
      parent = json['parent'],
      name = json['name'],
      color = json['color'] ?? 0;
}

class BookCapabilities {
  final Set<String> surfaces;
  const BookCapabilities(this.surfaces);
  factory BookCapabilities.parse(dynamic json, String legacyFormat) {
    if (json is Map && json['surfaces'] is List) {
      return BookCapabilities(
        Set.unmodifiable((json['surfaces'] as List).whereType<String>()),
      );
    }
    // Compatibility with older bridge snapshots and explicitly injected test APIs.
    return BookCapabilities(switch (legacyFormat) {
      'Comic' => const {'image_page'},
      'Pdf' => const {'fixed_page'},
      'Markdown' => const {'markdown', 'text'},
      'Txt' => const {'text'},
      _ => const {},
    });
  }
  bool get imagePages => surfaces.contains('image_page');
  bool get fixedPages => surfaces.contains('fixed_page');
  bool get markdown => surfaces.contains('markdown');
  bool get text => surfaces.contains('text');
  bool get document => surfaces.contains('document');

  /// Unit the position index counts, as declared by the core.
  String get unit => document
      ? 'anchor'
      : (imagePages || fixedPages)
      ? 'page'
      : 'paragraph';
}

class Book {
  final String id, project, title, format;
  final int revision;
  final bool archived;
  final Map<String, dynamic> metadata;
  final List<Map<String, dynamic>> pages;
  final BookCapabilities capabilities;
  Book(Map<String, dynamic> json, {dynamic capabilities})
    : id = json['id'],
      project = json['project'],
      title = json['title'],
      format = json['format'],
      revision = json['revision'],
      archived = json['archived'] == true,
      metadata = Map.unmodifiable(
        json['metadata'] as Map? ?? const <String, dynamic>{},
      ),
      capabilities = BookCapabilities.parse(
        capabilities ?? json['capabilities'],
        json['format'],
      ),
      pages = List.unmodifiable(
        (json['pages'] as List).map(
          (p) => Map<String, dynamic>.unmodifiable(p),
        ),
      );
  bool get isComic => capabilities.imagePages;
  bool get isPdf => capabilities.fixedPages;
  bool get isMarkdown => capabilities.markdown;

  /// EPUB/MOBI/AZW3/FB2: laid out by the bundled browser engine, anchored by CFI.
  bool get isDocument => capabilities.document;
  String get label => switch (format) {
    'Comic' => '漫画',
    'Markdown' => 'Markdown',
    'Pdf' => 'PDF',
    'Epub' => 'EPUB',
    'Mobi' => 'MOBI',
    'Azw3' => 'AZW3',
    'Fb2' => 'FB2',
    _ => 'TXT',
  };
  int get bytes {
    final seen = <String>{};
    return pages.fold(0, (sum, p) {
      final id = p['resource']['id'] as String?;
      return sum +
          (id == null || seen.add(id) ? p['resource']['bytes'] as int : 0);
    });
  }
}

class LibrarySnapshot {
  final Map<String, dynamic> raw;
  late final Map<String, dynamic> catalog = raw['catalog'];
  late final List<Project> projects = List.unmodifiable(
    (catalog['projects'] as List).map(
      (p) => Project(p['id'] == inbox ? {...p, 'name': '资料库'} : p),
    ),
  );
  late final List<Book> allBooks = List.unmodifiable(
    (catalog['books'] as List).map(
      (b) => Book(b, capabilities: raw['book_capabilities']?[b['id']]),
    ),
  );
  late final List<Book> books = List.unmodifiable(
    allBooks.where((b) => !b.archived),
  );
  LibrarySnapshot(Map<String, dynamic> input)
    : raw = _freeze(input) as Map<String, dynamic>;
  String get inbox => catalog['inbox'];
  List<Book> booksIn(String project) =>
      books.where((b) => b.project == project).toList();
  List<Project> children(String parent) =>
      projects.where((p) => p.parent == parent).toList();
  Project project(String id) => projects.firstWhere((p) => p.id == id);
  int position(Book book) {
    final progress = (catalog['progress'] as List).where(
      (p) => p['book'] == book.id && p['actor'] == catalog['actor'],
    );
    if (progress.isEmpty) return 0;
    final location = progress.first['location'] as Map;
    if (location.containsKey('Paragraph')) {
      return location['Paragraph']['index'] as int;
    }
    if (location.containsKey('Document')) {
      return documentPercent(book) ?? 0;
    }
    final page = location['Page']['page'];
    final index = book.pages.indexWhere((p) => p['id'] == page);
    return index < 0 ? 0 : index;
  }

  /// How far the reader is through a document, as a percentage.
  ///
  /// A CFI is the only permanent document position; the dashboard shows a
  /// percentage because a reflowable book has no fixed page count until it is
  /// laid out. `null` means the book is not a document.
  int? documentPercent(Book book) {
    if (!book.isDocument) return null;
    for (final entry in catalog['progress'] as List) {
      final row = entry as Map;
      if (row['book'] != book.id || row['actor'] != catalog['actor']) continue;
      final document = (row['location'] as Map)['Document'];
      if (document is! Map) return 0;
      final saved = document['progress'];
      return saved is int ? saved.clamp(0, 100) : 0;
    }
    return 0;
  }

  double? contentFraction(Book book) {
    for (final entry in catalog['progress'] as List) {
      if (entry['book'] != book.id || entry['actor'] != catalog['actor']) {
        continue;
      }
      final value = entry['content_progress'];
      if (value is num) return (value / 10000).clamp(0.0, 1.0);
    }
    return null;
  }

  List<Project> ancestors(String id) {
    final result = <Project>[];
    var next = project(id);
    final visited = <String>{};
    while (visited.add(next.id)) {
      result.insert(0, next);
      if (next.parent == null) break;
      next = project(next.parent!);
    }
    return result;
  }
}

String sizeLabel(num bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freeze(v))),
    );
  }
  if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
  return value;
}
