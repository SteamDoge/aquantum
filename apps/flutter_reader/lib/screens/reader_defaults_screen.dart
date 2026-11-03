// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../formats/document_engine_android.dart';
import '../formats/document_engine_windows.dart';
import '../formats/reader_provider.dart';
import '../formats/reader_provider_preferences.dart';
import '../plugins/plugin_manager.dart';

/// Software settings for format-wide reader selection, independent of typography.
class ReaderDefaultsScreen extends StatefulWidget {
  final PluginManager? plugins;
  const ReaderDefaultsScreen({super.key, this.plugins});
  @override
  State<ReaderDefaultsScreen> createState() => _ReaderDefaultsScreenState();
}

class _ReaderDefaultsScreenState extends State<ReaderDefaultsScreen> {
  static const formats = {
    'Txt': ('TXT', 'text'),
    'Markdown': ('Markdown', 'markdown'),
    'Comic': ('漫画', 'image_page'),
    'Pdf': ('PDF', 'fixed_page'),
    'Epub': ('EPUB', 'document'),
    'Mobi': ('MOBI', 'document'),
    'Azw3': ('AZW3', 'document'),
    'Fb2': ('FB2', 'document'),
  };
  final selected = <String, String?>{};
  final paged = <String, bool>{};
  String? error;
  bool ready = false;
  bool get comicSupported =>
      AndroidDocumentEngine.supported || WindowsDocumentEngine.supported;

  Book book(String format) => Book({
    'id': 'format-default-$format',
    'project': '',
    'title': formats[format]!.$1,
    'format': format,
    'revision': 0,
    'pages': <Map<String, dynamic>>[],
    'capabilities': {
      'surfaces': [formats[format]!.$2, if (format == 'Markdown') 'text'],
    },
  });

  @override
  void initState() {
    super.initState();
    widget.plugins?.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.plugins?.removeListener(changed);
    super.dispose();
  }

  Future<void> load() async {
    try {
      for (final format in formats.keys) {
        selected[format] = await ReaderProviderPreferences.read(book(format));
        paged[format] = await ReaderProviderPreferences.paged(format);
      }
      if (mounted) setState(() => ready = true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> choose(String format) async {
    final sample = book(format);
    final providers = readerProviders(sample, widget.plugins);
    if (providers.length == 1 && !(format == 'Comic' && comicSupported)) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (_) => ReaderProviderPanel(
        book: sample,
        plugins: widget.plugins,
        selected: selected[format],
        foliateSelected:
            selected[format] == ReaderProviderPreferences.foliateComic &&
            comicSupported,
        onSelect: (id) => save(format, id),
        openFoliate: format == 'Comic' && comicSupported
            ? () => save(format, ReaderProviderPreferences.foliateComic)
            : null,
      ),
    );
  }

  Future<void> save(String format, String id) async {
    await ReaderProviderPreferences.save(format, id);
    if (mounted) setState(() => selected[format] = id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('阅读器选择')),
    body: error != null
        ? Center(child: Text(error!))
        : !ready
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('按格式选择阅读器和默认翻页方式，下次打开生效。单文件已有设置优先保留。'),
              ),
              for (final format in formats.keys)
                Builder(
                  builder: (context) {
                    final sample = book(format);
                    final providers = readerProviders(sample, widget.plugins);
                    final foliate = format == 'Comic' && comicSupported;
                    final current =
                        selected[format] ==
                                ReaderProviderPreferences.foliateComic &&
                            foliate
                        ? 'Foliate 漫画阅读'
                        : selectedProvider(
                            sample,
                            widget.plugins,
                            selected[format],
                          ).name;
                    final canChoose = providers.length > 1 || foliate;
                    return Column(
                      children: [
                        ListTile(
                          key: ValueKey('reader-default-$format'),
                          title: Text(formats[format]!.$1),
                          subtitle: Text(current),
                          trailing: canChoose
                              ? const Icon(Icons.chevron_right)
                              : const Text('内置'),
                          onTap: canChoose ? () => choose(format) : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: DropdownButtonFormField<bool>(
                            key: ValueKey(
                              'reader-default-mode-$format-${paged[format]}',
                            ),
                            initialValue: paged[format],
                            decoration: const InputDecoration(
                              labelText: '默认翻页方式',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: true,
                                child: Text('左右翻页'),
                              ),
                              DropdownMenuItem(
                                value: false,
                                child: Text('上下翻页（连续滚动）'),
                              ),
                            ],
                            onChanged: (value) async {
                              if (value == null) return;
                              try {
                                await ReaderProviderPreferences.savePaged(
                                  format,
                                  value,
                                );
                                if (mounted) {
                                  setState(() => paged[format] = value);
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(SnackBar(content: Text('$e')));
                                }
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    );
                  },
                ),
            ],
          ),
  );
}
