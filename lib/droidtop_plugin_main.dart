// droidtop flutter_embed adapter for romgi (private plugin-core wrapper, see
// droidtop_plugin/README.md). Headless: FlutterDroidtopPlugin hosts this
// engine inside droidtop's :pluginhost process and talks to it over one
// MethodChannel, "JSON in, JSON out", plugin API contract 2.
//
// This file and lib/droidtop_plugin_logic.dart (the pure view and descriptor
// builders) are the whole Dart side of the wrapper. Everything they call
// (RomDatabaseService and the models) is romgi's own, unmodified code.
//
// The plugin id, and so the channel name FlutterDroidtopPlugin derives as
// "dev.droidtop.pluginhost/<pluginId>", differs per line
// (bi0shacker001.romgi-main, ...). It is not hardcoded: droidtop_plugin/
// build.sh passes it as --dart-define, so this one file is identical on
// every plugin/<line> branch.
//
// What the plugin does, by extension point (manifest.template.json):
//   library.sources  form / search / detail from the local game index; the
//                    acquire job returns a download descriptor, so droidtop
//                    downloads the single file itself (DownloadManager,
//                    droidtop's Downloads list) and places it in the system's
//                    folder. The plugin never writes a game file.
//   ui.settings      index status plus a job that downloads the index.
//   ui.main          romgi's own app, on a second engine.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'droidtop_plugin_logic.dart';
import 'main.dart' as app;
import 'services/rom_database_service.dart';

const String _pluginId = String.fromEnvironment(
  'DROIDTOP_PLUGIN_ID',
  defaultValue: 'bi0shacker001.romgi-dev',
);
final MethodChannel _channel = MethodChannel(
  'dev.droidtop.pluginhost/$_pluginId',
);

/// The app's own full-screen UI (the `ui.main` extension point, droidtop
/// docs/plugin-api.md 1.7): droidtop starts this function on a second engine
/// in this plugin's process when the person opens the plugin's own screen. It
/// is the entry the standalone app runs. `vm:entry-point` keeps it in the AOT
/// snapshot, which is built from this file as its target.
@pragma('vm:entry-point')
void mainUi() => app.main();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'handle':
        return _handle(call);
      case 'startJob':
        return _startJob(call);
      case 'cancelJob':
        return _cancelJob(call);
    }
    return v2Error('UNSUPPORTED', 'Unknown method ${call.method}');
  });
  // droidtop's flutter_embed readiness handshake, required of every
  // flutter_embed plugin: FlutterDroidtopPlugin.onLoad() blocks on this call,
  // because starting this isolate is not the moment this line runs, and a
  // handle() sent earlier fails with a channel-not-registered error. It goes
  // right after setMethodCallHandler and before any other work.
  _channel.invokeMethod('ready');
}

Map<String, dynamic> _decode(MethodCall call) =>
    jsonDecode(call.arguments as String) as Map<String, dynamic>;

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const <String, dynamic>{};

// ---------------------------------------------------------------- handle

Future<String> _handle(MethodCall call) async {
  try {
    final envelope = _decode(call);
    if (envelope['contract'] != 2) {
      return v2Error('INVALID_ARGS', 'Unsupported contract');
    }
    final point = envelope['point'] as String?;
    final op = envelope['op'] as String?;
    final args = _map(envelope['args']);
    if (point == 'ui.settings' && op == 'view') return await _settings();
    if (point == 'library.sources') {
      switch (op) {
        case 'form':
          return await _form(args);
        case 'search':
          return await _search(args);
        case 'detail':
          return await _detail(args);
        case 'acquire':
          return v2Error('UNSUPPORTED', 'Acquiring runs as a job');
      }
    }
    return v2Error('UNSUPPORTED', 'Unsupported extension point or operation');
  } catch (_) {
    return v2Error('FAILED', 'romgi could not complete the request');
  }
}

Future<String> _settings() async {
  final db = RomDatabaseService();
  final ready = await db.isDatabaseReady();
  final version = ready ? await db.getLocalVersion() : null;
  return v2Data(settingsView(indexReady: ready, entries: version?.entries));
}

String _systemId(Map<String, dynamic> args) =>
    _map(_map(args['context'])['system'])['id'] as String? ?? '';

Future<String> _form(Map<String, dynamic> args) async {
  final db = RomDatabaseService();
  if (!await db.isDatabaseReady()) {
    return v2Error('FAILED', _indexMissing);
  }
  return v2Data(sourceForm(
    systemId: _systemId(args),
    platforms: await db.getPlatforms(),
    regions: await db.getRegions(),
  ));
}

const String _indexMissing =
    'The game index is not downloaded yet. Open this plugin’s Settings page to download it.';

Future<String> _search(Map<String, dynamic> args) async {
  final db = RomDatabaseService();
  if (!await db.isDatabaseReady()) {
    return v2Error('FAILED', _indexMissing);
  }
  final values = _map(args['values']);
  // An empty platform is the person's "All platforms"; an absent one (the
  // default form) means the system the search was opened from.
  final platform =
      values.containsKey('platform') ? values['platform'] as String? : _systemId(args);
  final region = values['region'] as String?;
  final result = await db.search(
    query: (args['query'] as String?) ?? values['query'] as String?,
    platforms: platform == null || platform.isEmpty ? null : [platform],
    regions: region == null || region.isEmpty ? null : [region],
    maxResults: maxSearchResults,
  );
  return v2Data({'results': result.entries.map(searchResult).toList()});
}

Future<String> _detail(Map<String, dynamic> args) async {
  final slug = _map(args['ref'])['slug'] as String?;
  if (slug == null || slug.isEmpty) {
    return v2Error('INVALID_ARGS', 'Missing game reference');
  }
  final entry = await RomDatabaseService().getEntry(slug);
  if (entry == null) return v2Error('NOT_FOUND', 'That game is not in the index');
  return v2Data(detailView(entry));
}

// ------------------------------------------------------------------ jobs

// jobId -> the token of the transfer it runs, so cancelJob (best effort, per
// DroidtopPlugin.cancelJob) can stop it.
final Map<String, CancelToken> _running = {};

/// A contract 2 job arrives as `startJob(jobId, capability, {call: <envelope>})`
/// (docs/plugin-api.md 1.6, "Jobs in contract 2"); the answer goes back over
/// jobProgress / jobComplete, not this method's return value.
Future<String> _startJob(MethodCall call) async {
  final payload = _decode(call);
  final jobId = payload['jobId'] as String;
  final raw = _map(payload['args'])['call'];
  if (raw is! String) {
    unawaited(_complete(jobId, ok: false, error: 'Missing job envelope'));
    return jsonEncode({'ok': true});
  }
  unawaited(_runJob(jobId, jsonDecode(raw) as Map<String, dynamic>));
  return jsonEncode({'ok': true});
}

Future<String> _cancelJob(MethodCall call) async {
  final jobId = _decode(call)['jobId'] as String?;
  _running[jobId]?.cancel();
  return jsonEncode({'ok': true});
}

Future<void> _runJob(String jobId, Map<String, dynamic> envelope) async {
  try {
    if (envelope['contract'] != 2) {
      return await _complete(jobId, ok: false, error: 'Unsupported contract');
    }
    final point = envelope['point'] as String?;
    final op = envelope['op'] as String?;
    final args = _map(envelope['args']);
    if (point == 'ui.settings' && op == 'downloadIndex') {
      return await _downloadIndex(jobId);
    }
    if (point == 'library.sources' && op == 'acquire') {
      return await _acquire(jobId, args);
    }
    return await _complete(jobId, ok: false, error: 'Unsupported job operation');
  } catch (_) {
    return _complete(jobId, ok: false, error: 'romgi could not complete the job');
  } finally {
    _running.remove(jobId);
  }
}

Future<void> _downloadIndex(String jobId) async {
  final token = _running[jobId] = CancelToken();
  var reports = Future<void>.value();
  try {
    await RomDatabaseService().downloadDatabase(
      cancelToken: token,
      onProgress: (progress) {
        final percent = (progress * 100).round().clamp(0, 100).toInt();
        reports = reports.then(
          (_) => _progress(jobId, percent, 'Downloading game index'),
        );
      },
    );
    await reports;
    await _complete(jobId, ok: true, values: {'message': 'Game index downloaded'});
  } on DioException catch (e) {
    await _complete(
      jobId,
      ok: false,
      error: CancelToken.isCancel(e)
          ? 'Cancelled'
          : 'The game index could not be downloaded. Check your connection.',
    );
  }
}

/// Resolves the chosen link and hands droidtop a download descriptor. The
/// transfer is droidtop's: it queues the URL through DownloadManager, shows
/// it in Downloads and installs, and places the file in `context.destination`.
Future<void> _acquire(String jobId, Map<String, dynamic> args) async {
  final slug = _map(args['ref'])['slug'] as String?;
  if (slug == null || slug.isEmpty) {
    return _complete(jobId, ok: false, error: 'Missing game reference');
  }
  final entry = await RomDatabaseService().getEntry(slug);
  if (entry == null) {
    return _complete(jobId, ok: false, error: 'That game is not in the index');
  }
  final links = directLinks(entry);
  final index = int.tryParse(_map(args['values'])['link'] as String? ?? '') ?? 0;
  if (index < 0 || index >= links.length) {
    return _complete(
      jobId,
      ok: false,
      error: links.isEmpty
          ? 'This game has no direct download'
          : 'Pick a download source first',
    );
  }
  await _complete(jobId, ok: true, values: {
    'download': jsonEncode(acquireDownload(entry, links[index])),
    'message': 'Queued ${entry.title}',
  });
}

Future<void> _progress(String jobId, int percent, String statusLine) {
  return _channel.invokeMethod('jobProgress', jsonEncode({
    'jobId': jobId,
    'percent': percent,
    'statusLine': statusLine,
  }));
}

Future<void> _complete(
  String jobId, {
  required bool ok,
  String? error,
  Map<String, String> values = const {},
}) {
  return _channel.invokeMethod('jobComplete', jsonEncode({
    'jobId': jobId,
    'result': jsonEncode({
      'ok': ok,
      if (error != null) 'error': error,
      if (values.isNotEmpty) 'values': values,
    }),
  }));
}
