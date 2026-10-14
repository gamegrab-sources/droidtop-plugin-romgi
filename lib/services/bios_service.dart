import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// BIOS, firmware and key files emulators ask for: which files a system
/// needs, whether they are in the user's BIOS folder, and where to get the
/// right dump.
///
/// This is the logic of the gamegrab-sources BIOS plugin
/// (github.com/gamegrab-sources/droidtop-plugin-bios, `src/plugin.py`) in
/// the app. The file list is that repository's `data/index.json`, generated
/// there by `tools/gen_index.py` (from droidtop-platforms' BIOS database,
/// Abdess/retrobios and the Internet Archive's `retroarch_bios`, plus the 3DS
/// and Switch keys); the app downloads it like it downloads its game index,
/// so there is one generator and one list.
class BiosService {
  BiosService({Dio? dio, Future<Directory> Function()? cacheDirectory})
      : _dio = dio ?? Dio(),
        _cacheDirectory = cacheDirectory;

  final Dio _dio;
  final Future<Directory> Function()? _cacheDirectory;

  static const String indexUrl =
      'https://raw.githubusercontent.com/gamegrab-sources/droidtop-plugin-bios/main/data/index.json';
  static const String retrobiosRaw =
      'https://raw.githubusercontent.com/Abdess/retrobios/main/';
  static const String iaDownload = 'https://archive.org/download/';
  static const String iaMetadata = 'https://archive.org/metadata/';

  /// How long a downloaded index is used before it is fetched again.
  static const Duration indexMaxAge = Duration(days: 7);

  /// Files larger than this are reported as present without reading them
  /// through for their MD5 (a Switch firmware package is hundreds of MB).
  static const int maxHashedSize = 64 * 1024 * 1024;

  static const String _indexCacheFile = 'bios-index.json';

  BiosIndex? _index;
  final Map<String, Map<String, IaFileInfo>?> _iaListings = {};

  // ------------------------------------------------------------------ index

  /// The file list: memory, then the cached copy while it is fresh, then the
  /// network; a cached copy of any age when the network fails.
  Future<BiosIndex> loadIndex({bool refresh = false}) async {
    if (!refresh && _index != null) return _index!;
    final cache = await _cacheFile();
    if (!refresh && cache != null && await cache.exists()) {
      final age = DateTime.now().difference(await cache.lastModified());
      if (age < indexMaxAge) {
        final cached = await _readIndex(cache);
        if (cached != null) return _index = cached;
      }
    }
    try {
      final response = await _dio.get<String>(
        indexUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data ?? '';
      final index = BiosIndex.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (cache != null) {
        await cache.parent.create(recursive: true);
        await cache.writeAsString(body, flush: true);
      }
      return _index = index;
    } catch (error) {
      final cached = cache != null && await cache.exists()
          ? await _readIndex(cache)
          : null;
      if (cached != null) return _index = cached;
      throw BiosException(
        'Could not download the BIOS file list. Check the connection and '
        'try again.',
      );
    }
  }

  Future<File?> _cacheFile() async {
    final dir = _cacheDirectory;
    if (dir == null) return null;
    return File(p.join((await dir()).path, _indexCacheFile));
  }

  static Future<BiosIndex?> _readIndex(File file) async {
    try {
      return BiosIndex.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------- system ids

  /// romgi's platform ids where the BIOS list (Batocera's ids) names the
  /// system differently. Ids that are the same in both need no entry.
  static const Map<String, String> platformAliases = {
    'ps1': 'psx',
    'psv': 'psvita',
    'vita': 'psvita',
    'gc': 'gamecube',
    'ds': 'nds',
    'n3ds': '3ds',
    'new3ds': '3ds',
    'ndd': 'n64dd',
    'scd': 'segacd',
    'megacd': 'segacd',
    'sat': 'saturn',
    'dc': 'dreamcast',
    'pce': 'pcengine',
    'tg16': 'pcengine',
    'tgcd': 'pcengine',
    'pcenginecd': 'pcengine',
    'sgx': 'supergrafx',
    'ng': 'neogeo',
    'ngcd': 'neogeocd',
    'cv': 'colecovision',
    'intv': 'intellivision',
    'a52': 'atari5200',
    'amiga': 'amiga500',
    'fmt': 'fmtowns',
    'mac': 'macintosh',
  };

  /// The BIOS list's id for a romgi platform, or null when the list has no
  /// files for it.
  static String? systemIdFor(String platform, BiosIndex index) {
    final key = platform.trim().toLowerCase();
    final id = platformAliases[key] ?? key;
    return index.systems.containsKey(id) ? id : null;
  }

  // ---------------------------------------------------------------- placing

  /// Where [file] goes inside the BIOS folder [biosRoot]. The list keeps
  /// Batocera's layout: `bios/...` is the BIOS folder itself (RetroArch's
  /// system folder), other dirs (`sysdata`, `keys`, `firmware`) are
  /// subfolders of it.
  static String targetPath(String biosRoot, BiosFile file) {
    var dir = file.dir.replaceAll('\\', '/');
    if (dir == 'bios') {
      dir = '';
    } else if (dir.startsWith('bios/')) {
      dir = dir.substring(5);
    }
    final parts = dir.split('/').where((s) => s.isNotEmpty && s != '..');
    return p.joinAll([biosRoot, ...parts, safeFileName(file.name)]);
  }

  static final RegExp _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+ -]*$');

  static String safeFileName(String name) {
    if (_safeName.hasMatch(name)) return name;
    final cleaned = name
        .replaceAll(RegExp(r'[^A-Za-z0-9._+ -]'), '_')
        .replaceFirst(RegExp(r'^[._ -]+'), '');
    return cleaned.isEmpty ? 'bios.bin' : cleaned;
  }

  // ----------------------------------------------------------------- status

  /// Whether [file] is in [biosRoot], and whether it is one of the dumps the
  /// list accepts.
  Future<BiosFileState> fileState(String biosRoot, BiosFile file) async {
    final target = File(targetPath(biosRoot, file));
    if (!await target.exists()) return BiosFileState.missing;
    if (file.md5.isEmpty) return BiosFileState.present;
    final size = await target.length();
    if (size > maxHashedSize) return BiosFileState.present;
    final digest = await md5.bind(target.openRead()).first;
    return file.md5.contains(digest.toString())
        ? BiosFileState.verified
        : BiosFileState.otherDump;
  }

  Future<BiosSystemStatus> systemStatus(
    String biosRoot,
    String systemId,
    BiosSystem system,
  ) async {
    final states = <String, BiosFileState>{};
    for (final file in system.files) {
      states[file.name] = await fileState(biosRoot, file);
    }
    return BiosSystemStatus(systemId: systemId, system: system, states: states);
  }

  // ---------------------------------------------------------------- sources

  /// Every way to get [file], right dumps first, then those whose bytes can
  /// be checked by SHA-256 (the plugin's order).
  Future<List<BiosCandidate>> candidates(
    String systemId,
    BiosFile file,
    BiosSourceSettings settings,
  ) async {
    final out = <BiosCandidate>[];
    final expected = file.md5.toSet();
    for (final src in file.sources) {
      if (src.kind == 'retrobios' && settings.retrobiosEnabled) {
        out.add(BiosCandidate(
          key: 'rb:${src.path}',
          label: 'retrobios (GitHub)',
          url: retrobiosRaw + _encodePath(src.path ?? ''),
          exact: src.exact,
          size: src.size,
          sha256: src.sha256 ?? '',
          md5: src.md5 ?? '',
        ));
      } else if (src.kind == 'ia') {
        out.add(BiosCandidate(
          key: 'ia:${src.item}/${src.name}',
          label: 'Internet Archive: ${src.item}',
          url: '$iaDownload${Uri.encodeComponent(src.item ?? '')}/'
              '${_encodePath(src.name ?? '')}',
          exact: src.exact,
          size: src.size,
          md5: src.md5 ?? '',
        ));
      }
    }
    final seen = out.map((c) => c.key).toSet();
    for (final itemId in settings.iaItems) {
      final listing = await _iaListing(itemId);
      if (listing == null) continue;
      for (final entry in listing.entries) {
        final name = entry.key;
        final info = entry.value;
        final sameName =
            name.toLowerCase().split('/').last == file.name.toLowerCase();
        final exact = info.md5.isNotEmpty && expected.contains(info.md5);
        if (!exact && !sameName) continue;
        final key = 'ia:$itemId/$name';
        if (!seen.add(key)) continue;
        out.add(BiosCandidate(
          key: key,
          label: 'Internet Archive: $itemId',
          url: '$iaDownload${Uri.encodeComponent(itemId)}/${_encodePath(name)}',
          exact: exact,
          size: info.size,
          md5: info.md5,
        ));
      }
    }
    for (var i = 0; i < settings.urlTemplates.length; i++) {
      final template = settings.urlTemplates[i];
      out.add(BiosCandidate(
        key: 'url:$i',
        label: 'Your source',
        url: expandTemplate(template, systemId, file),
        exact: false,
        note: 'your own address',
      ));
    }
    // Stable sort: right dumps first, then the ones that can be checked.
    final indexed = out.asMap().entries.toList()
      ..sort((a, b) {
        final ka = (a.value.exact ? 0 : 2) + (a.value.sha256.isNotEmpty ? 0 : 1);
        final kb = (b.value.exact ? 0 : 2) + (b.value.sha256.isNotEmpty ? 0 : 1);
        return ka != kb ? ka - kb : a.key - b.key;
      });
    return [for (final e in indexed) e.value];
  }

  /// A user's address template: `{file}`, `{system}` and `{md5}` stand for
  /// the file's name, the system id and its first accepted MD5.
  static String expandTemplate(String template, String systemId, BiosFile file) {
    final firstMd5 = file.md5.isEmpty ? '' : file.md5.first;
    return template
        .replaceAll('{file}', Uri.encodeComponent(file.name))
        .replaceAll('{system}', Uri.encodeComponent(systemId))
        .replaceAll('{md5}', firstMd5);
  }

  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  static final RegExp _iaId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$');

  static bool isValidIaItem(String id) => _iaId.hasMatch(id);

  /// The files an Internet Archive item holds, name -> md5/size; null when
  /// it cannot be listed.
  Future<Map<String, IaFileInfo>?> _iaListing(String itemId) async {
    if (_iaListings.containsKey(itemId)) return _iaListings[itemId];
    Map<String, IaFileInfo>? listing;
    if (isValidIaItem(itemId)) {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '$iaMetadata${Uri.encodeComponent(itemId)}/files',
        );
        final rows = response.data?['result'] as List<dynamic>? ?? const [];
        listing = {};
        for (final row in rows.whereType<Map<String, dynamic>>()) {
          final name = row['name'] as String?;
          if (name == null || name.isEmpty) continue;
          listing[name] = IaFileInfo(
            md5: ((row['md5'] as String?) ?? '').toLowerCase(),
            size: int.tryParse('${row['size'] ?? ''}') ?? 0,
          );
        }
      } catch (_) {
        listing = null;
      }
    }
    _iaListings[itemId] = listing;
    return listing;
  }

  // --------------------------------------------------------------- download

  /// Downloads [file] from [candidate] into [biosRoot]: asks the source once
  /// whether the file is there with the right size, downloads next to the
  /// target, checks the size and the SHA-256 or MD5 the source lists, and
  /// only then moves it into place. Returns the file's path.
  Future<String> download({
    required String biosRoot,
    required BiosFile file,
    required BiosCandidate candidate,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _preflight(candidate);
    final targetPath = BiosService.targetPath(biosRoot, file);
    final partPath = '$targetPath.part';
    await Directory(p.dirname(targetPath)).create(recursive: true);
    try {
      await _dio.download(
        candidate.url,
        partPath,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
    } on DioException catch (error) {
      await _deleteQuietly(partPath);
      if (CancelToken.isCancel(error)) rethrow;
      throw BiosException(
        '${candidate.label} did not send ${file.name}: '
        '${error.message ?? error.type.name}',
      );
    }
    final part = File(partPath);
    final problem = await verify(part, file, candidate);
    if (problem != null) {
      await _deleteQuietly(partPath);
      throw BiosException(problem);
    }
    final existing = File(targetPath);
    if (await existing.exists()) await existing.delete();
    await part.rename(targetPath);
    return targetPath;
  }

  /// Checks a downloaded file against what the source promised: its size,
  /// then its SHA-256, or its MD5 for a source holding a listed dump. A
  /// plain-language problem, or null when it is right.
  static Future<String?> verify(
    File downloaded,
    BiosFile file,
    BiosCandidate candidate,
  ) async {
    final size = await downloaded.length();
    if (candidate.size > 0 && size != candidate.size) {
      return '${file.name} from ${candidate.label} has $size bytes, not '
          '${candidate.size}; it was not kept';
    }
    if (candidate.sha256.isNotEmpty) {
      final digest = await sha256.bind(downloaded.openRead()).first;
      if (digest.toString() != candidate.sha256.toLowerCase()) {
        return '${file.name} from ${candidate.label} is not the file its '
            'SHA-256 names; it was not kept';
      }
    } else if (candidate.exact && candidate.md5.isNotEmpty) {
      final digest = await md5.bind(downloaded.openRead()).first;
      if (digest.toString() != candidate.md5.toLowerCase()) {
        return '${file.name} from ${candidate.label} is not the dump its MD5 '
            'names; it was not kept';
      }
    }
    return null;
  }

  /// One HEAD request: is the file there, and is its size the expected one.
  /// Skipped for a user's own address, which is fetched as it is.
  Future<void> _preflight(BiosCandidate candidate) async {
    if (candidate.key.startsWith('url:')) return;
    Response<dynamic> response;
    try {
      response = await _dio.head<dynamic>(
        candidate.url,
        options: Options(
          followRedirects: true,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (error) {
      throw BiosException(
        '${candidate.label} did not answer: ${error.message ?? error.type.name}',
      );
    }
    if (response.statusCode == 404) {
      throw BiosException('${candidate.label} no longer has this file');
    }
    final length = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (response.statusCode == 200 &&
        candidate.size > 0 &&
        length != null &&
        length != 0 &&
        length != candidate.size) {
      throw BiosException(
        '${candidate.label} offers a file of another size than expected '
        '($length bytes, not ${candidate.size})',
      );
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

// ------------------------------------------------------------------- models

class BiosIndex {
  const BiosIndex({required this.systems});

  final Map<String, BiosSystem> systems;

  factory BiosIndex.fromJson(Map<String, dynamic> json) {
    final raw = json['systems'] as Map<String, dynamic>? ?? const {};
    return BiosIndex(systems: {
      for (final e in raw.entries)
        if (e.value is Map<String, dynamic>)
          e.key: BiosSystem.fromJson(e.value as Map<String, dynamic>),
    });
  }
}

class BiosSystem {
  const BiosSystem({required this.name, required this.files});

  final String name;
  final List<BiosFile> files;

  factory BiosSystem.fromJson(Map<String, dynamic> json) => BiosSystem(
        name: json['name'] as String? ?? '',
        files: (json['files'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(BiosFile.fromJson)
            .toList(),
      );
}

class BiosFile {
  const BiosFile({
    required this.name,
    required this.dir,
    required this.md5,
    required this.sources,
    this.note,
  });

  final String name;
  final String dir;

  /// Every accepted dump's MD5, lower case.
  final List<String> md5;
  final List<BiosSourceRef> sources;
  final String? note;

  factory BiosFile.fromJson(Map<String, dynamic> json) => BiosFile(
        name: json['name'] as String,
        dir: json['dir'] as String? ?? 'bios',
        md5: (json['md5'] as List<dynamic>? ?? const [])
            .map((m) => '$m'.toLowerCase())
            .toList(),
        sources: (json['src'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(BiosSourceRef.fromJson)
            .toList(),
        note: json['note'] as String?,
      );
}

/// One place the list knows holds a file: `retrobios` (by [path], with
/// SHA-256) or `ia` (an Internet Archive [item] and file [name]).
class BiosSourceRef {
  const BiosSourceRef({
    required this.kind,
    required this.exact,
    this.path,
    this.item,
    this.name,
    this.size = 0,
    this.sha256,
    this.md5,
  });

  final String kind;
  final bool exact;
  final String? path;
  final String? item;
  final String? name;
  final int size;
  final String? sha256;
  final String? md5;

  factory BiosSourceRef.fromJson(Map<String, dynamic> json) => BiosSourceRef(
        kind: json['kind'] as String? ?? '',
        exact: json['exact'] as bool? ?? false,
        path: json['path'] as String?,
        item: json['item'] as String?,
        name: json['name'] as String?,
        size: (json['size'] as num?)?.toInt() ?? 0,
        sha256: (json['sha256'] as String?)?.toLowerCase(),
        md5: (json['md5'] as String?)?.toLowerCase(),
      );
}

/// One way to get a file: where, whether it is a listed dump, and what can
/// be checked after downloading it.
class BiosCandidate {
  const BiosCandidate({
    required this.key,
    required this.label,
    required this.url,
    required this.exact,
    this.size = 0,
    this.sha256 = '',
    this.md5 = '',
    this.note = '',
  });

  final String key;
  final String label;
  final String url;
  final bool exact;
  final int size;
  final String sha256;
  final String md5;
  final String note;

  /// "retrobios (GitHub) · checked by SHA-256 · 512 KB".
  String describe() {
    final parts = <String>[label];
    if (sha256.isNotEmpty) {
      parts.add('checked by SHA-256');
    } else if (exact) {
      parts.add('listed with the right MD5');
    } else {
      parts.add('a different dump, unchecked');
    }
    if (size > 0) parts.add(sizeText(size));
    return parts.join(' · ');
  }

  static String sizeText(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
  }
}

class IaFileInfo {
  const IaFileInfo({required this.md5, required this.size});

  final String md5;
  final int size;
}

/// The user's source options (Settings > BIOS and system files), with the
/// plugin's defaults: retrobios on, no extra Internet Archive items, no
/// addresses of their own.
class BiosSourceSettings {
  const BiosSourceSettings({
    this.retrobiosEnabled = true,
    this.iaItems = const [],
    this.urlTemplates = const [],
  });

  final bool retrobiosEnabled;
  final List<String> iaItems;
  final List<String> urlTemplates;
}

enum BiosFileState {
  /// Not in the BIOS folder.
  missing,

  /// There, and its MD5 is one the list accepts.
  verified,

  /// There, not checked (the list has no MD5 for it, or it is too large to
  /// read through).
  present,

  /// There, but a dump the list does not accept.
  otherDump,
}

class BiosSystemStatus {
  const BiosSystemStatus({
    required this.systemId,
    required this.system,
    required this.states,
  });

  final String systemId;
  final BiosSystem system;
  final Map<String, BiosFileState> states;

  int get total => system.files.length;

  int get present => states.values
      .where((s) => s == BiosFileState.verified || s == BiosFileState.present)
      .length;

  bool get complete => present == total;
}

class BiosException implements Exception {
  BiosException(this.message);

  final String message;

  @override
  String toString() => message;
}
