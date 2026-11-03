// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/pdf_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

Uint8List makePdf(int count) {
  final objects = <String>[];
  objects.add('<< /Type /Catalog /Pages 2 0 R >>');
  objects.add(
    '<< /Type /Pages /Count $count /Kids [${List.generate(count, (i) => '${4 + i * 2} 0 R').join(' ')}] >>',
  );
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  for (var i = 0; i < count; i++) {
    final stream = 'BT /F1 18 Tf 30 150 Td (Hello PDF page ${i + 1}) Tj ET';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + i * 2} 0 R >>',
    );
    objects.add('<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  }
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(utf8.encode(output.toString()));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'PDFium opens managed copy, renders target region as binary and preserves stable page anchors',
    () async {
      final root = await Directory.systemTemp.createTemp('aq-pdf-core-');
      addTearDown(() => root.delete(recursive: true));
      Pdfrx.cacheDirectoryPath = root.path;
      await pdfrxFlutterInitialize();
      final file = File('${root.path}/original.pdf');
      await file.writeAsBytes(makePdf(1000));
      final api = RustReaderApi('${root.path}/app');
      final catalog = (await api.call('snapshot'))['catalog'];
      final plan = await api.call('preview_import', {
        'target': catalog['inbox'],
        'paths': [file.path],
      });
      final done = await api.call('commit_import', {
        'task': plan['task'],
        'base_revision': plan['base_revision'],
        'target': plan['target'],
        'projects': [],
        'books': [
          for (final b in plan['books'])
            {
              'id': b['id'],
              'title': b['title'],
              'project': b['project'],
              'resources': [for (final r in b['resources']) r['id']],
            },
        ],
        'skip_issues': false,
        'append': null,
      });
      final id = done['books'][0];
      final source = await api.call('document_path', {'book': id});
      // Managed copy remains readable after the external original disappears.
      await file.delete();
      final clock = Stopwatch()..start();
      final document = await PdfDocument.openFile(
        source['path'],
        useProgressiveLoading: true,
      );
      addTearDown(document.dispose);
      expect(document.pages.length, 1000);
      final coldMs = clock.elapsedMilliseconds;
      await document.reloadPages(pageNumbersToReload: [1000]);
      final target = await document.pages.last.ensureLoaded();
      final image = await target.render(
        x: 16,
        y: 16,
        width: 64,
        height: 48,
        fullWidth: 1200,
        fullHeight: 800,
      );
      expect(image, isNotNull);
      expect(image!.pixels.length, 64 * 48 * 4);
      image.dispose();
      final renderMs = clock.elapsedMilliseconds - coldMs;
      final bound = Book(
        Map<String, dynamic>.from(
          await api.call('bind_pdf_pages', {
            'book': id,
            'resource': source['resource'],
            'revision': source['revision'],
            'count': document.pages.length,
          }),
        ),
      );
      expect(bound.pages.length, 1000);
      expect(
        (await api.call('effective_direction', {'book': id}))['value'],
        'TopToBottom',
      );
      await api.call('set_project_direction', {
        'project': bound.project,
        'format': 'Pdf',
        'direction': 'RightToLeft',
      });
      expect(
        (await api.call('effective_direction', {'book': id}))['value'],
        'TopToBottom',
      );
      await api.call('set_page_crop', {
        'book': id,
        'page': bound.pages[999]['id'],
        'left': 0.2,
        'right': 0.1,
        'top': 0.1,
        'bottom': 0.2,
      });
      final restoredCrop = await RustReaderApi(
        '${root.path}/app',
      ).call('effective_crop', {'book': id, 'page': bound.pages[999]['id']});
      expect(restoredCrop['left'], closeTo(0.2, 0.0001));
      expect(await File(source['path']).readAsBytes(), makePdf(1000));
      expect(bound.bytes, await File(source['path']).length());
      await api.call('save_progress', {'book': id, 'index': 999});
      await api.call('add_note', {
        'book': id,
        'index': 999,
        'text': 'last page note',
      });
      final again = await api.call('bind_pdf_pages', {
        'book': id,
        'resource': source['resource'],
        'revision': bound.revision,
        'count': 1000,
      });
      expect(again['pages'][999]['id'], bound.pages[999]['id']);
      final state = await RustReaderApi('${root.path}/app').call('snapshot');
      expect(
        state['catalog']['progress'][0]['location']['Page']['page'],
        bound.pages.last['id'],
      );
      final text = await target.loadText();
      expect(text!.fullText, contains('Hello PDF page 1000'));
      final session = PdfEngineSession(document, bound);
      final region = await session.region(999, {
        'left': 0.2,
        'right': 0.1,
        'top': 0.1,
        'bottom': 0.2,
      }, 300);
      expect(region, isNotNull);
      expect(region!.width, 300);
      expect(region.height, 200);
      region.dispose();
      final hits = await session.search('Hello PDF');
      expect(hits.length, 100);
      expect(session.highlights.length, 100);
      final output = Platform.environment['AQ_PDF_MEASUREMENTS'];
      if (output != null) {
        await File(output).writeAsString(
          jsonEncode({
            'sample': 'generated 1000-page vector PDF',
            'coldOpenMs': coldMs,
            'targetRegionRenderMs': renderMs,
            'regionBytes': 64 * 48 * 4,
            'pages': 1000,
            'scope':
                'automated engine test; not device P95 or memory acceptance',
          }),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
