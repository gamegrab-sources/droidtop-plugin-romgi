import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/droidtop_plugin_logic.dart';
import 'package:romgi/models/download_link.dart';
import 'package:romgi/models/platform.dart';
import 'package:romgi/models/region.dart';
import 'package:romgi/models/rom_entry.dart';

DownloadLink link({
  String url = 'https://example.org/files/game.zip',
  String filename = 'game.zip',
  int size = 0,
  bool requiresAuth = false,
  String? infohash,
  String name = 'Mirror',
  String host = 'example.org',
  String sizeStr = '',
}) =>
    DownloadLink(
      name: name,
      type: 'Game',
      format: 'zip',
      url: url,
      filename: filename,
      host: host,
      size: size,
      sizeStr: sizeStr,
      sourceUrl: '',
      requiresAuth: requiresAuth,
      torrentInfohash: infohash,
    );

RomEntry entry(List<DownloadLink> links, {String title = 'Some Game (USA)'}) =>
    RomEntry(
      slug: 'some-game-usa',
      title: title,
      platform: 'snes',
      regions: const ['USA'],
      links: links,
    );

final RegExp descriptorName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

void main() {
  group('acquireFileName', () {
    test('folds a title into a name droidtop accepts and keeps the extension', () {
      final name = acquireFileName("Zelda: Link's Awakening (USA) [!]", 'zelda.7z');
      expect(name, matches(descriptorName));
      expect(name, endsWith('.7z'));
      expect(name, startsWith('Zelda_Link_s_Awakening_USA'));
    });

    test('never starts with a separator and never carries a path', () {
      for (final title in ['../../etc/passwd', '/abs/path', '.hidden', '___', '']) {
        final name = acquireFileName(title, 'a.zip');
        expect(name, matches(descriptorName), reason: title);
        expect(name.contains('/'), isFalse);
        expect(name.contains('..'), isFalse, reason: title);
      }
    });

    test('drops a hostile or oversized extension', () {
      expect(acquireFileName('Game', 'x.z ip;rm'), matches(descriptorName));
      expect(acquireFileName('Game', 'x.${'a' * 40}'), 'Game');
      expect(acquireFileName('Game', 'noextension'), 'Game');
    });
  });

  group('direct links', () {
    test('plain http and https count; torrents, accounts and other schemes do not', () {
      expect(isDirectHttpLink(link()), isTrue);
      expect(isDirectHttpLink(link(url: 'http://example.org/a.zip')), isTrue);
      expect(isDirectHttpLink(link(infohash: 'abc')), isFalse);
      expect(isDirectHttpLink(link(requiresAuth: true)), isFalse);
      expect(isDirectHttpLink(link(url: 'magnet:?xt=urn:btih:abc')), isFalse);
      expect(isDirectHttpLink(link(url: 'file:///sdcard/a.zip')), isFalse);
      expect(isDirectHttpLink(link(url: 'https:///nohost')), isFalse);
    });

    test('a debrid-resolved torrent link is a direct link again', () {
      expect(isDirectHttpLink(link(infohash: 'abc').copyWith(debridResolved: true)), isTrue);
    });
  });

  group('acquireDownload', () {
    test('carries the url, browser headers and a bare file name', () {
      final d = acquireDownload(entry([link()]), link());
      expect(d['url'], 'https://example.org/files/game.zip');
      expect(d['fileName'], matches(descriptorName));
      expect((d['headers'] as Map)['User-Agent'], contains('Mozilla'));
      expect(d.containsKey('size'), isFalse);
      // The reply is JSON text in a job result.
      expect(() => jsonEncode(d), returnsNormally);
    });

    test('size is a cap with headroom over the index figure', () {
      final small = acquireDownload(entry([]), link(size: 1000));
      expect(small['size'], 1000 + 1048576);
      final big = acquireDownload(entry([]), link(size: 1000 * 1048576));
      expect(big['size'], 1100 * 1048576);
    });

    test('Myrient gets the Referer and Origin romgi sends itself', () {
      final d = acquireDownload(
        entry([]),
        link(url: 'https://myrient.erista.me/files/No-Intro/x.zip'),
      );
      final headers = d['headers'] as Map;
      expect(headers['Referer'], 'https://myrient.erista.me/');
      expect(headers['Origin'], 'https://myrient.erista.me');
    });

    test('other hosts get no Referer', () {
      expect((acquireDownload(entry([]), link())['headers'] as Map).containsKey('Referer'), isFalse);
    });
  });

  group('views', () {
    test('the form preselects the opening system only when the index has it', () {
      const platforms = [
        Platform(id: 'snes', brand: 'Nintendo', name: 'SNES'),
        Platform(id: 'gb', brand: 'Nintendo', name: 'Game Boy'),
      ];
      const regions = [Region(id: 'usa', name: 'USA')];
      Map<String, dynamic> choice(Map<String, dynamic> form, String id) =>
          ((form['sections'] as List).first['items'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere((item) => item['id'] == id);

      final known = sourceForm(systemId: 'snes', platforms: platforms, regions: regions);
      expect(choice(known, 'platform')['value'], 'snes');
      expect((choice(known, 'platform')['options'] as List).length, 3);
      expect(choice(known, 'region')['value'], '');

      final unknown = sourceForm(systemId: 'dreamcast', platforms: platforms, regions: regions);
      expect(choice(unknown, 'platform')['value'], '');
      expect(choice(unknown, 'query')['type'], 'text');
    });

    test('a search result refers to its game by slug only', () {
      final result = searchResult(entry([link(), link(infohash: 'abc')]));
      expect(result['ref'], {'slug': 'some-game-usa'});
      expect(result['badges'], ['1 download']);
      expect(result['id'], 'some-game-usa');
      expect(jsonEncode(result).length, lessThan(1024));
    });

    test('detail offers the direct links and one acquire job, and counts the rest', () {
      final view = detailView(entry([
        link(name: 'A', sizeStr: '1 MB'),
        link(infohash: 'abc'),
        link(requiresAuth: true),
      ]));
      final items = ((view['sections'] as List).first['items'] as List).cast<Map<String, dynamic>>();
      final pick = items.firstWhere((i) => i['id'] == 'link');
      expect((pick['options'] as List).length, 1);
      expect(pick['value'], '0');
      final button = items.firstWhere((i) => i['id'] == 'acquire');
      expect(button['action']['kind'], 'job');
      expect(button['action']['op'], 'acquire');
      expect(button['action']['args'], {'ref': {'slug': 'some-game-usa'}});
      expect(items.firstWhere((i) => i['id'] == 'skipped')['value'], '2 torrent or sign-in sources');
    });

    test('detail of a torrent-only game says so and offers no job', () {
      final view = detailView(entry([link(infohash: 'abc')]));
      final items = ((view['sections'] as List).first['items'] as List).cast<Map<String, dynamic>>();
      expect(items.any((i) => i['id'] == 'acquire'), isFalse);
      expect(items.any((i) => i['id'] == 'none'), isTrue);
    });

    test('the settings view offers the index download whatever its state', () {
      for (final ready in [true, false]) {
        final view = settingsView(indexReady: ready, entries: ready ? 12 : null);
        final items = ((view['sections'] as List).first['items'] as List).cast<Map<String, dynamic>>();
        expect(items.firstWhere((i) => i['id'] == 'index')['value'], ready ? 'Downloaded · 12 games' : 'Not downloaded');
        expect(items.firstWhere((i) => i['id'] == 'download-index')['action']['op'], 'downloadIndex');
      }
    });
  });

  group('replies', () {
    test('success and failure have the shapes droidtop reads', () {
      expect(jsonDecode(v2Data({'a': 1})), {'ok': true, 'data': {'a': 1}});
      expect(jsonDecode(v2Error('FAILED', 'no')), {
        'ok': false,
        'error': {'code': 'FAILED', 'message': 'no'},
      });
    });
  });
}
