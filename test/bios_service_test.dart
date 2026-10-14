import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:romgi/services/bios_service.dart';

// The shape of gamegrab-sources/droidtop-plugin-bios data/index.json, cut
// down to two systems.
final _indexJson = {
  'version': 1,
  'systems': {
    'psx': {
      'name': 'Sony PlayStation',
      'files': [
        {
          'name': 'scph1001.bin',
          'dir': 'bios',
          'md5': ['dc2b9bf8da62ec93e868cfd29f0d067d'],
          'src': [
            {
              'kind': 'ia',
              'exact': true,
              'item': 'retroarch_bios',
              'name': 'scph1001.bin',
              'md5': 'dc2b9bf8da62ec93e868cfd29f0d067d',
              'size': 524288,
            },
            {
              'kind': 'retrobios',
              'exact': true,
              'path': 'bios/Sony/PlayStation/scph1001_v20.bin',
              'md5': 'dc2b9bf8da62ec93e868cfd29f0d067d',
              'sha256': 'AA',
              'size': 524288,
            },
          ],
        },
      ],
    },
    '3ds': {
      'name': 'Nintendo 3DS',
      'files': [
        {
          'name': 'boot9.bin',
          'dir': 'sysdata',
          'md5': ['d8675e80e5dd3a9afaaf885d79b14e9c'],
          'note': 'The 3DS boot ROM.',
          'src': [],
        },
      ],
    },
    'dreamcast': {
      'name': 'Sega Dreamcast',
      'files': [
        {'name': 'dc_boot.bin', 'dir': 'bios/dc', 'md5': [], 'src': []},
      ],
    },
  },
};

BiosIndex _index() =>
    BiosIndex.fromJson(jsonDecode(jsonEncode(_indexJson)) as Map<String, dynamic>);

void main() {
  group('systemIdFor', () {
    final index = _index();

    test('maps romgi platform ids onto the list ids', () {
      expect(BiosService.systemIdFor('ps1', index), 'psx');
      expect(BiosService.systemIdFor('psx', index), 'psx');
      expect(BiosService.systemIdFor('n3ds', index), '3ds');
      expect(BiosService.systemIdFor('dc', index), 'dreamcast');
      expect(BiosService.systemIdFor('PS1', index), 'psx');
    });

    test('is null for a system without files', () {
      expect(BiosService.systemIdFor('snes', index), isNull);
    });
  });

  group('targetPath', () {
    final index = _index();

    test('bios/ is the BIOS folder itself, other dirs are subfolders', () {
      final psx = index.systems['psx']!.files.first;
      final boot9 = index.systems['3ds']!.files.first;
      final dc = index.systems['dreamcast']!.files.first;
      expect(BiosService.targetPath('/b', psx), p.join('/b', 'scph1001.bin'));
      expect(
        BiosService.targetPath('/b', boot9),
        p.join('/b', 'sysdata', 'boot9.bin'),
      );
      expect(BiosService.targetPath('/b', dc), p.join('/b', 'dc', 'dc_boot.bin'));
    });

    test('never leaves the BIOS folder', () {
      const file = BiosFile(
        name: '../evil.bin',
        dir: 'bios/../../x',
        md5: [],
        sources: [],
      );
      final target = BiosService.targetPath('/b', file);
      expect(p.isWithin('/b', target), isTrue);
    });
  });

  test('expandTemplate fills file, system and md5', () {
    final file = _index().systems['psx']!.files.first;
    expect(
      BiosService.expandTemplate('https://x.org/{system}/{file}?h={md5}', 'psx', file),
      'https://x.org/psx/scph1001.bin?h=dc2b9bf8da62ec93e868cfd29f0d067d',
    );
  });

  group('candidates', () {
    final service = BiosService();
    final file = _index().systems['psx']!.files.first;

    test('listed dumps first, SHA-256-checkable first, own addresses last', () async {
      final list = await service.candidates(
        'psx',
        file,
        const BiosSourceSettings(urlTemplates: ['https://x.org/{file}']),
      );
      expect(list.map((c) => c.key).toList(), [
        'rb:bios/Sony/PlayStation/scph1001_v20.bin',
        'ia:retroarch_bios/scph1001.bin',
        'url:0',
      ]);
      expect(
        list.first.url,
        'https://raw.githubusercontent.com/Abdess/retrobios/main/'
        'bios/Sony/PlayStation/scph1001_v20.bin',
      );
      expect(list.last.exact, isFalse);
    });

    test('retrobios can be turned off', () async {
      final list = await service.candidates(
        'psx',
        file,
        const BiosSourceSettings(retrobiosEnabled: false),
      );
      expect(list.map((c) => c.key), ['ia:retroarch_bios/scph1001.bin']);
    });
  });

  group('verify and fileState', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('bios'));
    tearDown(() async => dir.delete(recursive: true));

    test('accepts the right bytes and refuses others', () async {
      final bytes = utf8.encode('a bios');
      final good = md5.convert(bytes).toString();
      final f = File(p.join(dir.path, 'x.bin'))..writeAsBytesSync(bytes);
      final file = BiosFile(name: 'x.bin', dir: 'bios', md5: [good], sources: const []);
      final right = BiosCandidate(
        key: 'k',
        label: 'L',
        url: 'u',
        exact: true,
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
      expect(await BiosService.verify(f, file, right), isNull);
      final wrongSize = BiosCandidate(key: 'k', label: 'L', url: 'u', exact: true, size: 1);
      expect(await BiosService.verify(f, file, wrongSize), isNotNull);
      final wrongMd5 = BiosCandidate(
        key: 'k',
        label: 'L',
        url: 'u',
        exact: true,
        md5: '0' * 32,
      );
      expect(await BiosService.verify(f, file, wrongMd5), isNotNull);

      final service = BiosService();
      expect(await service.fileState(dir.path, file), BiosFileState.verified);
      final other = BiosFile(name: 'x.bin', dir: 'bios', md5: ['0' * 32], sources: const []);
      expect(await service.fileState(dir.path, other), BiosFileState.otherDump);
      final absent = BiosFile(name: 'y.bin', dir: 'bios', md5: [good], sources: const []);
      expect(await service.fileState(dir.path, absent), BiosFileState.missing);
    });
  });
}
