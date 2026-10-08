import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:romgi/services/zrif_codec.dart';

void main() {
  group('ZrifCodec', () {
    test('decodeToRif round-trips a rif encoded with the real dictionary', () {
      // A real zRIF is produced by NoPayStation's own tooling, which we
      // can't invoke here — but zlib preset dictionaries are a standard,
      // interoperable RFC1950 mechanism, so encoding a rif with the exact
      // same dictionary bytes decodeToRif expects (ZrifCodec.zrifDictionary,
      // itself extracted byte-for-byte from pkg2zip's verified C source)
      // and confirming decodeToRif recovers it exercises the same base64 +
      // dictionary-aware zlib path a real zRIF would go through.
      final rif = Uint8List(ZrifCodec.rifSize);
      for (var i = 0; i < rif.length; i++) {
        rif[i] = i % 256;
      }
      final contentId = 'PCSB00001_00-TESTGAME000000001';
      // Zero the whole 0x30-byte content-id field first so the bytes past
      // the string (which a real rif null-pads) don't collide with the
      // i % 256 filler pattern used elsewhere.
      rif.fillRange(0x10, 0x10 + 0x30, 0);
      rif.setRange(0x10, 0x10 + contentId.length, utf8.encode(contentId));

      final compressed = ZLibEncoder(
        dictionary: ZrifCodec.zrifDictionary,
      ).convert(rif);
      final zrif = base64.encode(compressed);

      final decoded = ZrifCodec.decodeToRif(zrif);

      expect(decoded, equals(rif));
      expect(ZrifCodec.contentIdFromRif(decoded), contentId);
    });

    test('decodeToRif tolerates zRIF strings missing base64 padding', () {
      final rif = Uint8List(ZrifCodec.rifSize);
      final compressed = ZLibEncoder(
        dictionary: ZrifCodec.zrifDictionary,
      ).convert(rif);
      final zrif = base64.encode(compressed).replaceAll('=', '');

      expect(ZrifCodec.decodeToRif(zrif), equals(rif));
    });

    test('decodeToRif throws on garbage input', () {
      expect(() => ZrifCodec.decodeToRif('not valid base64!!'),
          throwsA(anything));
    });

    test('contentIdFromRif reads a null-terminated field at offset 0x10',
        () {
      final rif = Uint8List(ZrifCodec.rifSize);
      rif.setRange(0x10, 0x10 + 3, utf8.encode('ABC'));
      expect(ZrifCodec.contentIdFromRif(rif), 'ABC');
    });

    test('encodeFromRif then decodeToRif recovers the original rif bytes',
        () {
      final rif = Uint8List(ZrifCodec.rifSize);
      for (var i = 0; i < rif.length; i++) {
        rif[i] = (i * 7) % 256;
      }
      final contentId = 'PCSB00001_00-TESTGAME000000001';
      rif.fillRange(0x10, 0x10 + 0x30, 0);
      rif.setRange(0x10, 0x10 + contentId.length, utf8.encode(contentId));

      final zrif = ZrifCodec.encodeFromRif(rif);
      final decoded = ZrifCodec.decodeToRif(zrif);

      expect(decoded, equals(rif));
      expect(ZrifCodec.contentIdFromRif(decoded), contentId);
    });

    test('encodeFromRif rejects the wrong length', () {
      expect(() => ZrifCodec.encodeFromRif(Uint8List(10)),
          throwsArgumentError);
    });
  });
}
