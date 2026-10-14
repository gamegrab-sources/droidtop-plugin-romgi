import 'package:dio/dio.dart';

import '../models/models.dart';
import 'internet_archive_auth_manager.dart';
import 'live_search_source.dart';

/// Live, on-demand search against Internet Archive's Macintosh Garden
/// mirror — classic Mac apps and games. Unlike the rest of the catalog
/// (one pre-built SQLite DB shipped with the app), this queries
/// archive.org directly at search time, the same way
/// `DownloadService._loadNoPayStationZrifs`/`_fetchVitaZrif` already
/// bypass the offline catalog for a live NoPayStation TSV lookup.
///
/// The mirror is organized as 54 fixed "bucket" items (one per starting
/// letter/digit, split Games vs Apps), each containing hundreds of
/// individual files — not one archive.org item per title. So "search" here
/// means: pick the bucket(s) matching the query's first letter, fetch (and
/// cache) that bucket's full file listing, and substring-match within it —
/// there's no item-level search API that would work for this shape of
/// data.
class MacintoshGardenService {
  MacintoshGardenService({required IAAuthManager auth, Dio? dio})
      : _auth = auth,
        _dio = dio ?? Dio();

  final IAAuthManager _auth;
  final Dio _dio;

  static const _letters = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '0',
  ];

  // The exact filter/extension set verified against ~2100 real Macintosh
  // Garden filenames (see the macintosh-garden branch's db/platforms.yml
  // and db/tests/test_internet_archive_scraper.py for the analysis this
  // was ported from). Unlike Python, Dart RegExp has no inline (?i) flag
  // syntax — caseSensitive: false below does the same job.
  static final RegExp _titlePattern = RegExp(
    r'^(.*?)(?:\.[A-Za-z0-9]+_)*\.(sit|sitx|zip|dmg|iso|toast|cdr|bin|cue|dsk|hqx|img)$',
    caseSensitive: false,
  );

  /// Extracts a clean title from a Macintosh Garden filename, or null if
  /// the file isn't a recognized content format (IA collections also
  /// carry incidental .torrent/.xml/.sqlite/.jpg metadata files).
  static String? cleanTitle(String filename) {
    final match = _titlePattern.firstMatch(filename);
    if (match == null) return null;
    final title = match.group(1);
    return (title == null || title.isEmpty) ? null : title;
  }

  /// Deterministic slug for a live Macintosh Garden result, matching the
  /// shape (not byte-for-byte the transliteration) of the catalog's own
  /// create_slug() (db/utils/parse_utils.py) — title-platform-regions,
  /// non-alphanumeric collapsed to single hyphens. Platform is always
  /// 'mac' and regions always empty for this source, so this reduces to
  /// title-mac-. No unidecode transliteration (no such package here);
  /// non-ASCII characters just fall through to the same hyphen
  /// replacement any other unmappable character would.
  static String slugFor(String title) {
    var t = title
        .replaceAll('+', ' plus ')
        .replaceAll('&', ' and ')
        .replaceAll('™', ' ')
        .replaceAll('©', ' ')
        .replaceAll('®', ' ');
    var slug = '$t-mac-'
        .replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '-')
        .toLowerCase();
    slug = slug.replaceAll(RegExp(r'-+'), '-');
    slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
    return slug;
  }

  static String _bucketId(String kind, String letter) =>
      'Macintosh_Garden_${kind}_Collection_$letter';

  final Map<String, List<_MacFile>> _bucketCache = {};
  final Map<String, DateTime> _bucketCacheAt = {};

  Future<List<_MacFile>> _loadBucket(String identifier, String type) async {
    final cachedAt = _bucketCacheAt[identifier];
    final cached = _bucketCache[identifier];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(hours: 24)) {
      return cached;
    }

    try {
      final headers = <String, dynamic>{};
      if (await _auth.isLoggedIn()) {
        await _auth.ensureFresh();
        await _auth.applyHeaders(headers);
      }
      final response = await _dio.get<Map<String, dynamic>>(
        'https://archive.org/metadata/$identifier',
        options: Options(headers: headers),
      );
      final files = (response.data?['files'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>();

      final result = <_MacFile>[];
      for (final f in files) {
        final name = f['name'] as String?;
        if (name == null) continue;
        final title = cleanTitle(name);
        if (title == null) continue;
        final size = int.tryParse('${f['size']}') ?? 0;
        result.add(_MacFile(
          identifier: identifier,
          filename: name,
          title: title,
          type: type,
          size: size,
        ));
      }

      _bucketCache[identifier] = result;
      _bucketCacheAt[identifier] = DateTime.now();
      return result;
    } catch (_) {
      // Best-effort — a stale cache (or an empty list on first-ever
      // failure) is better than surfacing a hard error for one bucket.
      return cached ?? [];
    }
  }

  static String _letterFor(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return '0';
    final first = trimmed[0].toUpperCase();
    return _letters.contains(first) ? first : '0';
  }

  /// Searches the Games + Apps buckets matching [query]'s starting letter.
  /// Only the first-letter bucket is fetched (cached after first use) —
  /// this mirrors how the mirror itself is organized, so it's both the
  /// natural and the cheapest scope for a live per-search lookup.
  Future<List<RomEntry>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];
    final letter = _letterFor(trimmed);
    final lowerQuery = trimmed.toLowerCase();

    final results = await Future.wait([
      _loadBucket(_bucketId('Games', letter), 'Game'),
      _loadBucket(_bucketId('Apps', letter), 'App'),
    ]);

    final matches = [...results[0], ...results[1]]
        .where((f) => f.title.toLowerCase().contains(lowerQuery))
        .toList();

    return matches.map((f) => f.toRomEntry()).toList();
  }
}

class _MacFile {
  const _MacFile({
    required this.identifier,
    required this.filename,
    required this.title,
    required this.type,
    required this.size,
  });

  final String identifier;
  final String filename;
  final String title;
  final String type;
  final int size;

  RomEntry toRomEntry() {
    final url =
        'https://archive.org/download/$identifier/${Uri.encodeComponent(filename)}';
    return RomEntry(
      slug: MacintoshGardenService.slugFor(title),
      title: title,
      platform: 'mac',
      liveSource: MacintoshGardenLiveSource.sourceId,
      regions: const [],
      links: [
        DownloadLink(
          name: title,
          type: type,
          format: 'mac',
          url: url,
          filename: filename,
          host: 'archive.org',
          size: size,
          sizeStr: _sizeStr(size),
          sourceUrl: 'https://archive.org/details/$identifier',
          sourceId: 'internet_archive',
        ),
      ],
    );
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

/// Macintosh Garden as a [LiveSearchSource]: unfiltered title searches only,
/// since the mirror has no live equivalent of the platform, region or
/// RetroAchievements filters.
class MacintoshGardenLiveSource implements LiveSearchSource {
  MacintoshGardenLiveSource(this._service);

  static const String sourceId = 'macintosh_garden';

  final MacintoshGardenService _service;

  @override
  String get id => sourceId;

  @override
  bool appliesTo({
    required String query,
    required List<String> platforms,
    required List<String> regions,
    required bool retroAchievementsOnly,
  }) =>
      query.isNotEmpty &&
      platforms.isEmpty &&
      regions.isEmpty &&
      !retroAchievementsOnly;

  @override
  Future<List<RomEntry>> search(String query) =>
      _service.search(query).catchError((Object _) => <RomEntry>[]);
}
