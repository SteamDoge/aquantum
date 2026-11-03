// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'plugin_api.dart';

/// One native result surface for every renderer; null means no visible result.
Future<void> showPluginResult(
  BuildContext context,
  PluginAction action,
  String? result,
) async {
  if (!context.mounted || result == null) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(action.name),
      content: SingleChildScrollView(child: SelectableText(result)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
