import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/bios_service.dart';
import 'download_provider.dart';
import 'settings_provider.dart';

final biosServiceProvider = Provider<BiosService>((ref) {
  return BiosService(cacheDirectory: getApplicationSupportDirectory);
});

/// The BIOS file list (cached for a week, refreshed from Settings).
final biosIndexProvider = FutureProvider<BiosIndex>((ref) {
  return ref.watch(biosServiceProvider).loadIndex();
});

/// The folder BIOS and system files go in: the one chosen in Settings, or
/// `bios` inside the download folder.
final biosFolderProvider = FutureProvider<String>((ref) async {
  final settings = ref.watch(settingsProvider);
  final chosen = settings.biosFolderPath;
  if (chosen != null && chosen.isNotEmpty) return chosen;
  final storage = ref.watch(storageServiceProvider);
  final downloads = await storage.getDownloadDirectory();
  return p.join(downloads.path, 'bios');
});

/// What is in the BIOS folder for one system of the BIOS list (by its id).
final biosSystemStatusProvider =
    FutureProvider.family<BiosSystemStatus?, String>((ref, systemId) async {
  final index = await ref.watch(biosIndexProvider.future);
  final system = index.systems[systemId];
  if (system == null || system.files.isEmpty) return null;
  final folder = await ref.watch(biosFolderProvider.future);
  return ref.watch(biosServiceProvider).systemStatus(folder, systemId, system);
});

/// The BIOS list's id for a romgi platform, or null when it needs no files
/// (or the list cannot be loaded).
final biosSystemIdForPlatformProvider =
    FutureProvider.family<String?, String>((ref, platform) async {
  try {
    final index = await ref.watch(biosIndexProvider.future);
    return BiosService.systemIdFor(platform, index);
  } catch (_) {
    return null;
  }
});
