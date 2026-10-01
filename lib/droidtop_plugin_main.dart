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
    if (call.method == 'handle') return _handleHandle(call);
    if (call.method == 'invoke') return _handleInvoke(call);
    if (call.method == 'startJob') return _handleStartJob(call);
    if (call.method == 'cancelJob') return _handleCancelJob(call);
    return jsonEncode({'ok': false, 'error': 'unknown method ${call.method}'});
  });
  // droidtop's flutter_embed readiness handshake (required of every
  // flutter_embed plugin, not just this one): FlutterDroidtopPlugin.onLoad()
  // on the host side blocks waiting for this exact call before returning,
  // because executeDartEntrypoint() starting this isolate is not the same
  // moment as this line actually running -- droidtop's own acquire_content
  // search call used to race this isolate's own startup and fail with a
  // channel-not-yet-registered PlatformException before this was added.
  _channel.invokeMethod('ready');
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

Future<String> _handleHandle(MethodCall call) async {
  try {
    final envelope = _decodePayload(call);
    if (envelope['contract'] != 2) {
      return _v2Error('INVALID_ARGS', 'Unsupported contract');
    }
    final point = envelope['point'] as String?;
    final op = envelope['op'] as String?;
    final args = (envelope['args'] as Map<String, dynamic>?) ?? const {};
    if (point == 'ui.settings') {
      if (op == 'view') return await _settingsView();
      return _v2Error('UNSUPPORTED', 'Unsupported settings operation');
    }
    if (point == 'library.sources') {
      switch (op) {
        case 'form': return await _sourceForm(args);
        case 'search': return await _sourceSearch(args);
        case 'detail': return await _sourceDetail(args);
        case 'acquire':
          return _v2Error('UNSUPPORTED', 'Acquisition runs as a job');
      }
    }
    return _v2Error('UNSUPPORTED', 'Unsupported extension point');
  } catch (_) {
    return _v2Error('FAILED', 'The plugin could not complete the request');
  }
}

String _v2Data(Object data) => jsonEncode({'ok': true, 'data': data});
String _v2Error(String code, String message) =>
    jsonEncode({'ok': false, 'error': {'code': code, 'message': message}});

Map<String, dynamic> _view(String title, List<Map<String, dynamic>> items,
        {String? subtitle}) =>
    {'view': 1, 'title': title, 'subtitle': subtitle,
     'sections': [{'id': 'main', 'items': items}]};

Future<String> _settingsView() async {
  final db = RomDatabaseService();
  final ready = await db.isDatabaseReady();
  final local = ready ? await db.getLocalVersion() : null;
  final view = _view('romgi', [
    {'type': 'info', 'id': 'index', 'title': 'Game index',
     'value': ready ? 'Downloaded${local == null ? '' : ' · ${local.entries} games'}' : 'Not downloaded'},
    {'type': 'button', 'id': 'download-index', 'title': 'Download the game index',
     'action': {'kind': 'job', 'op': 'downloadIndex', 'title': 'Download game index'}},
  ]);
  return _v2Data(view);
}

Future<String> _sourceForm(Map<String, dynamic> args) async {
  final context = (args['context'] as Map<String, dynamic>?) ?? const {};
  final system = (context['system'] as Map<String, dynamic>?) ?? const {};
  final systemId = system['id'] as String? ?? '';
  final regions = <Map<String, dynamic>>[
    {'value': '', 'label': 'Any region'},
  ];
  try {
    for (final region in await RomDatabaseService().getRegions()) {
      regions.add({'value': region.id, 'label': region.name});
    }
  } catch (_) {}
  final systems = <Map<String, dynamic>>[
    {'value': '', 'label': 'All platforms'},
  ];
  try {
    for (final platform in await RomDatabaseService().getPlatforms()) {
      systems.add({'value': platform.id, 'label': '${platform.brand} ${platform.name}'.trim()});
    }
  } catch (_) {}
  final items = <Map<String, dynamic>>[
    {'type': 'text', 'id': 'query', 'title': 'Search', 'value': ''},
    {'type': 'choice', 'id': 'platform', 'title': 'Platform', 'options': systems, 'value': systemId},
    {'type': 'choice', 'id': 'region', 'title': 'Region', 'options': regions, 'value': ''},
  ];
  return _v2Data(_view('Search games', items));
}

Future<String> _sourceSearch(Map<String, dynamic> args) async {
  final context = (args['context'] as Map<String, dynamic>?) ?? const {};
  final system = (context['system'] as Map<String, dynamic>?) ?? const {};
  final values = (args['values'] as Map<String, dynamic>?) ?? const {};
  final platform = (values['platform'] as String?) ?? system['id'] as String?;
  final region = values['region'] as String?;
  final db = RomDatabaseService();
  if (!await db.isDatabaseReady()) {
    return _v2Error('FAILED', 'The game index is not downloaded yet. Open this plugin’s Settings page to download it.');
  }
  final result = await db.search(
    query: (args['query'] as String?) ?? values['query'] as String?,
    platforms: platform == null || platform.isEmpty ? null : [platform],
    regions: region == null || region.isEmpty ? null : [region],
    maxResults: 50,
  );
  return _v2Data({'results': result.entries.map((entry) => {
    'id': entry.slug,
    'title': entry.title,
    'subtitle': entry.platform,
    'columns': [if (entry.regions.isNotEmpty) entry.regions.join(', ')],
    'badges': [if (entry.links.isNotEmpty) '${entry.links.length} downloads'],
    'platform': entry.platform,
    'ref': entry.toJson(),
  }).toList()});
}

Future<String> _sourceDetail(Map<String, dynamic> args) async {
  final ref = args['ref'];
  if (ref is! Map<String, dynamic>) return _v2Error('INVALID_ARGS', 'Missing game reference');
  final entry = RomEntry.fromJson(ref);
  final options = <Map<String, dynamic>>[];
  for (var i = 0; i < entry.links.length; i++) {
    final link = entry.links[i];
    options.add({'value': '$i', 'label': '${link.name} · ${link.host} · ${link.sizeStr}'});
  }
  final view = _view(entry.title, [
    {'type': 'info', 'id': 'platform', 'title': 'Platform', 'value': entry.platform},
    if (entry.regions.isNotEmpty) {'type': 'info', 'id': 'regions', 'title': 'Regions', 'value': entry.regions.join(', ')},
    {'type': 'choice', 'id': 'link', 'title': 'Download', 'options': options, 'value': options.isEmpty ? '' : options.first['value']},
    if (options.isNotEmpty) {'type': 'button', 'id': 'acquire', 'title': 'Download game',
     'action': {'kind': 'job', 'op': 'acquire', 'title': 'Download ${entry.title}', 'args': {'ref': ref}}},
  ]);
  return _v2Data(view);
}

Future<String> _handleInvoke(MethodCall call) async {
  try {
    final payload = _decodePayload(call);
    final capability = payload['capability'] as String?;
    if (capability != 'acquire_content') {
      return jsonEncode({'ok': false, 'error': 'unsupported capability $capability'});
    }
    final args = (payload['args'] as Map<String, dynamic>?) ?? const {};
    final action = args['action'] as String?;
    if (action == 'search') return await _search(args);
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
  final rawArgs = payload['args'];
  if (rawArgs is Map<String, dynamic> && rawArgs['call'] is String) {
    final envelope = jsonDecode(rawArgs['call'] as String) as Map<String, dynamic>;
    unawaited(_runV2Job(jobId, envelope));
    return jsonEncode({'ok': true});
  }
  final args = (rawArgs as Map<String, dynamic>?) ?? const {};
  // Fire-and-forget from this handler's own point of view: the real
  // answer goes back over "jobProgress"/"jobComplete" (matching
  // FlutterDroidtopPlugin.startJob's own contract, docs/SPEC.md 12a),
  // not this method's return value.
  unawaited(_runDownloadJob(jobId, args));
  return jsonEncode({'ok': true});
}

/// Runs a contract 2 action that the host routed through startJob. The
/// envelope is the same one used by handle; source jobs additionally carry
/// the resolved destination in their host-owned context.
Future<void> _runV2Job(
  String jobId,
  Map<String, dynamic> envelope,
) async {
  try {
    if (envelope['contract'] != 2) {
      await _reportComplete(jobId, {
        'ok': false,
        'error': 'Unsupported contract',
      });
      return;
    }
    final point = envelope['point'] as String?;
    final op = envelope['op'] as String?;
    final args = (envelope['args'] as Map<String, dynamic>?) ?? const {};

    if (point == 'ui.settings' && op == 'downloadIndex') {
      final db = RomDatabaseService();
      var progressReports = Future<void>.value();
      await db.downloadDatabase(onProgress: (progress) {
        final percent = (progress * 100).round().clamp(0, 100).toInt();
        progressReports = progressReports.then((_) =>
            _reportProgress(jobId, percent, 'Downloading game index'));
      });
      await progressReports;
      await _reportComplete(jobId, {
        'ok': true,
        'values': {'message': 'Game index downloaded'},
      });
      return;
    }

    if (point == 'library.sources' && op == 'acquire') {
      final ref = args['ref'];
      if (ref is! Map<String, dynamic>) {
        await _reportComplete(jobId, {
          'ok': false,
          'error': 'Missing game reference',
        });
        return;
      }
      final context = (args['context'] as Map<String, dynamic>?) ?? const {};
      final destinationPath = context['destination'] as String?;
      if (destinationPath == null || destinationPath.isEmpty) {
        await _reportComplete(jobId, {
          'ok': false,
          'error': 'Missing destination',
        });
        return;
      }
      final values = (args['values'] as Map<String, dynamic>?) ?? const {};
      final linkIndex = int.tryParse(values['link'] as String? ?? '') ?? 0;
      await _runDownloadJob(jobId, {
        'destinationPath': destinationPath,
        'entry': jsonEncode(ref),
        'linkIndex': linkIndex,
      });
      return;
    }

    await _reportComplete(jobId, {
      'ok': false,
      'error': 'Unsupported job operation',
    });
  } catch (e) {
    await _reportComplete(jobId, {'ok': false, 'error': e.toString()});
  }
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
