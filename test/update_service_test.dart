import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/services/update_service.dart';

import 'debrid/debrid_test_utils.dart';

const _tag = 'build-main';
const _tagPath = '/repos/bi0shacker001/romgi/releases/tags/$_tag';

Map<String, dynamic> _release({int? build, String version = '1.7.3+12'}) => {
  'tag_name': _tag,
  'published_at': '2026-10-08T00:00:00Z',
  'body': [
    'Automated build from abc. Replaced on every push to `main`.',
    if (build != null) 'romgi-build: $build',
    if (build != null) 'romgi-version: $version',
  ].join('\n'),
  'assets': [
    {
      'name': 'romgi-main-debug.apk',
      'browser_download_url': 'https://example.com/romgi-main-debug.apk',
      'size': 2,
    },
    {
      'name': 'romgi-main-release.apk',
      'browser_download_url': 'https://example.com/romgi-main-release.apk',
      'size': 1,
    },
  ],
};

UpdateService _service(
  StubAdapter adapter, {
  String releaseTag = _tag,
  int buildNumber = 100,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return UpdateService(
    dio: dio,
    releaseTag: releaseTag,
    buildNumber: buildNumber,
  );
}

StubAdapter _serving(Map<String, dynamic> release) => StubAdapter({
  _tagPath: (_) => jsonBody(jsonEncode(release)),
});

void main() {
  group('AppRelease.fromGitHubJson', () {
    test('reads the build number and prefers the release APK', () {
      final release = AppRelease.fromGitHubJson(_release(build: 123));
      expect(release.buildNumber, 123);
      expect(release.version, '1.7.3+12 build 123');
      expect(
        release.apkDownloadUrl,
        'https://example.com/romgi-main-release.apk',
      );
      expect(release.apkSize, 1);
    });

    test('a release without a build line has no build number', () {
      final release = AppRelease.fromGitHubJson(_release());
      expect(release.buildNumber, isNull);
      expect(release.version, _tag);
    });
  });

  group('UpdateService.checkForUpdate', () {
    test('asks for its own branch release, not the repo-wide latest', () async {
      final adapter = _serving(_release(build: 101));
      await _service(adapter).checkForUpdate();
      expect(adapter.calls.single.uri.path, _tagPath);
    });

    test('offers a newer build on the same channel', () async {
      final update = await _service(_serving(_release(build: 101)))
          .checkForUpdate();
      expect(update?.buildNumber, 101);
    });

    test('the same or an older build is not an update', () async {
      expect(
        await _service(_serving(_release(build: 100))).checkForUpdate(),
        isNull,
      );
      expect(
        await _service(_serving(_release(build: 99))).checkForUpdate(),
        isNull,
      );
    });

    test('a release without a build number is not an update', () async {
      expect(await _service(_serving(_release())).checkForUpdate(), isNull);
    });

    test('a branch without a release is not an update', () async {
      final adapter = StubAdapter({
        _tagPath: (_) => jsonBody('{"message":"Not Found"}', 404),
      });
      expect(await _service(adapter).checkForUpdate(), isNull);
    });

    test('a failed request is an error, not "up to date"', () async {
      final adapter = StubAdapter({
        _tagPath: (_) => jsonBody('{"message":"rate limited"}', 403),
      });
      expect(_service(adapter).checkForUpdate(), throwsA(isA<DioException>()));
    });

    test('an unstamped build never checks', () async {
      final adapter = _serving(_release(build: 101));
      final service = _service(adapter, releaseTag: '', buildNumber: 0);
      expect(service.checksForUpdates, isFalse);
      expect(await service.checkForUpdate(), isNull);
      expect(adapter.calls, isEmpty);
    });
  });
}
