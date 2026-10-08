import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Decodes a NoPayStation "zRIF" string into the raw 512-byte binary `.rif`
/// license (`work.bin`) it's a compressed/encoded form of.
///
/// A zRIF is: the binary rif -> zlib-deflated with a shared preset
/// dictionary -> base64-encoded. This reimplements that decode path from
/// scratch in Dart (base64 decode + [ZLibDecoder] with the same preset
/// dictionary) rather than shelling out to pkg2zip for it, since dart:io's
/// zlib bindings already support preset dictionaries directly — no need to
/// round-trip through a subprocess just to unwrap ~512 bytes.
///
/// Algorithm and the dictionary bytes below are taken directly from
/// pkg2zip's zrif_decode()/zrif_dict (vendored at
/// android/app/src/main/cpp/pkg2zip/pkg2zip_zrif.c), not recalled from
/// memory — this is the same dictionary NoPayStation's own zRIF generator
/// uses, identified by zlib DICTID 0x627d1d5d.
class ZrifCodec {
  static const int rifSize = 512;

  /// The exact bytes of pkg2zip's `zrif_dict[]` — a fixed zlib preset
  /// dictionary shared by all zRIF strings.
  static final Uint8List zrifDictionary = Uint8List.fromList([
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    48, 48, 48, 48, 57, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    48, 48, 48, 48, 54, 48, 48, 48, 48, 55, 48, 48, 48, 48, 56, 0,
    48, 48, 48, 48, 51, 48, 48, 48, 48, 52, 48, 48, 48, 48, 53, 48,
    95, 48, 48, 45, 65, 68, 68, 67, 79, 78, 84, 48, 48, 48, 48, 50,
    45, 80, 67, 83, 71, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49,
    45, 80, 67, 83, 69, 48, 48, 48, 45, 80, 67, 83, 70, 48, 48, 48,
    45, 80, 67, 83, 67, 48, 48, 48, 45, 80, 67, 83, 68, 48, 48, 48,
    45, 80, 67, 83, 65, 48, 48, 48, 45, 80, 67, 83, 66, 48, 48, 48,
    0, 1, 0, 1, 0, 1, 0, 2, 239, 205, 171, 137, 103, 69, 35, 1,
  ]);

  /// Decodes [zrif] into its 512-byte binary rif (`work.bin`). Throws
  /// [FormatException] if the string isn't valid base64, isn't valid zlib
  /// data, or doesn't decode to exactly [rifSize] bytes.
  static Uint8List decodeToRif(String zrif) {
    final compressed = base64.decode(base64.normalize(zrif.trim()));
    final decoder = ZLibDecoder(dictionary: zrifDictionary);
    final rif = Uint8List.fromList(decoder.convert(compressed));
    if (rif.length != rifSize) {
      throw FormatException(
        'zRIF decoded to ${rif.length} bytes, expected $rifSize — is it corrupted?',
      );
    }
    return rif;
  }

  /// The content ID embedded in a decoded Vita (non-PSM) rif, at byte
  /// offset 0x10, null-terminated within a 0x30-byte field — used to catch
  /// a zRIF that doesn't actually belong to the pkg it's being paired with.
  static String contentIdFromRif(Uint8List rif) {
    final field = rif.sublist(0x10, 0x10 + 0x30);
    final end = field.indexOf(0);
    return utf8.decode(field.sublist(0, end == -1 ? field.length : end));
  }

  /// The reverse of [decodeToRif]: re-derives a usable zRIF string from a
  /// decoded `.rif`/`work.bin`, so we don't need to keep the original zRIF
  /// text around once we have the binary form on disk. The result isn't
  /// guaranteed to be byte-identical to whatever string originally
  /// produced [rif] (compressors can make different valid choices), but
  /// decoding it back always reproduces the same [rif] bytes, which is
  /// the only property that actually matters here.
  static String encodeFromRif(Uint8List rif) {
    if (rif.length != rifSize) {
      throw ArgumentError('rif must be exactly $rifSize bytes');
    }
    final encoder = ZLibEncoder(dictionary: zrifDictionary);
    return base64.encode(encoder.convert(rif));
  }
}
