// The pure half of the droidtop plugin wrapper (plugin-core, see
// droidtop_plugin/README.md): the view documents the plugin hands droidtop
// and the acquire download descriptor, built from romgi's own models with no
// channel, no Flutter binding and no I/O, so they are unit-tested
// (test/droidtop_plugin_logic_test.dart) without an engine.
//
// Shapes follow droidtop's docs/plugin-api.md 1.6 (the view schema and the
// additive `download` acquire reply, docs/plugin-view.schema.json).
import 'dart:convert';

import 'models/download_link.dart';
import 'models/platform.dart';
import 'models/region.dart';
import 'models/rom_entry.dart';

/// At most this many results are asked of the local index per search.
/// (droidtop shows at most 200.)
const int maxSearchResults = 50;

/// Headers romgi's own downloader sends: several hosts throttle or refuse a
/// non-browser agent. Mirrors DownloadService._startDownload.
const Map<String, String> _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Accept': '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
};

/// A link droidtop's own DownloadManager can fetch as one file: plain
/// HTTP(S), no torrent, and nothing that needs an account (the Internet
/// Archive login is kept in the app's own secure storage, which the headless
/// engine does not use).
bool isDirectHttpLink(DownloadLink link) {
  if (link.isTorrent || link.requiresAuth) return false;
  final uri = Uri.tryParse(link.url);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// The links of [entry] a source job can hand to droidtop, in index order.
List<DownloadLink> directLinks(RomEntry entry) =>
    entry.links.where(isDirectHttpLink).toList(growable: false);

/// A file name droidtop accepts in a download descriptor
/// (`[A-Za-z0-9][A-Za-z0-9._-]*`, a bare name): the title with every other
/// character folded to `_`, plus the source file's extension.
String acquireFileName(String title, String sourceFileName) {
  final dot = sourceFileName.lastIndexOf('.');
  var extension = dot > 0 ? sourceFileName.substring(dot) : '';
  extension = extension.replaceAll(RegExp(r'[^A-Za-z0-9.]'), '');
  if (extension.length > 12 || extension == '.') extension = '';
  var stem = title
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'^[^A-Za-z0-9]+'), '')
      .replaceAll(RegExp(r'_+$'), '');
  if (stem.length > 120) stem = stem.substring(0, 120);
  if (stem.isEmpty) stem = 'download';
  return '$stem$extension';
}

/// The additive `download` reply of a contract 2 acquire job: droidtop
/// downloads [link] itself (DownloadManager, the Downloads list, its size cap
/// and a resumed connection) and places the file in the destination folder.
/// `size` is a cap, not an expectation, so it carries 10% headroom (and at
/// least 1 MiB) over the index's figure, which is not always exact.
Map<String, dynamic> acquireDownload(RomEntry entry, DownloadLink link) {
  final headers = Map<String, String>.of(_browserHeaders);
  final host = Uri.parse(link.url).host;
  if (host == 'myrient.erista.me') {
    // Same Referer and Origin DownloadService sends to avoid throttling.
    headers['Referer'] = 'https://myrient.erista.me/';
    headers['Origin'] = 'https://myrient.erista.me';
  }
  final descriptor = <String, dynamic>{
    'url': link.url,
    'headers': headers,
    'fileName': acquireFileName(entry.title, link.filename),
  };
  if (link.size > 0) {
    final headroom = link.size ~/ 10;
    descriptor['size'] = link.size + (headroom < 1048576 ? 1048576 : headroom);
  }
  return descriptor;
}

Map<String, dynamic> view(
  String title,
  List<Map<String, dynamic>> items, {
  String? subtitle,
}) =>
    {
      'view': 1,
      'title': title,
      'subtitle': subtitle,
      'sections': [
        {'id': 'main', 'items': items},
      ],
    };

/// `ui.settings` `view`: the index status and the one action the plugin needs.
Map<String, dynamic> settingsView({required bool indexReady, int? entries}) =>
    view('romgi', [
      {
        'type': 'info',
        'id': 'index',
        'title': 'Game index',
        'value': indexReady
            ? 'Downloaded${entries == null ? '' : ' · $entries games'}'
            : 'Not downloaded',
      },
      {
        'type': 'button',
        'id': 'download-index',
        'title': indexReady ? 'Update the game index' : 'Download the game index',
        'action': {
          'kind': 'job',
          'op': 'downloadIndex',
          'title': 'Download game index',
        },
      },
    ]);

/// `library.sources` `form`: the search field plus the platform and region
/// filters. [systemId] is droidtop's system id for the screen that opened the
/// form; it preselects the platform only when the index has that platform.
Map<String, dynamic> sourceForm({
  required String systemId,
  required List<Platform> platforms,
  required List<Region> regions,
}) {
  final platformOptions = <Map<String, dynamic>>[
    {'value': '', 'label': 'All platforms'},
    for (final p in platforms)
      {'value': p.id, 'label': '${p.brand} ${p.name}'.trim()},
  ];
  final selected = platforms.any((p) => p.id == systemId) ? systemId : '';
  return view('Search games', [
    {'type': 'text', 'id': 'query', 'title': 'Search', 'value': ''},
    {
      'type': 'choice',
      'id': 'platform',
      'title': 'Platform',
      'options': platformOptions,
      'value': selected,
    },
    {
      'type': 'choice',
      'id': 'region',
      'title': 'Region',
      'options': [
        {'value': '', 'label': 'Any region'},
        for (final r in regions) {'value': r.id, 'label': r.name},
      ],
      'value': '',
    },
  ]);
}

/// One `library.sources` `search` result. droidtop caps an action's args at
/// 16 KiB, so `ref` is only the slug; `detail` and `acquire` read the entry
/// back from the local index.
Map<String, dynamic> searchResult(RomEntry entry) {
  final direct = directLinks(entry).length;
  return {
    'id': entry.slug,
    'title': entry.title,
    'subtitle': entry.platform,
    'columns': [if (entry.regions.isNotEmpty) entry.regions.join(', ')],
    'badges': [
      if (direct > 0) '$direct ${direct == 1 ? 'download' : 'downloads'}',
    ],
    'platform': entry.platform,
    'ref': {'slug': entry.slug},
  };
}

/// `library.sources` `detail`: what the game is, a picker over the direct
/// downloads, and the one acquire job. Torrent and account-only links are
/// counted, not offered, until the plugin can run them (README).
Map<String, dynamic> detailView(RomEntry entry) {
  final links = directLinks(entry);
  final skipped = entry.links.length - links.length;
  final options = <Map<String, dynamic>>[
    for (var i = 0; i < links.length; i++)
      {
        'value': '$i',
        'label': [
          links[i].name,
          links[i].host,
          if (links[i].sizeStr.isNotEmpty) links[i].sizeStr,
        ].where((part) => part.isNotEmpty).join(' · '),
      },
  ];
  return view(entry.title, [
    {
      'type': 'info',
      'id': 'platform',
      'title': 'Platform',
      'value': entry.platform,
    },
    if (entry.regions.isNotEmpty)
      {
        'type': 'info',
        'id': 'regions',
        'title': 'Regions',
        'value': entry.regions.join(', '),
      },
    if (options.isNotEmpty) ...[
      {
        'type': 'choice',
        'id': 'link',
        'title': 'Download from',
        'options': options,
        'value': options.first['value'],
      },
      {
        'type': 'button',
        'id': 'acquire',
        'title': 'Download game',
        'action': {
          'kind': 'job',
          'op': 'acquire',
          'title': 'Download ${entry.title}',
          'args': {
            'ref': {'slug': entry.slug},
          },
        },
      },
    ] else
      {
        'type': 'info',
        'id': 'none',
        'title': 'No direct download',
        'subtitle': 'This game is only listed with torrent or sign-in sources.',
      },
    if (options.isNotEmpty && skipped > 0)
      {
        'type': 'info',
        'id': 'skipped',
        'title': 'Not offered here',
        'value':
            '$skipped torrent or sign-in ${skipped == 1 ? 'source' : 'sources'}',
      },
  ]);
}

/// A successful contract 2 `handle` reply.
String v2Data(Object data) => jsonEncode({'ok': true, 'data': data});

/// A failed contract 2 `handle` reply; [code] is one of droidtop's closed set
/// (INVALID_ARGS, UNSUPPORTED, NOT_FOUND, FAILED, ...).
String v2Error(String code, String message) => jsonEncode({
      'ok': false,
      'error': {'code': code, 'message': message},
    });
