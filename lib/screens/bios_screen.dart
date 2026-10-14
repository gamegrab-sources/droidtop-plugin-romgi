import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../services/bios_service.dart';

const String _copyrightNote =
    'BIOS and firmware files are copyrighted: take only those of consoles '
    'you own.';

/// Every system of the BIOS list, with how many of its files are in the
/// BIOS folder.
class BiosScreen extends ConsumerStatefulWidget {
  const BiosScreen({super.key});

  @override
  ConsumerState<BiosScreen> createState() => _BiosScreenState();
}

class _BiosScreenState extends ConsumerState<BiosScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final indexAsync = ref.watch(biosIndexProvider);
    final folder = ref.watch(biosFolderProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BIOS and System Files'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Download the file list again',
            onPressed: () async {
              try {
                await ref.read(biosServiceProvider).loadIndex(refresh: true);
              } catch (_) {
                // The list provider shows the error.
              }
              if (mounted) ref.invalidate(biosIndexProvider);
            },
          ),
        ],
      ),
      body: indexAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _Message(text: '$error'),
        data: (index) {
          final ids = index.systems.keys.where((id) {
            if (_filter.isEmpty) return true;
            final name = index.systems[id]!.name.toLowerCase();
            return id.contains(_filter) || name.contains(_filter);
          }).toList()
            ..sort((a, b) => index.systems[a]!.name
                .toLowerCase()
                .compareTo(index.systems[b]!.name.toLowerCase()));
          return ListView(
            children: [
              if (folder != null)
                ListTile(
                  leading: const Icon(Icons.folder),
                  title: const Text('BIOS folder'),
                  subtitle: Text(folder),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Find a system',
                  ),
                  onChanged: (value) =>
                      setState(() => _filter = value.trim().toLowerCase()),
                ),
              ),
              for (final id in ids)
                _SystemTile(systemId: id, system: index.systems[id]!),
            ],
          );
        },
      ),
    );
  }
}

class _SystemTile extends ConsumerWidget {
  const _SystemTile({required this.systemId, required this.system});

  final String systemId;
  final BiosSystem system;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(biosSystemStatusProvider(systemId)).valueOrNull;
    return ListTile(
      leading: Icon(
        status == null
            ? Icons.memory
            : status.complete
                ? Icons.check_circle
                : Icons.error_outline,
        color: status != null && status.complete ? Colors.green : null,
      ),
      title: Text(system.name.isEmpty ? systemId : system.name),
      subtitle: Text(
        status == null
            ? '${system.files.length} files'
            : '${status.present} of ${status.total} in your BIOS folder',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BiosSystemScreen(systemId: systemId),
        ),
      ),
    );
  }
}

/// One system's files: which are there, where each goes, and getting the
/// missing ones.
class BiosSystemScreen extends ConsumerStatefulWidget {
  const BiosSystemScreen({super.key, required this.systemId});

  final String systemId;

  @override
  ConsumerState<BiosSystemScreen> createState() => _BiosSystemScreenState();
}

class _BiosSystemScreenState extends ConsumerState<BiosSystemScreen> {
  bool _busy = false;
  String? _progress;

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(biosIndexProvider).valueOrNull;
    final system = index?.systems[widget.systemId];
    final statusAsync = ref.watch(biosSystemStatusProvider(widget.systemId));
    final folder = ref.watch(biosFolderProvider).valueOrNull;

    if (system == null || folder == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('System Files')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final status = statusAsync.valueOrNull;
    final missing = system.files
        .where((f) => status?.states[f.name] == BiosFileState.missing)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(system.name.isEmpty ? widget.systemId : system.name),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(
              status == null
                  ? 'Checking your BIOS folder…'
                  : '${status.present} of ${status.total} files in your BIOS '
                      'folder',
            ),
            subtitle: const Text(_copyrightNote),
          ),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: FilledButton.icon(
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: Text(_progress ??
                    'Get the ${missing.length} missing '
                        '${missing.length == 1 ? 'file' : 'files'}'),
                onPressed: _busy ? null : () => _getMissing(missing, folder),
              ),
            ),
          const Divider(),
          for (final file in system.files)
            ListTile(
              leading: _StateIcon(state: status?.states[file.name]),
              title: Text(file.name),
              subtitle: Text(
                [
                  _stateText(status?.states[file.name]),
                  'Goes in ${BiosService.targetPath(folder, file)}',
                  if (file.note != null) file.note!,
                ].join('\n'),
              ),
              isThreeLine: true,
              onTap: _busy ? null : () => _openFile(file, folder),
            ),
        ],
      ),
    );
  }

  String _stateText(BiosFileState? state) {
    switch (state) {
      case BiosFileState.verified:
        return 'In your BIOS folder, a known good dump';
      case BiosFileState.present:
        return 'In your BIOS folder (not checked)';
      case BiosFileState.otherDump:
        return 'In your BIOS folder, but not a dump emulators are known to '
            'accept';
      case BiosFileState.missing:
        return 'Missing';
      case null:
        return 'Checking…';
    }
  }

  /// Gets each missing file from its first source holding a listed dump.
  Future<void> _getMissing(List<BiosFile> files, String folder) async {
    final service = ref.read(biosServiceProvider);
    final sources = ref.read(settingsProvider).biosSources;
    final failures = <String>[];
    setState(() => _busy = true);
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      setState(() => _progress = 'Getting ${file.name} (${i + 1} of '
          '${files.length})');
      try {
        final candidates = (await service.candidates(
          widget.systemId,
          file,
          sources,
        ))
            .where((c) => c.exact)
            .toList();
        if (candidates.isEmpty) {
          failures.add('${file.name}: no source holds a listed dump');
          continue;
        }
        String? lastError;
        for (final candidate in candidates) {
          try {
            await service.download(
              biosRoot: folder,
              file: file,
              candidate: candidate,
            );
            lastError = null;
            break;
          } on BiosException catch (error) {
            lastError = error.message;
          }
        }
        if (lastError != null) failures.add('${file.name}: $lastError');
      } catch (error) {
        failures.add('${file.name}: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _progress = null;
    });
    ref.invalidate(biosSystemStatusProvider(widget.systemId));
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(failures.isEmpty
          ? 'All missing files are in your BIOS folder'
          : 'Not all files could be fetched:\n${failures.join('\n')}'),
    ));
  }

  Future<void> _openFile(BiosFile file, String folder) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BiosFileSheet(
        systemId: widget.systemId,
        file: file,
        folder: folder,
      ),
    );
    if (changed == true) {
      ref.invalidate(biosSystemStatusProvider(widget.systemId));
    }
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});

  final BiosFileState? state;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case BiosFileState.verified:
        return const Icon(Icons.check_circle, color: Colors.green);
      case BiosFileState.present:
        return const Icon(Icons.check_circle_outline);
      case BiosFileState.otherDump:
        return const Icon(Icons.warning_amber, color: Colors.orange);
      case BiosFileState.missing:
        return const Icon(Icons.error_outline);
      case null:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
    }
  }
}

/// One file's sources, in the BIOS plugin's order, and a download.
class _BiosFileSheet extends ConsumerStatefulWidget {
  const _BiosFileSheet({
    required this.systemId,
    required this.file,
    required this.folder,
  });

  final String systemId;
  final BiosFile file;
  final String folder;

  @override
  ConsumerState<_BiosFileSheet> createState() => _BiosFileSheetState();
}

class _BiosFileSheetState extends ConsumerState<_BiosFileSheet> {
  late final Future<List<BiosCandidate>> _candidates;
  int _choice = 0;
  bool _busy = false;
  double? _fraction;
  String? _error;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _candidates = ref.read(biosServiceProvider).candidates(
          widget.systemId,
          widget.file,
          ref.read(settingsProvider).biosSources,
        );
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<List<BiosCandidate>>(
          future: _candidates,
          builder: (context, snapshot) {
            final candidates = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.file.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text('Goes in '
                    '${BiosService.targetPath(widget.folder, widget.file)}'),
                if (widget.file.md5.isNotEmpty)
                  Text('Accepted dumps: ${widget.file.md5.length} '
                      '(MD5 ${widget.file.md5.take(2).join(', ')}'
                      '${widget.file.md5.length > 2 ? ', …' : ''})'),
                const SizedBox(height: 12),
                if (candidates == null)
                  const Center(child: CircularProgressIndicator())
                else if (candidates.isEmpty)
                  const Text(
                    'No source for this file. Turn on a source or add an '
                    'address of your own in Settings > BIOS and System '
                    'Files, or put the file in the folder yourself.',
                  )
                else ...[
                  const Text('Get it from'),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (var i = 0; i < candidates.length; i++)
                          ListTile(
                            selected: i == _choice,
                            leading: Icon(i == _choice
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked),
                            title: Text(candidates[i].describe()),
                            onTap: _busy
                                ? null
                                : () => setState(() => _choice = i),
                          ),
                      ],
                    ),
                  ),
                  if (_fraction != null)
                    LinearProgressIndicator(value: _fraction),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  const Text(_copyrightNote),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: const Text('Download'),
                      onPressed: _busy
                          ? null
                          : () => _download(candidates[_choice]),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _download(BiosCandidate candidate) async {
    final cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _fraction = 0;
      _cancel = cancel;
    });
    try {
      await ref.read(biosServiceProvider).download(
            biosRoot: widget.folder,
            file: widget.file,
            candidate: candidate,
            cancelToken: cancel,
            onProgress: (received, total) {
              if (!mounted || total <= 0) return;
              setState(() => _fraction = received / total);
            },
          );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fraction = null;
        _error = error is BiosException ? error.message : '$error';
      });
    }
  }
}

/// A row for a game's detail screen: the system's BIOS files, when the BIOS
/// list has any for it, with how many are in the BIOS folder.
class SystemFilesRow extends ConsumerWidget {
  const SystemFilesRow({super.key, required this.platform});

  final String platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final systemId =
        ref.watch(biosSystemIdForPlatformProvider(platform)).valueOrNull;
    if (systemId == null) return const SizedBox.shrink();
    final status = ref.watch(biosSystemStatusProvider(systemId)).valueOrNull;
    if (status == null) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ListTile(
        leading: Icon(
          status.complete ? Icons.check_circle : Icons.memory,
          color: status.complete ? Colors.green : null,
        ),
        title: const Text('BIOS and system files'),
        subtitle: Text(status.complete
            ? 'All ${status.total} files for ${status.system.name} are in '
                'your BIOS folder'
            : '${status.present} of ${status.total} files for '
                '${status.system.name} are in your BIOS folder. Tap to get '
                'the missing ones.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BiosSystemScreen(systemId: systemId),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
