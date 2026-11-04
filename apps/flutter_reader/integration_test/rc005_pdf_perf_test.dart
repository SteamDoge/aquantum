// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/formats/pdf_engine.dart';

num p95(List<num> values) {
  final copy = [...values]..sort();
  return copy[((copy.length - 1) * .95).ceil()];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'profile synthetic PDF classes and native viewport during indexing',
    (tester) async {
      expect(
        kProfileMode,
        isTrue,
        reason: 'Performance must run in profile mode',
      );
      final fixtures = Directory(Platform.environment['AQ_PDF_FIXTURES']!);
      final manifest = jsonDecode(
        await File('${fixtures.path}/manifest.json').readAsString(),
      );
      final root = await Directory(
        '${fixtures.path}/runs/${DateTime.now().millisecondsSinceEpoch}',
      ).create(recursive: true);
      final api = RustReaderApi('${root.path}/app');
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      await pdfrxFlutterInitialize();
      final results = <Map<String, dynamic>>[];
      for (final sample in manifest['fixtures']) {
        final original = '${fixtures.path}/${sample['file']}';
        final timer = Stopwatch()..start();
        final plan = await api.call('preview_import', {
          'target': inbox,
          'paths': [original],
        });
        final imported = await api.call('commit_import', {
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
        final importMs = timer.elapsedMicroseconds / 1000;
        final id = imported['books'][0];
        final source = await api.call('document_path', {'book': id});
        Future<PdfDocument> open() => PdfDocument.openFile(
          source['path'],
          useProgressiveLoading: true,
          passwordProvider: () async => sample['password'],
        );
        final opens = <num>[], renders = <num>[];
        var rss = ProcessInfo.currentRss;
        for (var round = 0; round < 20; round++) {
          timer.reset();
          final doc = await open();
          await doc.reloadPages(pageNumbersToReload: [doc.pages.length]);
          opens.add(timer.elapsedMicroseconds / 1000);
          timer.reset();
          final page = await doc.pages.last.ensureLoaded();
          final pixels = await page.render(
            x: 0,
            y: 0,
            width: 512,
            height: 512,
            fullWidth: page.width * 3,
            fullHeight: page.height * 3,
          );
          expect(pixels, isNotNull);
          pixels!.dispose();
          renders.add(timer.elapsedMicroseconds / 1000);
          rss = rss > ProcessInfo.currentRss ? rss : ProcessInfo.currentRss;
          await doc.dispose();
        }
        final doc = await open();
        final book = Book(
          Map<String, dynamic>.from(
            await api.call('bind_pdf_pages', {
              'book': id,
              'resource': source['resource'],
              'revision': source['revision'],
              'count': doc.pages.length,
            }),
          ),
        );
        final engine = PdfEngineSession(doc, book);
        final controller = PdfViewerController();
        final frames = <FrameTiming>[];
        void timings(List<FrameTiming> data) => frames.addAll(data);
        WidgetsBinding.instance.addTimingsCallback(timings);
        await tester.pumpWidget(
          MaterialApp(
            home: PdfViewer(
              PdfDocumentRefDirect(doc, autoDispose: false),
              controller: controller,
              params: const PdfViewerParams(
                maxImageBytesCachedOnMemory: 64 * 1024 * 1024,
                onePassRenderingSizeThreshold: 1536,
                horizontalCacheExtent: .25,
                verticalCacheExtent: .5,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        frames.clear();
        timer.reset();
        final search = engine.search('Hello');
        final responseTimer = Stopwatch()..start();
        final region = await engine.region(doc.pages.length - 1, {}, 512);
        region?.dispose();
        final responseMs = responseTimer.elapsedMicroseconds / 1000;
        for (var i = 0; i < 60; i++) {
          if (controller.isReady) {
            controller.goToPage(pageNumber: (i % doc.pages.length) + 1);
          }
          await tester.pump(const Duration(milliseconds: 16));
        }
        await search;
        final indexMs = timer.elapsedMicroseconds / 1000;
        await tester.pump(const Duration(milliseconds: 200));
        WidgetsBinding.instance.removeTimingsCallback(timings);
        expect(frames, isNotEmpty);
        rss = rss > ProcessInfo.currentRss ? rss : ProcessInfo.currentRss;
        results.add({
          'kind': sample['kind'],
          'bytes': sample['bytes'],
          'pages': sample['pages'],
          'synthetic': true,
          'rounds': 20,
          'importMs': importMs,
          'firstOpenTargetMs': opens.first,
          'openTargetP95Ms': p95(opens),
          'region512P95Ms': p95(renders),
          'sampledPeakRssBytes': rss,
          'searchWithNavigationMs': indexMs,
          'visibleRegionDuringSearchMs': responseMs,
          'frames': frames.length,
          'buildP95Ms': p95(
            frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(),
          ),
          'rasterP95Ms': p95(
            frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList(),
          ),
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await engine.close();
      }
      binding.reportData = {
        'platform': Platform.operatingSystem,
        'mode': 'profile',
        'samples': results,
        'scope':
            'Synthetic local samples, OS cache retained; sampled process RSS includes Flutter. This is not ARM64 physical-device or production-library P95.',
      };
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
