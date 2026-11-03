// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

Future<bool> exportPluginBytes(String name, Uint8List bytes) async {
  final path = await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
  if (path == null) return false;
  // Mobile implementations write through their document provider; desktop
  // pickers only select a destination and require the host to write the bytes.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('导出目标不能是链接');
    }
    final staging = File('$path.${DateTime.now().microsecondsSinceEpoch}.part');
    await staging.writeAsBytes(bytes, flush: true);
    if (await file.exists()) {
      await file.rename(
        '$path.${DateTime.now().microsecondsSinceEpoch}.previous',
      );
    }
    await staging.rename(path);
  }
  return true;
}
