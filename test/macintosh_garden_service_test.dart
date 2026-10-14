import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/services/macintosh_garden_service.dart';

void main() {
  group('MacintoshGardenService.cleanTitle', () {
    // Same corpus used to verify the equivalent Python filter regex on the
    // macintosh-garden branch's db/platforms.yml — real filenames pulled
    // from live archive.org Macintosh Garden collections, not invented.
    test('plain filenames', () {
      expect(MacintoshGardenService.cleanTitle('AESOP1_03.zip'), 'AESOP1_03');
      expect(MacintoshGardenService.cleanTitle('AH_Demo.sit'), 'AH_Demo');
      expect(MacintoshGardenService.cleanTitle('ARMOR_ALLEY.iso'), 'ARMOR_ALLEY');
      expect(MacintoshGardenService.cleanTitle('Achilles.dmg'), 'Achilles');
      expect(
        MacintoshGardenService.cleanTitle('Age_3_-_The_WarChiefs.cdr_.zip'),
        'Age_3_-_The_WarChiefs',
      );
    });

    test('compound-wrapped extensions', () {
      expect(
        MacintoshGardenService.cleanTitle(
          'Absolute_Solitaire_CD.toast_.sit',
        ),
        'Absolute_Solitaire_CD',
      );
      expect(
        MacintoshGardenService.cleanTitle('A_to_Zap.iso_.sit'),
        'A_to_Zap',
      );
    });

    test('triple-wrapped extensions', () {
      expect(
        MacintoshGardenService.cleanTitle(
          'MacWrite_Pro_1.5v3.smi_.sit_.hqx',
        ),
        'MacWrite_Pro_1.5v3',
      );
    });

    test('recognizes newer classic Mac formats', () {
      expect(MacintoshGardenService.cleanTitle('Archive.sitx'), 'Archive');
      expect(MacintoshGardenService.cleanTitle('Encoded.hqx'), 'Encoded');
      expect(MacintoshGardenService.cleanTitle('Disk.img'), 'Disk');
    });

    test('is case-insensitive on the extension', () {
      expect(MacintoshGardenService.cleanTitle('Game.SIT'), 'Game');
      expect(MacintoshGardenService.cleanTitle('Game.Zip'), 'Game');
    });

    test('rejects incidental IA metadata files', () {
      expect(MacintoshGardenService.cleanTitle('meta.sqlite'), isNull);
      expect(MacintoshGardenService.cleanTitle('listing.torrent'), isNull);
      expect(MacintoshGardenService.cleanTitle('cover.jpg'), isNull);
      expect(MacintoshGardenService.cleanTitle('info.xml'), isNull);
    });
  });

  group('MacintoshGardenService.slugFor', () {
    test('lowercases and hyphenates', () {
      expect(
        MacintoshGardenService.slugFor('Absolute Solitaire CD'),
        'absolute-solitaire-cd-mac',
      );
    });

    test('collapses repeated separators and strips edges', () {
      expect(
        MacintoshGardenService.slugFor('  Weird -- Title!! '),
        'weird-title-mac',
      );
    });

    test('replaces + and & with words', () {
      expect(
        MacintoshGardenService.slugFor('Rock & Roll + More'),
        'rock-and-roll-plus-more-mac',
      );
    });

    test('is deterministic for the same title', () {
      final a = MacintoshGardenService.slugFor('Oregon Trail');
      final b = MacintoshGardenService.slugFor('Oregon Trail');
      expect(a, b);
    });
  });
}
