import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../services/live_search_source.dart';
import '../services/macintosh_garden_service.dart';
import '../services/prowlarr_service.dart';
import '../services/rom_database_service.dart';
import 'api_provider.dart';
import 'macintosh_garden_provider.dart';
import 'prowlarr_provider.dart';
import 'settings_provider.dart';

class SearchState {
  final String query;
  final List<String> selectedPlatforms;
  final List<String> selectedRegions;
  final bool retroAchievementsOnly;
  final SearchResult? result;
  final bool isLoading;
  final dynamic error;

  const SearchState({
    this.query = '',
    this.selectedPlatforms = const [],
    this.selectedRegions = const [],
    this.retroAchievementsOnly = false,
    this.result,
    this.isLoading = false,
    this.error,
  });

  SearchState copyWith({
    String? query,
    List<String>? selectedPlatforms,
    List<String>? selectedRegions,
    bool? retroAchievementsOnly,
    SearchResult? result,
    bool? isLoading,
    dynamic error,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      selectedPlatforms: selectedPlatforms ?? this.selectedPlatforms,
      selectedRegions: selectedRegions ?? this.selectedRegions,
      retroAchievementsOnly:
          retroAchievementsOnly ?? this.retroAchievementsOnly,
      result: result ?? this.result,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SearchNotifier extends StateNotifier<SearchState> {
  final RomDatabaseService _db;
  final List<LiveSearchSource> _liveSources;

  /// [liveSources] are the live sources the user has turned on; each one
  /// decides per search whether it applies.
  SearchNotifier(this._db, {List<LiveSearchSource> liveSources = const []})
      : _liveSources = liveSources,
        super(const SearchState());

  Future<void> search({String? query}) async {
    state = state.copyWith(
      query: query ?? state.query,
      isLoading: true,
      clearError: true,
    );

    try {
      final effectiveQuery = state.query.isEmpty ? null : state.query;
      // Live sources only add to the first page of a query search: none of
      // them has a live equivalent of the catalog's pagination.
      final live = effectiveQuery == null
          ? const <LiveSearchSource>[]
          : _liveSources
              .where((source) => source.appliesTo(
                    query: effectiveQuery,
                    platforms: state.selectedPlatforms,
                    regions: state.selectedRegions,
                    retroAchievementsOnly: state.retroAchievementsOnly,
                  ))
              .toList();

      final results = await Future.wait<Object>([
        _db.search(
          query: effectiveQuery,
          platforms: state.selectedPlatforms.isEmpty
              ? null
              : state.selectedPlatforms,
          regions:
              state.selectedRegions.isEmpty ? null : state.selectedRegions,
          retroAchievementsOnly: state.retroAchievementsOnly,
          page: 1,
        ),
        for (final source in live)
          source
              .search(effectiveQuery!)
              .catchError((Object _) => <RomEntry>[]),
      ]);

      final localResult = results.first as SearchResult;
      final liveEntries = [
        for (final entries in results.skip(1)) ...(entries as List<RomEntry>),
      ];
      final result = liveEntries.isEmpty
          ? localResult
          : SearchResult(
              entries: [...localResult.entries, ...liveEntries],
              totalResults: localResult.totalResults + liveEntries.length,
              currentPage: localResult.currentPage,
              totalPages: localResult.totalPages,
              currentResults: localResult.currentResults + liveEntries.length,
            );

      state = state.copyWith(result: result, isLoading: false);
    } catch (error) {
      state = state.copyWith(error: error, isLoading: false);
    }
  }

  Future<void> loadNextPage() async {
    final currentResult = state.result;
    if (currentResult == null || !currentResult.hasMore || state.isLoading) {
      return;
    }

    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final nextPage = currentResult.currentPage + 1;
      final result = await _db.search(
        query: state.query.isEmpty ? null : state.query,
        platforms: state.selectedPlatforms.isEmpty
            ? null
            : state.selectedPlatforms,
        regions: state.selectedRegions.isEmpty ? null : state.selectedRegions,
        retroAchievementsOnly: state.retroAchievementsOnly,
        page: nextPage,
      );

      // Append new entries to existing ones
      final combinedEntries = [...currentResult.entries, ...result.entries];
      final combinedResult = SearchResult(
        entries: combinedEntries,
        totalResults: result.totalResults,
        currentPage: result.currentPage,
        totalPages: result.totalPages,
        currentResults: combinedEntries.length,
      );

      state = state.copyWith(result: combinedResult, isLoading: false);
    } catch (error) {
      state = state.copyWith(error: error, isLoading: false);
    }
  }

  void setSelectedPlatforms(List<String> platforms) {
    state = state.copyWith(selectedPlatforms: platforms);
  }

  void setSelectedRegions(List<String> regions) {
    state = state.copyWith(selectedRegions: regions);
  }

  void setRetroAchievementsOnly(bool value) {
    state = state.copyWith(retroAchievementsOnly: value);
  }

  void clearFilters() {
    state = state.copyWith(
      selectedPlatforms: [],
      selectedRegions: [],
      retroAchievementsOnly: false,
    );
  }

  void reset() {
    state = const SearchState();
  }
}

final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((
  ref,
) {
  final db = ref.watch(romDatabaseProvider);
  final settings = ref.watch(settingsProvider);

  return SearchNotifier(
    db,
    liveSources: [
      if (settings.prowlarrSearchEnabled)
        ProwlarrLiveSource(
          ref.watch(prowlarrServiceProvider),
          baseUrl: settings.prowlarrBaseUrl,
        ),
      if (settings.macintoshGardenSearchEnabled)
        MacintoshGardenLiveSource(ref.watch(macintoshGardenServiceProvider)),
    ],
  );
});
