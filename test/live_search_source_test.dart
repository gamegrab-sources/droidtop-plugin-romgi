import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/services/internet_archive_auth_manager.dart';
import 'package:romgi/services/live_search_source.dart';
import 'package:romgi/services/macintosh_garden_service.dart';
import 'package:romgi/services/prowlarr_service.dart';

bool _applies(
  LiveSearchSource source, {
  String query = 'doom',
  List<String> platforms = const [],
  List<String> regions = const [],
  bool ra = false,
}) =>
    source.appliesTo(
      query: query,
      platforms: platforms,
      regions: regions,
      retroAchievementsOnly: ra,
    );

void main() {
  group('ProwlarrLiveSource', () {
    test('applies to any query search once a base URL is set', () {
      final source = ProwlarrLiveSource(
        ProwlarrService(),
        baseUrl: 'http://localhost:9696',
      );
      expect(source.id, 'prowlarr');
      expect(_applies(source), isTrue);
      expect(_applies(source, platforms: ['snes']), isTrue);
      expect(_applies(source, query: ''), isFalse);
    });

    test('adds nothing without a base URL', () {
      final source = ProwlarrLiveSource(ProwlarrService(), baseUrl: '');
      expect(_applies(source), isFalse);
    });
  });

  group('MacintoshGardenLiveSource', () {
    final source = MacintoshGardenLiveSource(
      MacintoshGardenService(auth: IAAuthManager()),
    );

    test('applies only to unfiltered title searches', () {
      expect(source.id, 'macintosh_garden');
      expect(_applies(source), isTrue);
      expect(_applies(source, query: ''), isFalse);
      expect(_applies(source, platforms: ['mac']), isFalse);
      expect(_applies(source, regions: ['us']), isFalse);
      expect(_applies(source, ra: true), isFalse);
    });
  });

  test('every live source has a badge name', () {
    expect(liveSourceName(ProwlarrLiveSource.sourceId), 'Prowlarr');
    expect(
      liveSourceName(MacintoshGardenLiveSource.sourceId),
      'Internet Archive',
    );
  });
}
