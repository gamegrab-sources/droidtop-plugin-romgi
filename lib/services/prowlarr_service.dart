import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';
import 'live_search_source.dart';

/// Live, on-demand search against a self-hosted Prowlarr instance —
/// Prowlarr itself aggregates whatever torrent indexers the user has
/// configured there. Same shape as `MacintoshGardenService`: queried live
/// at search time rather than baked into the offline catalog, since
/// there's no way to "own" someone else's Prowlarr/indexer setup ahead of
/// time the way the offline catalog pipeline owns Internet Archive
/// mirrors.
///
/// Downloading a result needs no special handling on romgi's side beyond
/// populating `torrentInfohash` correctly: any `DownloadLink` with that
/// field set already gets debrid-resolved automatically if the user has a
/// debrid provider configured (`DebridService`/`download_service.dart`),
/// or is dropped gracefully by `LinkResolver` if torrents are disabled and
/// no debrid provider is set up — both paths already exist and need no
/// Prowlarr-specific code.
class ProwlarrService {
  ProwlarrService({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ?? Dio(),
        _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final Dio _dio;
  final FlutterSecureStorage _storage;

  static const String _apiKeyStorageKey = 'prowlarr.api_key.v1';

  Future<String?> getApiKey() async {
    try {
      return await _storage.read(key: _apiKeyStorageKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> setApiKey(String apiKey) async {
    await _storage.write(key: _apiKeyStorageKey, value: apiKey.trim());
  }

  Future<void> clearApiKey() async {
    await _storage.delete(key: _apiKeyStorageKey);
  }

  /// Searches Prowlarr for torrent releases matching [query]. [baseUrl]
  /// should be the instance root (e.g. `http://localhost:9696`, no
  /// trailing path). Returns one [RomEntry] per release, each with a
  /// single torrent [DownloadLink]. Non-torrent (usenet) results are
  /// filtered out — romgi has no usenet download path.
  Future<List<RomEntry>> search({
    required String baseUrl,
    required String apiKey,
    required String query,
    int limit = 50,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || baseUrl.isEmpty || apiKey.isEmpty) return [];

    final url = '${_stripTrailingSlash(baseUrl)}/api/v1/search';
    final response = await _dio.get<List<dynamic>>(
      url,
      queryParameters: {
        'query': trimmed,
        'type': 'search',
        'limit': limit,
      },
      options: Options(headers: {'X-Api-Key': apiKey}),
    );

    final results = response.data ?? [];
    final entries = <RomEntry>[];
    for (final raw in results) {
      if (raw is! Map<String, dynamic>) continue;
      final entry = releaseToRomEntry(raw);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  static String _stripTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  // Same base64url-ish infohash shape zRIF/torrent tooling elsewhere in
  // this app already expects: 40 hex chars (SHA-1, the common case) or 32
  // base32 chars (rare, older BEP 3 encoding some indexers still emit).
  static final RegExp _magnetInfohashPattern = RegExp(
    r'xt=urn:btih:([a-fA-F0-9]{40}|[A-Za-z2-7]{32})',
  );

  /// Extracts a BitTorrent infohash from a magnet URI, or null if none is
  /// found. Only needed as a fallback — Prowlarr's `infoHash` field is
  /// usually already populated directly.
  static String? infohashFromMagnet(String magnetUri) {
    final match = _magnetInfohashPattern.firstMatch(magnetUri);
    return match?.group(1)?.toUpperCase();
  }

  /// Maps a single Prowlarr `ReleaseResource` (as raw decoded JSON) to a
  /// [RomEntry], or null if it's not a usable torrent result (wrong
  /// protocol, or no infohash available from either field).
  static RomEntry? releaseToRomEntry(Map<String, dynamic> release) {
    final protocol = (release['protocol'] as String? ?? '').toLowerCase();
    if (protocol != 'torrent') return null;

    final title = release['title'] as String?;
    if (title == null || title.isEmpty) return null;

    final infoHash = (release['infoHash'] as String?)?.trim();
    final magnetUrl = release['magnetUrl'] as String?;
    final resolvedHash = (infoHash != null && infoHash.isNotEmpty)
        ? infoHash.toUpperCase()
        : (magnetUrl != null ? infohashFromMagnet(magnetUrl) : null);
    if (resolvedHash == null) return null;

    final size = (release['size'] as num?)?.toInt() ?? 0;
    final indexer = release['indexer'] as String? ?? 'Prowlarr';
    final downloadUrl = release['downloadUrl'] as String? ?? magnetUrl ?? '';
    final infoUrl = release['infoUrl'] as String?;
    final guid = release['guid'] as String? ?? resolvedHash;
    final seeders = (release['seeders'] as num?)?.toInt();
    final leechers = (release['leechers'] as num?)?.toInt();

    return RomEntry(
      slug: slugFor(title, guid),
      title: title,
      platform: 'prowlarr',
      liveSource: ProwlarrLiveSource.sourceId,
      regions: const [],
      links: [
        DownloadLink(
          name: title,
          // No dedicated seeders/leechers field on DownloadLink — folded
          // into the existing type label (already rendered as a plain
          // text chip in entry_detail_screen.dart) rather than adding a
          // model field just for this one source.
          type: 'Torrent (${seeders ?? 0}↑/${leechers ?? 0}↓)',
          format: 'torrent',
          url: downloadUrl,
          filename: title,
          host: indexer,
          size: size,
          sizeStr: _sizeStr(size),
          sourceUrl: infoUrl ?? downloadUrl,
          sourceId: 'prowlarr',
          torrentInfohash: resolvedHash,
          // File index is unknown ahead of time for a live indexer
          // result — left null. The debrid path defaults an unset index
          // to 0 (fine for single-file releases; a known limitation for
          // multi-file ones, see the prowlarr-integration plan).
          torrentFileIndex: null,
        ),
      ],
    );
  }

  /// Unlike Macintosh Garden's slug (title+platform is enough to be
  /// stable/collision-compatible with the offline catalog), Prowlarr
  /// results for the same title can come from many different releases —
  /// the guid disambiguates them so two different releases of the same
  /// game don't collide onto one slug.
  static String slugFor(String title, String guid) {
    final t = title
        .replaceAll('+', ' plus ')
        .replaceAll('&', ' and ')
        .replaceAll('™', ' ')
        .replaceAll('©', ' ')
        .replaceAll('®', ' ');
    var slug = '$t-prowlarr-$guid'
        .replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '-')
        .toLowerCase();
    slug = slug.replaceAll(RegExp(r'-+'), '-');
    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    return slug;
  }

  static String _sizeStr(int bytes) {
    if (bytes <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}';
  }
}

/// Prowlarr as a [LiveSearchSource]: any query search, once a base URL is
/// set (the API key is read at search time; without one it adds nothing).
/// Prowlarr has no notion of romgi's platform/region filters, so it does
/// not look at them.
class ProwlarrLiveSource implements LiveSearchSource {
  ProwlarrLiveSource(this._service, {required this.baseUrl});

  static const String sourceId = 'prowlarr';

  final ProwlarrService _service;
  final String baseUrl;

  @override
  String get id => sourceId;

  @override
  bool appliesTo({
    required String query,
    required List<String> platforms,
    required List<String> regions,
    required bool retroAchievementsOnly,
  }) =>
      query.isNotEmpty && baseUrl.isNotEmpty;

  @override
  Future<List<RomEntry>> search(String query) async {
    try {
      final apiKey = await _service.getApiKey();
      if (apiKey == null || apiKey.isEmpty) return [];
      return await _service.search(
        baseUrl: baseUrl,
        apiKey: apiKey,
        query: query,
      );
    } catch (_) {
      // Best-effort — a Prowlarr hiccup shouldn't fail the whole search.
      return [];
    }
  }
}
