import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../services/download_service.dart';
import '../utils/utils.dart';
import 'internet_archive_login_screen.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadState = ref.watch(downloadProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (downloadState.completedDownloads.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'clear_completed') {
                  ref.read(downloadProvider.notifier).clearCompletedDownloads();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'clear_completed',
                  child: Text('Clear completed'),
                ),
              ],
            ),
        ],
      ),
      body: downloadState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context, ref, downloadState),
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    DownloadState state,
  ) {
    if (state.activeDownloads.isEmpty &&
        state.completedDownloads.isEmpty &&
        state.failedDownloads.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.download_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'No downloads yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Browse ROMs and tap download to get started',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(downloadProvider.notifier).refresh(),
      child: ListView(
        children: [
          // Current downloads
          if (state.currentDownloads.isNotEmpty) ...[
            _SectionHeader(
              title: 'Downloading (${state.currentDownloads.length})',
            ),
            ...state.currentDownloads.map(
              (task) => _CurrentDownloadTile(task: task),
            ),
          ],

          // Queue
          if (state.queuedDownloads.isNotEmpty) ...[
            _SectionHeader(title: 'Queue (${state.queuedDownloads.length})'),
            ...state.queuedDownloads.map(
              (task) => _QueuedDownloadTile(task: task),
            ),
          ],

          // Failed
          if (state.failedDownloads.isNotEmpty) ...[
            _SectionHeader(title: 'Failed (${state.failedDownloads.length})'),
            ...state.failedDownloads.map(
              (task) => _FailedDownloadTile(task: task),
            ),
          ],

          // Completed
          if (state.completedDownloads.isNotEmpty) ...[
            _SectionHeader(
              title: 'Completed (${state.completedDownloads.length})',
            ),
            ...state.completedDownloads.map(
              (task) => _CompletedDownloadTile(task: task),
            ),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _CurrentDownloadTile extends ConsumerWidget {
  final DownloadTask task;

  const _CurrentDownloadTile({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Box art
                SizedBox(
                  width: 48,
                  height: 48,
                  child: task.boxartUrl != null
                      ? CachedNetworkImage(
                          imageUrl: task.boxartUrl!,
                          fit: BoxFit.cover,
                          placeholder: (context, string) =>
                              const Icon(Icons.videogame_asset),
                          errorWidget: (context, string, error) =>
                              const Icon(Icons.videogame_asset),
                        )
                      : const Icon(Icons.videogame_asset, size: 32),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${PlatformNames.getDisplayName(task.platform)} • ${task.link.host} • ${task.statusText}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                // Pause button
                IconButton(
                  icon: const Icon(Icons.pause),
                  onPressed: () {
                    ref.read(downloadProvider.notifier).pauseDownload(task.id);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Progress bar — indeterminate while fetching torrent metadata
            // (we have no total yet, so a fixed bar would just sit at 0%).
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: task.fetchingMetadata || task.status == DownloadStatus.extracting
                    ? null
                    : task.progress,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  task.fetchingMetadata
                      ? task.peers > 0
                          ? '${task.peers} peer${task.peers == 1 ? '' : 's'} connected'
                          : 'Contacting trackers…'
                      : task.status == DownloadStatus.extracting
                          ? 'Extracting…'
                          : task.progressText,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (task.speedText.isNotEmpty &&
                        task.status != DownloadStatus.extracting) ...[
                      Text(
                        task.speedText,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (!task.fetchingMetadata &&
                        task.status != DownloadStatus.extracting)
                      Text(
                        '${(task.progress * 100).toStringAsFixed(1)}%',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ],
            ),
            if (task.link.isTorrent && task.peers >= 0) ...[
              const SizedBox(height: 4),
              Text(
                '${task.peers} peer${task.peers == 1 ? '' : 's'} • '
                '${task.seeds} seed${task.seeds == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QueuedDownloadTile extends ConsumerWidget {
  final DownloadTask task;

  const _QueuedDownloadTile({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPaused = task.status == DownloadStatus.paused;

    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: task.boxartUrl != null
            ? CachedNetworkImage(
                imageUrl: task.boxartUrl!,
                fit: BoxFit.cover,
                placeholder: (context, string) =>
                    const Icon(Icons.videogame_asset),
                errorWidget: (context, string, error) =>
                    const Icon(Icons.videogame_asset),
              )
            : const Icon(Icons.videogame_asset),
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${PlatformNames.getDisplayName(task.platform)} • ${task.link.sizeStr}${isPaused ? ' • Paused' : ''}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isPaused)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: () {
                ref.read(downloadProvider.notifier).resumeDownload(task.id);
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.pause),
              onPressed: () {
                ref.read(downloadProvider.notifier).pauseDownload(task.id);
              },
            ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              ref.read(downloadProvider.notifier).cancelDownload(task.id);
            },
          ),
        ],
      ),
    );
  }
}

class _CompletedDownloadTile extends ConsumerWidget {
  final DownloadTask task;

  const _CompletedDownloadTile({required this.task});

  // A completed Vita download still sitting at a plain top-level .pkg means
  // the license either wasn't requested (pkgOnly) or the automatic fetch
  // failed silently; a pkg+license folder (pkgWithLicense mode) is also
  // eligible, to let the user merge it into a decrypted zip on request.
  // Either way, offer the license/decrypt action.
  bool get _hasVitaPkgToDecrypt {
    if (task.platform != 'psv' || task.filePath == null) return false;
    final path = task.filePath!;
    if (path.toLowerCase().endsWith('.pkg')) return true;
    return FileSystemEntity.isDirectorySync(path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: task.boxartUrl != null
            ? CachedNetworkImage(
                imageUrl: task.boxartUrl!,
                fit: BoxFit.cover,
                placeholder: (context, string) =>
                    const Icon(Icons.videogame_asset),
                errorWidget: (context, string, error) =>
                    const Icon(Icons.videogame_asset),
              )
            : const Icon(Icons.videogame_asset),
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${PlatformNames.getDisplayName(task.platform)} • ${task.link.sizeStr}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_hasVitaPkgToDecrypt)
            IconButton(
              icon: const Icon(Icons.vpn_key_outlined),
              tooltip: 'Decrypt with license',
              onPressed: () => showDialog(
                context: context,
                builder: (_) => _VitaLicenseDialog(task: task),
              ),
            ),
          Icon(
            Icons.check_circle,
            color: Theme.of(context).colorScheme.primary,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove',
            onPressed: () {
              ref
                  .read(downloadProvider.notifier)
                  .removeCompletedDownload(task.id);
            },
          ),
        ],
      ),
    );
  }
}

class _VitaLicenseDialog extends ConsumerStatefulWidget {
  final DownloadTask task;

  const _VitaLicenseDialog({required this.task});

  @override
  ConsumerState<_VitaLicenseDialog> createState() => _VitaLicenseDialogState();
}

class _VitaLicenseDialogState extends ConsumerState<_VitaLicenseDialog> {
  final _zrifController = TextEditingController();
  late VitaDownloadMode _mode;
  bool _applying = false;
  String? _error;
  String? _sourceUrl;

  // Already has a saved license — either the legacy per-game subfolder
  // layout, or the current flat <name>.rif sitting next to the pkg (a
  // leftover <name>.zrif from before that switch also counts). The only
  // thing worth doing here is merging it into a decrypted zip, so default
  // to that instead of the general per-platform setting.
  bool get _hasExistingLicense {
    final path = widget.task.filePath;
    if (path == null) return false;
    if (FileSystemEntity.isDirectorySync(path)) return true;
    final withoutExt = p.withoutExtension(path);
    return File('$withoutExt.rif').existsSync() ||
        File('$withoutExt.zrif').existsSync();
  }

  @override
  void initState() {
    super.initState();
    if (_hasExistingLicense) {
      _mode = VitaDownloadMode.decryptToZip;
    } else {
      _mode = ref.read(settingsProvider).vitaDownloadMode;
      if (_mode == VitaDownloadMode.pkgOnly) {
        _mode = VitaDownloadMode.pkgWithLicense;
      }
    }
    ref
        .read(downloadProvider.notifier)
        .getVitaLicenseSourceUrl(widget.task)
        .then((url) {
      if (mounted) setState(() => _sourceUrl = url);
    });
  }

  Future<void> _openSource() async {
    final url = _sourceUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _zrifController.dispose();
    super.dispose();
  }

  String _modeName(VitaDownloadMode mode) {
    switch (mode) {
      case VitaDownloadMode.pkgOnly:
        return 'PKG only';
      case VitaDownloadMode.pkgWithLicense:
        return 'PKG + license (folder)';
      case VitaDownloadMode.decryptToZip:
        return 'Decrypt to zip';
    }
  }

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      await ref.read(downloadProvider.notifier).applyVitaLicense(
            widget.task,
            _mode,
            manualZrif: _zrifController.text,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _applying = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_hasExistingLicense ? 'Merge into decrypted zip' : 'Decrypt with license'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_hasExistingLicense) ...[
              Text(
                'This pkg + license folder will be merged into a single '
                'decrypted zip; the folder is removed once that succeeds.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
            ],
            for (final mode in [
              VitaDownloadMode.pkgWithLicense,
              VitaDownloadMode.decryptToZip,
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  mode == _mode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: mode == _mode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                title: Text(_modeName(mode)),
                onTap: () => setState(() => _mode = mode),
              ),
            const SizedBox(height: 8),
            Text(
              _hasExistingLicense
                  ? 'Apply reuses the license already saved in this folder. '
                      'To use a different one instead, paste a zRIF below:'
                  : 'Apply retries fetching the zRIF license from the catalog. '
                      'If that keeps failing (e.g. a 404), open the title\'s '
                      'NoPayStation page, copy its zRIF, and paste it below instead:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _sourceUrl == null ? null : _openSource,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(
                _sourceUrl == null
                    ? 'No catalog page found for this title'
                    : 'Open on NoPayStation',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _zrifController,
              decoration: const InputDecoration(
                labelText: 'zRIF (optional — paste after copying above)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLines: 3,
              minLines: 1,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _applying ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _applying ? null : _apply,
          child: _applying
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Apply'),
        ),
      ],
    );
  }
}

class _FailedDownloadTile extends ConsumerWidget {
  final DownloadTask task;

  const _FailedDownloadTile({required this.task});

  bool get _isAuthRequired => DownloadService.isAuthRequiredError(task.error);

  String _getErrorMessage() {
    if (_isAuthRequired) {
      return 'Internet Archive login required';
    }
    return task.error ?? 'Download failed';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: task.boxartUrl != null
            ? CachedNetworkImage(
                imageUrl: task.boxartUrl!,
                fit: BoxFit.cover,
                placeholder: (context, string) =>
                    const Icon(Icons.videogame_asset),
                errorWidget: (context, string, error) =>
                    const Icon(Icons.videogame_asset),
              )
            : const Icon(Icons.videogame_asset),
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          if (_isAuthRequired)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.lock,
                size: 14,
                color: Colors.deepPurple.shade400,
              ),
            ),
          Expanded(
            child: Text(
              _getErrorMessage(),
              style: TextStyle(
                color: _isAuthRequired
                    ? Colors.deepPurple.shade400
                    : Theme.of(context).colorScheme.error,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isAuthRequired)
            TextButton.icon(
              icon: const Icon(Icons.lock_open, size: 18),
              label: const Text('Login'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.deepPurple.shade400,
              ),
              onPressed: () => _loginAndRetry(context, ref),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Retry',
              onPressed: () {
                ref.read(downloadProvider.notifier).retryDownload(task.id);
              },
            ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove',
            onPressed: () {
              ref.read(downloadProvider.notifier).cancelDownload(task.id);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _loginAndRetry(BuildContext context, WidgetRef ref) async {
    final loggedIn = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => const InternetArchiveLoginScreen(),
      ),
    );

    if (loggedIn == true) {
      ref.invalidate(iaLoggedInProvider);
      ref.read(downloadProvider.notifier).retryDownload(task.id);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Logged in! Retrying download...')),
        );
      }
    }
  }
}
