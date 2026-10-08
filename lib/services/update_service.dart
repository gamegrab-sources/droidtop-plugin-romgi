import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Where this build's updates come from, stamped in by CI
/// (.github/workflows/pr-checks.yml passes both as --dart-define).
///
/// This fork publishes one rolling GitHub release per branch, tagged
/// `build-<branch>` and replaced on every push, so neither GitHub's
/// "latest release" (whichever branch happened to publish last) nor the
/// pubspec version (unchanged between pushes) can tell an installed build
/// whether a newer one exists. The release tag names the build's own
/// channel and the CI run number orders builds within it.
class UpdateChannel {
  static const String releaseTag = String.fromEnvironment('ROMGI_RELEASE_TAG');
  static const int buildNumber = int.fromEnvironment('ROMGI_BUILD_NUMBER');
}

class AppRelease {
  final String version;
  final String tagName;
  final String? body;
  final String? apkDownloadUrl;
  final int? apkSize;
  final DateTime publishedAt;

  /// The CI run number the release's APKs were built by, from the
  /// `romgi-build: <n>` line CI writes into the release body; null for a
  /// release that does not carry one.
  final int? buildNumber;

  const AppRelease({
    required this.version,
    required this.tagName,
    this.body,
    this.apkDownloadUrl,
    this.apkSize,
    required this.publishedAt,
    this.buildNumber,
  });

  static final _buildLine = RegExp(r'^romgi-build:\s*(\d+)\s*$', multiLine: true);
  static final _versionLine = RegExp(r'^romgi-version:\s*(\S+)\s*$', multiLine: true);

  factory AppRelease.fromGitHubJson(Map<String, dynamic> json) {
    // A branch release carries both a debug and a release APK; the update
    // is the release one. Any other single .apk is taken as-is.
    final apks = (json['assets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .where((asset) => (asset['name'] as String? ?? '').endsWith('.apk'))
        .toList();
    final apk =
        apks
            .where(
              (asset) => (asset['name'] as String).endsWith('-release.apk'),
            )
            .firstOrNull ??
        apks
            .where((asset) => !(asset['name'] as String).contains('debug'))
            .firstOrNull;

    final tagName = json['tag_name'] as String? ?? '';
    final body = json['body'] as String?;
    final buildNumber = int.tryParse(
      _buildLine.firstMatch(body ?? '')?.group(1) ?? '',
    );
    final appVersion = _versionLine.firstMatch(body ?? '')?.group(1);

    final String version;
    if (appVersion != null && buildNumber != null) {
      version = '$appVersion build $buildNumber';
    } else if (buildNumber != null) {
      version = 'build $buildNumber';
    } else {
      version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
    }

    return AppRelease(
      version: version,
      tagName: tagName,
      body: body,
      apkDownloadUrl: apk?['browser_download_url'] as String?,
      apkSize: apk?['size'] as int?,
      publishedAt:
          DateTime.tryParse(json['published_at'] as String? ?? '') ??
          DateTime.now(),
      buildNumber: buildNumber,
    );
  }
}

class UpdateService {
  static const String _githubRepo = 'bi0shacker001/romgi';

  final Dio _dio;
  final String _releaseTag;
  final int _buildNumber;

  UpdateService({
    Dio? dio,
    String releaseTag = UpdateChannel.releaseTag,
    int buildNumber = UpdateChannel.buildNumber,
  }) : _dio = dio ?? Dio(),
       _releaseTag = releaseTag,
       _buildNumber = buildNumber;

  /// False for a build CI did not stamp with its channel: a local build, or
  /// the app embedded as a droidtop plugin, which droidtop updates as a
  /// bundle. It has nothing to compare against, so it never offers an APK.
  bool get checksForUpdates => _releaseTag.isNotEmpty && _buildNumber > 0;

  /// This build's own CI run number, 0 when unstamped.
  int get buildNumber => _buildNumber;

  Future<String> getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();

    return packageInfo.version;
  }

  /// This build's channel release, or null when the branch has none
  /// published. Network and API errors are thrown, so a failed check shows
  /// as failed rather than as "up to date".
  Future<AppRelease?> getChannelRelease() async {
    try {
      final response = await _dio.get(
        'https://api.github.com/repos/$_githubRepo/releases/tags/'
        '${Uri.encodeComponent(_releaseTag)}',
        options: Options(
          headers: {
            'Accept': 'application/vnd.github.v3+json',
            'User-Agent': 'romgi-app',
          },
        ),
      );
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw StateError('unexpected release response');
      }
      return AppRelease.fromGitHubJson(data);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// The newer build on this build's own channel, or null when there is
  /// none (or this build has no channel, see [checksForUpdates]).
  Future<AppRelease?> checkForUpdate() async {
    if (!checksForUpdates) return null;

    final release = await getChannelRelease();
    if (release == null ||
        release.apkDownloadUrl == null ||
        release.buildNumber == null) {
      return null;
    }

    return release.buildNumber! > _buildNumber ? release : null;
  }

  Future<String?> downloadUpdate(
    AppRelease release, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (release.apkDownloadUrl == null) return null;

    try {
      final tempDirectory = await getTemporaryDirectory();
      final suffix = release.buildNumber?.toString() ?? release.tagName;
      final apkPath = '${tempDirectory.path}/romgi-$suffix.apk';

      await _dio.download(
        release.apkDownloadUrl!,
        apkPath,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        options: Options(headers: {'User-Agent': 'romgi-app'}),
      );

      return apkPath;
    } catch (error) {
      return null;
    }
  }

  Future<bool> installApk(String apkPath) async {
    try {
      final result = await OpenFilex.open(apkPath);

      return result.type == ResultType.done;
    } catch (error) {
      return false;
    }
  }
}
