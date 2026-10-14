// Pigeon spec for the Dart↔Kotlin 3DS NCCH decryption bridge.
// Regenerate: dart run pigeon --input pigeons/ncch_decrypt_api.dart

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/ncch/ncch_decrypt_api.g.dart',
  dartOptions: DartOptions(),
  kotlinOut:
      'android/app/src/main/kotlin/com/caprado/romgi/ncch_decrypt/NcchDecryptApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.caprado.romgi.ncch_decrypt'),
  dartPackageName: 'romgi',
))

/// Methods Dart calls into Kotlin.
@HostApi()
abstract class NcchDecryptHostApi {
  /// Decrypts every populated NCCH partition of the CCI (.3ds) file at
  /// [cciPath] in place, using key material derived from the user-supplied
  /// [boot9Path] (a dump of their own console's ARM9 bootROM). Partitions
  /// using seed crypto additionally need [seeddbPath] (a user-supplied
  /// seeddb.bin) to look up their per-title seed; if a seed-using partition
  /// is hit and [seeddbPath] is null or lacks that title's seed, this
  /// throws rather than guessing. Also throws if boot9 is invalid/mismatched.
  @async
  void decryptCci(String cciPath, String boot9Path, String? seeddbPath);
}
