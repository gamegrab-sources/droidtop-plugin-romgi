import '../models/models.dart';

/// A source searched live, at search time, next to the offline catalog
/// (Prowlarr, Macintosh Garden). Its results are appended to the first page
/// of a search and carry [RomEntry.liveSource] = [id], which is how the rest
/// of the app tells them apart from catalog entries: their slug is not in the
/// local database, so the detail screen renders the entry it was handed and
/// skips catalog-only lookups (disc groups, metadata, recently viewed).
///
/// Each source is a user option, off by default; [SearchNotifier] runs the
/// ones it is given.
abstract class LiveSearchSource {
  /// The value its entries carry in [RomEntry.liveSource].
  String get id;

  /// Whether this source has anything to add to the search described by the
  /// arguments (a source without filters of its own skips filtered searches).
  bool appliesTo({
    required String query,
    required List<String> platforms,
    required List<String> regions,
    required bool retroAchievementsOnly,
  });

  /// Best effort: a failing source returns an empty list instead of failing
  /// the whole search.
  Future<List<RomEntry>> search(String query);
}

/// The live sources the app knows, by [RomEntry.liveSource] id, with the
/// name shown on a live result's badge.
const Map<String, String> kLiveSourceNames = {
  'prowlarr': 'Prowlarr',
  'macintosh_garden': 'Internet Archive',
};

String liveSourceName(String id) => kLiveSourceNames[id] ?? id;
