// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:aquantum_reader/formats/document_engine.dart';
import 'package:aquantum_reader/formats/document_engine_android.dart';
import 'package:aquantum_reader/formats/document_engine_channel.dart';
import 'package:aquantum_reader/formats/document_engine_windows.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'qa_storage.dart';

Uint8List epub() {
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '''<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  );
  add(
    'book.opf',
    '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">rc006-smoke</dc:identifier><dc:title>RC006 EPUB</dc:title><dc:language>zh</dc:language></metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine></package>''',
  );
  add(
    'nav.xhtml',
    '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="text.xhtml">测试正文</a></li></ol></nav></body></html>''',
  );
  add(
    'text.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title/></head><body><a id="self-closing"/>${List.generate(40, (i) => '<p>RC006 测试正文 $i，阅读器需要显示文字并保留稳定位置。</p>').join()}</body></html>',
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bundled Foliate opens EPUB, FB2 and managed comic in native host', (
    tester,
  ) async {
    await configureQaStorage();
    final DocumentEngine engine =
        await tester.runAsync(
              () async => Platform.isAndroid
                  ? AndroidDocumentEngine.create()
                  : WindowsDocumentEngine.create().timeout(
                      const Duration(seconds: 30),
                    ),
            )
            as DocumentEngine;
    debugPrint('RC006_HOST: created');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Builder(builder: engine.build)),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    try {
      await tester.runAsync(() async {
        await engine.ready.timeout(const Duration(seconds: 30));
        debugPrint('RC006_HOST: ready');
        final info = await engine.open(
          bytes: epub(),
          name: 'smoke.epub',
          format: 'Epub',
        );
        expect(info.title, 'RC006 EPUB');
        debugPrint('RC006_HOST: EPUB opened');
        expect(await engine.anchor(), isNotEmpty);
        await engine.style({'fontSize': 24, 'theme': 'dark'});
        await engine.turn(1);
        final anchor = await engine.anchor();
        expect(anchor, isNotEmpty);
        await engine.goToFraction(.5);
        await engine.goTo(anchor: anchor);
        final fb2 = utf8.encode(
          '''<?xml version="1.0" encoding="UTF-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><genre>prose</genre><author><first-name>QA</first-name><last-name>RC006</last-name></author><book-title>RC006 FB2</book-title><lang>zh</lang></title-info></description><body><section><title><p>测试</p></title><p>这是正式宿主中的 FB2 正文。</p></section></body></FictionBook>''',
        );
        expect(
          (await engine.open(
            bytes: Uint8List.fromList(fb2),
            name: 'smoke.fb2',
            format: 'Fb2',
          )).title,
          'RC006 FB2',
        );
        debugPrint('RC006_HOST: FB2 opened');
        expect(await engine.anchor(), isNotEmpty);
        await (engine as ChannelDocumentEngine).openImages(
          name: '漫画',
          pages: ['stable-page-1'],
          readImage: (_) async =>
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0S8AAAAASUVORK5CYII=',
        );
        expect(await engine.anchor(), isNotEmpty);
      });
    } finally {
      await tester.runAsync(engine.close);
      await tester.pumpWidget(const SizedBox());
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
