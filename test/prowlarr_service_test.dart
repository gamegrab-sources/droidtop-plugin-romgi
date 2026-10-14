import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/services/prowlarr_service.dart';

Map<String, dynamic> _release({
  String protocol = 'torrent',
  String title = 'Some.Game.Title',
  String? infoHash = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
  String? magnetUrl,
  String? downloadUrl = 'https://indexer.example/download/123',
  String? infoUrl = 'https://indexer.example/details/123',
  String guid = 'guid-123',
  String indexer = 'SomeIndexer',
  int size = 1024 * 1024 * 500,
  int? seeders = 12,
  int? leechers = 3,
}) {
  return {
    'protocol': protocol,
    'title': title,
    if (infoHash != null) 'infoHash': infoHash,
    if (magnetUrl != null) 'magnetUrl': magnetUrl,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (infoUrl != null) 'infoUrl': infoUrl,
    'guid': guid,
    'indexer': indexer,
    'size': size,
    if (seeders != null) 'seeders': seeders,
    if (leechers != null) 'leechers': leechers,
  };
}

void main() {
  group('ProwlarrService.releaseToRomEntry', () {
    test('maps a well-formed torrent release', () {
      final entry = ProwlarrService.releaseToRomEntry(_release());
      expect(entry, isNotNull);
      expect(entry!.title, 'Some.Game.Title');
      expect(entry.platform, 'prowlarr');
      expect(entry.liveSource, 'prowlarr');
      expect(entry.isLive, isTrue);
      expect(entry.links, hasLength(1));

      final link = entry.links.first;
      expect(link.torrentInfohash, 'ABCDEF0123456789ABCDEF0123456789ABCDEF01');
      expect(link.sourceId, 'prowlarr');
      expect(link.host, 'SomeIndexer');
      expect(link.type, contains('12'));
      expect(link.type, contains('3'));
      expect(link.torrentFileIndex, isNull);
    });

    test('filters out non-torrent (usenet) results', () {
      expect(
        ProwlarrService.releaseToRomEntry(_release(protocol: 'usenet')),
        isNull,
      );
    });

    test('falls back to parsing infoHash from magnetUrl when infoHash is absent',
        () {
      final entry = ProwlarrService.releaseToRomEntry(_release(
        infoHash: null,
        magnetUrl:
            'magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567&dn=Some+Game',
      ));
      expect(entry, isNotNull);
      expect(
        entry!.links.first.torrentInfohash,
        '0123456789ABCDEF0123456789ABCDEF01234567',
      );
    });

    test('returns null when neither infoHash nor a parseable magnetUrl exists',
        () {
      expect(
        ProwlarrService.releaseToRomEntry(_release(infoHash: null)),
        isNull,
      );
    });

    test('returns null for an empty title', () {
      expect(
        ProwlarrService.releaseToRomEntry(_release(title: '')),
        isNull,
      );
    });

    test('two different releases of the same title get different slugs', () {
      final a = ProwlarrService.releaseToRomEntry(_release(guid: 'guid-a'));
      final b = ProwlarrService.releaseToRomEntry(_release(guid: 'guid-b'));
      expect(a!.slug, isNot(b!.slug));
    });
  });

  group('ProwlarrService.infohashFromMagnet', () {
    test('extracts a 40-char hex infohash', () {
      expect(
        ProwlarrService.infohashFromMagnet(
          'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=x',
        ),
        '0123456789ABCDEF0123456789ABCDEF01234567',
      );
    });

    test('extracts a 32-char base32 infohash', () {
      expect(
        ProwlarrService.infohashFromMagnet(
          'magnet:?xt=urn:btih:ABCDEFGHIJKLMNOPQRSTUVWXYZ234567&dn=x',
        ),
        'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567',
      );
    });

    test('returns null for a non-magnet string', () {
      expect(ProwlarrService.infohashFromMagnet('not a magnet'), isNull);
    });
  });
}
