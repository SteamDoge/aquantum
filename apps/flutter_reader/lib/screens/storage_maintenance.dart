// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/backup_preferences.dart';
import '../data/models.dart';
import '../data/picked_paths.dart';
import '../data/document_io.dart';
import '../data/reader_api.dart';
import 'import_preview.dart';
import 'storage_cleanup.dart';

String taskKindLabel(dynamic kind) =>
    const {
      'import': '导入',
      'cleanup': '手动清理',
      'backup': '备份',
      'restore': '恢复',
    }[kind] ??
    '存储任务';
String taskPhaseLabel(dynamic phase) =>
    const {
      'ready': '等待执行',
      'preview': '等待确认',
      'completed': '已完成',
      'stopped': '已暂停或失败',
      'discarded': '已放弃',
      'discarding': '放弃中，待完成',
      'error': '需要处理',
      'staging': '准备文件',
      'packing': '写入备份',
      'checking': '校验文件',
      'copying': '复制文件',
      'pending': '等待执行',
      'cancelled': '已取消，待继续',
    }[phase] ??
    '处理中';

class StorageMaintenanceScreen extends StatefulWidget {
  final ReaderApi api;
  final Future<void> Function(Map<String, dynamic>)? onRestored;
  final Future<void> Function()? onRollback;
  const StorageMaintenanceScreen({
    super.key,
    required this.api,
    this.onRestored,
    this.onRollback,
  });
  @override
  State<StorageMaintenanceScreen> createState() =>
      _StorageMaintenanceScreenState();
}

class _StorageMaintenanceScreenState extends State<StorageMaintenanceScreen> {
  Map<String, dynamic>? overview, progress;
  List<dynamic> tasks = [];
  List<Map<String, dynamic>> documentOutputs = [];
  Map<String, dynamic>? documentStaging;
  bool busy = false;
  String? error, message, jobKind, jobTask;
  Timer? poll;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final data = Map<String, dynamic>.from(
        await widget.api.call('storage_overview'),
      );
      final list = await widget.api.call('storage_tasks') as List;
      final outputs = await pendingDocumentOutputs();
      final retained = await retainedDocumentIo();
      if (mounted) {
        setState(() {
          overview = data;
          tasks = list.reversed.toList();
          documentOutputs = outputs;
          documentStaging = retained;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      poll?.cancel();
      if (mounted) {
        setState(() {
          busy = false;
          jobKind = null;
          jobTask = null;
          progress = null;
        });
        await refresh();
      }
    }
  }

  Future<dynamic> job(
    String kind,
    String task,
    Future<dynamic> Function() action,
  ) async {
    setState(() {
      jobKind = kind;
      jobTask = task;
      progress = null;
    });
    poll?.cancel();
    poll = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      try {
        final value = Map<String, dynamic>.from(
          await widget.api.call('task_status', {'kind': kind, 'task': task}),
        );
        if (mounted) setState(() => progress = value);
      } catch (_) {
        /* A job may still be writing its first complete state. */
      }
    });
    try {
      return await action();
    } finally {
      poll?.cancel();
    }
  }

  Future<void> cancel() async {
    if (jobKind == null || jobTask == null) return;
    try {
      await widget.api.call('task_cancel', {'kind': jobKind, 'task': jobTask});
      if (mounted) setState(() => message = '已请求暂停，已完成文件与失败残留保留。');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;
  Future<({DocumentOutput directory, String name})?> backupDestination() async {
    final directory = await pickDocumentOutput('选择备份保存目录');
    if (directory == null) return null;
    return (
      directory: directory,
      name: 'AQuantum-${DateTime.now().millisecondsSinceEpoch}.aqb',
    );
  }

  Future<void> backup({String? task}) async {
    final destination = await backupDestination();
    if (destination == null || !mounted) return;
    await run(() async {
      String id;
      if (task == null) {
        final plan = await widget.api.call('backup_prepare', {
          'device_preferences': await preferenceSnapshot(),
        });
        id = plan['task'];
        if (!mounted) return;
        if (!await confirm(
          '创建资料库备份？',
          '包含 ${plan['files']} 个文件，约 ${sizeLabel(plan['bytes'] as num)}。包含正文、历史、笔记、进度、阅读设置、插件和导入暂存。\n\n同名目标不会覆盖；扫描失败或源文件变化时不会报告备份成功。',
          '开始备份',
        )) {
          return;
        }
      } else {
        id = task;
        await widget.api.call('task_resume', {'kind': 'backup', 'task': id});
      }
      await job(
        'backup',
        id,
        () => widget.api.call('backup_run', {
          'task': id,
          'destination': destination.directory.file(destination.name),
        }),
      );
      final published = await destination.directory.publish(destination.name);
      if (mounted) {
        setState(() => message = '备份已校验并保存：$published');
      }
    });
  }

  Future<void> restore({String? task}) async {
    if (widget.onRestored == null) {
      setState(() => error = '当前运行入口没有配置资料库切换。');
      return;
    }
    String? source;
    if (task == null) {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['aqb', 'zip'],
      );
      if (selected == null || selected.files.isEmpty) return;
      source = selected.files.single.path;
      if (source == null) {
        if (mounted) setState(() => error = '无法取得备份路径，请先保存到设备文件后重选。');
        return;
      }
      source = await pickedCachePath(source);
    }
    await run(() async {
      final id =
          task ??
          (await widget.api.call('restore_prepare', {'source': source}))['task']
              as String;
      if (task != null) {
        await widget.api.call('task_resume', {'kind': 'restore', 'task': id});
      }
      final result = Map<String, dynamic>.from(
        await job(
          'restore',
          id,
          () => widget.api.call('restore_run', {'task': id}),
        ),
      );
      if (!mounted) return;
      final accepted = await confirm(
        '使用已恢复的资料库？',
        '已校验 ${result['books']} 项内容、${result['notes']} 条笔记。恢复到独立副本，原资料库和当前设置快照保留，可从这里回退。\n\n${result['missing_external_sources']} 个任务来源需要重新选择。阅读设置与插件数据将恢复；插件需要重新授权启用。',
        '切换到恢复副本',
      );
      if (!accepted) return;
      await widget.onRestored!(result);
      await returnToLibrary();
    });
  }

  Future<void> returnToLibrary() async {
    if (!mounted) return;
    // PopScope must see the completed state before we request navigation.
    setState(() => busy = false);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> cleanup({String? task}) async {
    await run(() async {
      final id =
          task ?? (await widget.api.call('cleanup_preview'))['task'] as String;
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => StorageCleanupScreen(api: widget.api, task: id),
        ),
      );
    });
  }

  /// Continuing is always an explicit user action, never an automatic restart.
  /// A cancelled task says so in its own words before anything runs again.
  Future<void> resume(Map<String, dynamic> task) async {
    if (task['phase'] == 'cancelled' &&
        !await confirm(
          '继续${taskKindLabel(task['kind'])}任务？',
          '该任务此前被取消。继续会从已保留的进度接着执行，已校验的部分不会重做；原件和目标不会被覆盖。',
          '继续任务',
        )) {
      return;
    }
    switch (task['kind']) {
      case 'backup':
        await backup(task: task['task']);
      case 'restore':
        await restore(task: task['task']);
      case 'cleanup':
        await cleanup(task: task['task']);
      case 'import':
        await run(() async {
          final plan = Map<String, dynamic>.from(
            await widget.api.call('import_plan', {'task': task['task']}),
          );
          if (mounted) {
            await Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ImportPreviewScreen(api: widget.api, plan: plan),
              ),
            );
          }
        });
    }
  }

  /// Giving up one task is explicit and scoped: its own staging is removed and
  /// a receipt is kept, while published files and every other task are left
  /// alone. Nothing here is ever swept automatically.
  Future<void> discard(Map<String, dynamic> task) async {
    final kind = task["kind"];
    final label = taskKindLabel(kind);
    if (kind == "import") {
      if (!await confirm(
        "放弃此导入任务？",
        "停止对此任务继续恢复。原计划和暂存仍保留，仅释放未引用副本的任务保护；当前正文和历史引用仍受保护。之后可重新选择原文件导入。",
        "放弃恢复",
      )) {
        return;
      }
      await run(() async {
        await widget.api.call("discard_import_task", {"task": task["task"]});
      });
      return;
    }
    if (!await confirm(
      "放弃$label任务？",
      "只删除这个任务自己的暂存与半成品，已发布的文件和其他任务都不受影响；放弃后不能继续，需要时请重新创建任务。",
      "放弃任务",
    )) {
      return;
    }
    await run(() async {
      await widget.api.call("task_discard", {
        "kind": kind,
        "task": task["task"],
      });
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = overview?['usage'] as Map?;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('存储维护与备份'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: busy ? null : refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(message!),
              ),
            if (progress != null)
              ListTile(
                title: Text(
                  '${taskPhaseLabel(progress!['phase'])} · ${progress!['completed']} / ${progress!['total']}',
                ),
                subtitle: Text(taskKindLabel(jobKind)),
              ),
            for (final output in documentOutputs)
              ListTile(
                title: Text('待完成保存 · ${output['name']}'),
                subtitle: Text(
                  '${sizeLabel(output['bytes'] as num)} · 已生成文件保留，选择新目录继续保存',
                ),
                trailing: OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                          final uri = await retryDocumentOutput(
                            output['path'] as String,
                          );
                          if (uri != null && mounted) {
                            setState(() => message = '已校验并保存：$uri');
                          }
                        }),
                  child: const Text('继续保存'),
                ),
              ),
            if (busy && jobKind != null)
              OutlinedButton.icon(
                onPressed: cancel,
                icon: const Icon(Icons.pause),
                label: const Text('暂停任务并保留文件'),
              ),
            if (usage != null) ...[
              if (documentStaging != null)
                ListTile(
                  title: Text(
                    '授权文件暂存 ${sizeLabel(documentStaging!['bytes'] as num)}',
                  ),
                  subtitle: Text(
                    '${documentStaging!['files']} 个文件 · 完成与失败副本均保留，未自动清理；暂不提供单独删除',
                  ),
                ),
              Text(
                '设备可用空间 ${sizeLabel(overview!['available_bytes'] as num)}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              ListTile(
                title: const Text('正文与历史引用'),
                trailing: Text(sizeLabel(usage['original_bytes'] as num)),
              ),
              ListTile(
                title: const Text('未引用副本'),
                trailing: Text(
                  sizeLabel(usage['retained_unreferenced_bytes'] as num),
                ),
              ),
              ListTile(
                title: const Text('失败临时文件'),
                trailing: Text(sizeLabel(usage['incomplete_bytes'] as num)),
              ),
              Text(
                '另有 ${overview!['pinned_resources']} 个资源身份由可恢复任务保护。不会按时间或空间自动清理。',
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : () => cleanup(),
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('手动清理预览'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => backup(),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('创建备份'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => restore(),
                  icon: const Icon(Icons.restore),
                  label: const Text('恢复备份'),
                ),
                if (widget.onRollback != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            if (await confirm(
                              '返回恢复前的资料库？',
                              '恢复前的资料库和设置快照仍保留。当前恢复副本也会保留。',
                              '回退资料库',
                            )) {
                              await widget.onRollback!();
                              await returnToLibrary();
                            }
                          }),
                    child: const Text('恢复回退'),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            ExpansionTile(
              title: const Text('按项目查看（共享资源在项目内去重）'),
              children: [
                for (final p in overview?['projects'] ?? [])
                  ListTile(
                    title: Text(p['name']),
                    subtitle: Text('${p['books']} 项内容 · ${p['resources']} 个资源'),
                    trailing: Text(sizeLabel(p['bytes'] as num)),
                  ),
              ],
            ),
            ExpansionTile(
              title: const Text('按文件查看'),
              children: [
                for (final b in overview?['books'] ?? [])
                  ListTile(
                    title: Text(
                      '${b['title']}${b['archived'] == true ? '（已移出书架）' : ''}',
                    ),
                    trailing: Text(sizeLabel(b['bytes'] as num)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('任务与恢复', style: Theme.of(context).textTheme.titleLarge),
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('没有存储任务。'),
              ),
            for (final t in tasks)
              Card(
                child: ListTile(
                  title: Text(
                    '${taskKindLabel(t['kind'])} · ${taskPhaseLabel(t['phase'])}',
                  ),
                  subtitle: Text(
                    '完成 ${t['completed'] ?? 0} / ${t['total'] ?? 0} 项${t['error'] == null ? '' : '\n${t['error']}'}',
                  ),
                  trailing: Wrap(
                    children: [
                      if (!['discarded', 'discarding'].contains(t['phase']) &&
                          (t['restart'] != null
                              ? t['restart'] != 'none' ||
                                    (t['kind'] == 'restore' &&
                                        t['phase'] == 'completed')
                              : t['kind'] == 'restore' ||
                                    t['kind'] == 'cleanup' ||
                                    ![
                                      'completed',
                                      'error',
                                    ].contains(t['phase'])))
                        IconButton(
                          tooltip: t['phase'] == 'completed'
                              ? '查看或使用结果'
                              : '继续任务',
                          onPressed: busy
                              ? null
                              : () => resume(Map<String, dynamic>.from(t)),
                          icon: const Icon(Icons.play_arrow),
                        ),
                      if (t['phase'] != 'completed' && t['discardable'] == true)
                        IconButton(
                          tooltip: '放弃任务',
                          onPressed: busy
                              ? null
                              : () => discard(Map<String, dynamic>.from(t)),
                          icon: const Icon(Icons.close),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
