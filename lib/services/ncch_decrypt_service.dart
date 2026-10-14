import '../ncch/ncch_decrypt_api.g.dart';

/// Dart-side wrapper around the Pigeon-generated [NcchDecryptHostApi].
///
/// Decrypts a 3DS CCI (`.3ds`) file in place, given key material derived
/// from a user-supplied `boot9.bin` dump of their own console's ARM9
/// bootROM. See `NcchDecryptServiceImpl.kt` for the actual algorithm.
class NcchDecryptService {
  NcchDecryptService({NcchDecryptHostApi? api})
      : _api = api ?? NcchDecryptHostApi();

  final NcchDecryptHostApi _api;

  /// [seeddbPath] is only needed for the subset of titles using seed
  /// crypto; may be null if not configured.
  Future<void> decryptCci(String cciPath, String boot9Path, String? seeddbPath) {
    return _api.decryptCci(cciPath, boot9Path, seeddbPath);
  }
}
