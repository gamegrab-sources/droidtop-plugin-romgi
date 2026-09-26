// droidtop flutter_embed adapter for romgi (private plugin-core wrapper --
// see droidtop_plugin/README.md in this same commit). Headless: no UI, no
// runApp(). FlutterDroidtopPlugin hosts this engine inside droidtop's own
// :pluginhost process and only ever talks to it over one MethodChannel,
// same "JSON in, JSON out, no rendering surface" shape droidtop's own
// samples/plugin-sample-flutter-statustile uses.
//
// This file is the ONLY plugin-core addition inside lib/ -- everything it
// calls (RomDatabaseService, DownloadService, the models) is romgi's own,
// unmodified code, reused directly per PLUGIN-PLAN.md's route A. The one
// other plugin-core change in this repo is notification_service.dart's
// additive NotificationService.silent() factory (droidtop has its own
// status surface; this embedding must never post a second, competing
// Android notification).
//
// The plugin id (and therefore this channel's name, which
// FlutterDroidtopPlugin derives as "dev.droidtop.pluginhost/<pluginId>")
// differs per line (bi0shacker001.romgi-main, bi0shacker001.romgi-3ds-decrypt,
// ...), so it is NOT hardcoded here -- droidtop_plugin/build.sh passes it
// as a compile-time --dart-define, read via String.fromEnvironment, so
// this one source file is identical across every plugin/<line> branch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'models/download_task.dart';
import 'models/rom_entry.dart';
import 'services/database_service.dart';
import 'services/download_service.dart';
import 'services/host_adapter.dart';
import 'services/notification_service.dart';
import 'services/rom_database_service.dart';
import 'services/seven_zip_service.dart';
import 'services/storage_service.dart';
import 'services/torrent_service.dart';

const String _pluginId = String.fromEnvironment(
  'DROIDTOP_PLUGIN_ID',
  defaultValue: 'bi0shacker001.romgi-dev',
);
final MethodChannel _channel = MethodChannel(
  'dev.droidtop.pluginhost/$_pluginId',
);

/// The one seam PLUGIN-PLAN.md's integration map identifies:
/// [DownloadService] only ever calls [getPlatformDirectory] to decide
/// where a file lands. Overriding just that method (romgi's own class is
/// a plain, non-final, non-sealed class -- confirmed by reading
/// services/storage_service.dart before writing this) hands droidtop's
/// own real destination folder straight through, with zero changes to
/// DownloadService, PlaylistWriter or anything else that already calls
/// through StorageService.
class DroidtopStorageService extends StorageService {
  DroidtopStorageService(this._destinationPath);
  final String _destinationPath;

  @override
  Future<Directory> getPlatformDirectory(String platform) async {
    final dir = Directory(_destinationPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

class _Runtime {
  _Runtime._(this.downloads);
  final DownloadService downloads;

  static _Runtime? _instance;
  static bool _initializing = false;

  /// Built lazily on first real call rather than in [main] -- the
  /// destination folder isn't known until droidtop's first invoke/startJob
  /// call hands it over as an argument, and DownloadService's storage
  /// dependency is fixed at construction.
  static _Runtime? existing() => _instance;

  static Future<_Runtime> forDestination(String destinationPath) async {
    // Only one plugin instance runs per :pluginhost process (one
    // FlutterEngine per plugin, per docs/SPEC.md 12a), so a single
    // process-lifetime instance -- rebuilt if the destination path
    // changes, since StorageService is otherwise wired at construction --
    // is the right lifetime, not a new DownloadService per call.
    final existing = _instance;
    if (existing != null) return existing;
    while (_initializing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final ready = _instance;
      if (ready != null) return ready;
    }
    _initializing = true;
    try {
      final downloads = DownloadService(
        db: DatabaseService(),
        romDb: RomDatabaseService(),
        storage: DroidtopStorageService(destinationPath),
        notifications: NotificationService.silent(),
        adapters: HostAdapterRegistry(),
        torrents: TorrentService(),
        sevenZip: SevenZipService(),
      );
      // Deliberately NOT calling downloads.initialize(): that also starts
      // flutter_foreground_task's own foreground service/notification,
      // which is exactly the second, droidtop-competing surface
      // NotificationService.silent() already avoids on the notification
      // side. addDownload/downloadStream work without it; only the
      // "resume pending downloads from last app run" behavior is skipped,
      // which is correct here -- this process doesn't persist between
      // droidtop plugin loads the way romgi's own app does.
      final runtime = _Runtime._(downloads);
      _instance = runtime;
      return runtime;
    } finally {
      _initializing = false;
    }
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'invoke') return _handleInvoke(call);
    if (call.method == 'startJob') return _handleStartJob(call);
    if (call.method == 'cancelJob') return _handleCancelJob(call);
    return jsonEncode({'ok': false, 'error': 'unknown method ${call.method}'});
  });
}

// jobId -> the romgi download task id it started, so a later "cancelJob"
// (best-effort, per DroidtopPlugin.cancelJob's own contract) can call
// through to DownloadService.cancelDownload with the id IT actually
// understands, not droidtop's own jobId.
final Map<String, String> _jobTaskIds = {};

Future<String> _handleCancelJob(MethodCall call) async {
  try {
    final payload = _decodePayload(call);
    final jobId = payload['jobId'] as String?;
    final taskId = jobId == null ? null : _jobTaskIds[jobId];
    if (taskId != null) {
      final runtime = _Runtime.existing();
      await runtime?.downloads.cancelDownload(taskId);
    }
  } catch (_) {
    // Best-effort, per DroidtopPlugin.cancelJob's own contract -- a
    // cancel that can't be matched to a running task is not an error.
  }
  return jsonEncode({'ok': true});
}

Map<String, dynamic> _decodePayload(MethodCall call) =>
    jsonDecode(call.arguments as String) as Map<String, dynamic>;

Future<String> _handleInvoke(MethodCall call) async {
  try {
    final payload = _decodePayload(call);
    final capability = payload['capability'] as String?;
    if (capability != 'acquire_content') {
      return jsonEncode({'ok': false, 'error': 'unsupported capability $capability'});
    }
    final args = (payload['args'] as Map<String, dynamic>?) ?? const {};
    final action = args['action'] as String?;
    if (action == 'search') return _search(args);
    return jsonEncode({'ok': false, 'error': 'acquire_content invoke only supports action=search (use startJob for action=download)'});
  } catch (e) {
    return jsonEncode({'ok': false, 'error': e.toString()});
  }
}

/// Search is a plain request/response over `invoke()`: romgi's own index
/// is a local sqlite database (RomDatabaseService), not a network round
/// trip, so it comfortably fits inside PluginRunner.CALL_TIMEOUT_MS
/// (15s) the way a real network scrape would not.
Future<String> _search(Map<String, dynamic> args) async {
  final query = args['query'] as String?;
  final platform = args['platform'] as String?;
  final romDb = RomDatabaseService();
  final result = await romDb.search(
    query: query,
    platforms: platform == null ? null : [platform],
    maxResults: (args['maxResults'] as num?)?.toInt() ?? 50,
  );
  final entries = result.entries.map((e) => e.toJson()).toList();
  return jsonEncode({
    'ok': true,
    'values': {'entries': jsonEncode(entries)},
  });
}

Future<String> _handleStartJob(MethodCall call) async {
  final payload = _decodePayload(call);
  final jobId = payload['jobId'] as String;
  final args = (payload['args'] as Map<String, dynamic>?) ?? const {};
  // Fire-and-forget from this handler's own point of view: the real
  // answer goes back over "jobProgress"/"jobComplete" (matching
  // FlutterDroidtopPlugin.startJob's own contract, docs/SPEC.md 12a),
  // not this method's return value.
  unawaited(_runDownloadJob(jobId, args));
  return jsonEncode({'ok': true});
}

Future<void> _reportProgress(String jobId, int percent, String statusLine) {
  return _channel.invokeMethod('jobProgress', jsonEncode({
    'jobId': jobId,
    'percent': percent,
    'statusLine': statusLine,
  }));
}

Future<void> _reportComplete(String jobId, Map<String, dynamic> result) {
  return _channel.invokeMethod('jobComplete', jsonEncode({
    'jobId': jobId,
    'result': jsonEncode(result),
  }));
}

/// The one long-running job this v1 wrapper implements: acquire_content's
/// download half. [args] carries a single [RomEntry] (as the same JSON
/// shape `_search` returns, so droidtop's own caller round-trips a result
/// it already has rather than re-fetching it), which link to use, and the
/// real destination folder droidtop already resolved for this system.
Future<void> _runDownloadJob(String jobId, Map<String, dynamic> args) async {
  try {
    final destinationPath = args['destinationPath'] as String?;
    if (destinationPath == null || destinationPath.isEmpty) {
      await _reportComplete(jobId, {'ok': false, 'error': 'missing destinationPath'});
      return;
    }
    final entryJson = args['entry'] as String?;
    if (entryJson == null) {
      await _reportComplete(jobId, {'ok': false, 'error': 'missing entry'});
      return;
    }
    final entry = RomEntry.fromJson(jsonDecode(entryJson) as Map<String, dynamic>);
    final linkIndex = (args['linkIndex'] as num?)?.toInt() ?? 0;
    if (linkIndex < 0 || linkIndex >= entry.links.length) {
      await _reportComplete(jobId, {'ok': false, 'error': 'linkIndex out of range for this entry'});
      return;
    }
    final link = entry.links[linkIndex];

    final runtime = await _Runtime.forDestination(destinationPath);
    final (addResult, task) = await runtime.downloads.addDownload(
      slug: entry.slug,
      title: entry.title,
      platform: entry.platform,
      boxartUrl: entry.boxartUrl,
      link: link,
    );
    _jobTaskIds[jobId] = task.id;
    if (addResult == AddDownloadResult.duplicate) {
      await _reportComplete(jobId, {
        'ok': true,
        'values': {'taskId': task.id, 'duplicate': 'true'},
      });
      return;
    }

    final done = Completer<void>();
    late final StreamSubscription<DownloadTask> sub;
    sub = runtime.downloads.downloadStream.listen((update) async {
      if (update.id != task.id) return;
      switch (update.status) {
        case DownloadStatus.downloading:
        case DownloadStatus.extracting:
          await _reportProgress(
            jobId,
            (update.progress * 100).round(),
            update.status == DownloadStatus.extracting ? 'Extracting' : 'Downloading',
          );
        case DownloadStatus.completed:
          await _reportComplete(jobId, {
            'ok': true,
            'values': {'taskId': update.id, 'filePath': update.filePath ?? ''},
          });
          await sub.cancel();
          if (!done.isCompleted) done.complete();
        case DownloadStatus.failed:
          await _reportComplete(jobId, {
            'ok': false,
            'error': update.error ?? 'download failed',
          });
          await sub.cancel();
          if (!done.isCompleted) done.complete();
        case DownloadStatus.pending:
        case DownloadStatus.paused:
          break;
      }
    });
    await done.future;
  } catch (e) {
    await _reportComplete(jobId, {'ok': false, 'error': e.toString()});
  }
}
