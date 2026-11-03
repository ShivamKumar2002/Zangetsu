import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../models/watch_status.dart';
import '../playback/playback_prefs.dart';
import '../privacy/incognito_mode.dart';
import 'mangabaka_service.dart';
import 'novelupdates_service.dart';
import 'tracker.dart';

/// Fans every list/progress write out to all connected trackers at once
/// (AniList + MyAnimeList + Simkl). Each tracker self-gates (skips when
/// disconnected / auto-sync off / type not applicable), and a failure in one
/// never blocks the others.
class TrackerHub {
  TrackerHub(this.trackers);

  final List<Tracker> trackers;

  Iterable<Tracker> get connected => trackers.where((t) => t.isConnected);
  bool get anyConnected => connected.isNotEmpty;

  /// Trackers that can actually sync in [mode]. A reading mode drops
  /// video-only trackers (Simkl), and a watching mode drops reading-only ones
  /// — either way the point is not to offer an account that can never sync a
  /// single title there.
  ///
  /// Display/selection only — the write paths already self-gate per
  /// [MediaKind] (see `MangaBakaService._canWrite`), so this never changes
  /// what gets synced. A novels-only tracker (NovelUpdates) is dropped from
  /// manga for the same reason.
  Iterable<Tracker> forMode(ContentMode mode) => switch (mode) {
    ContentMode.anime => trackers.where(trackerSupportsVideo),
    ContentMode.manga => trackers.where(
      (t) => t.supportsReading && !trackerIsNovelOnly(t),
    ),
    ContentMode.novel => trackers.where((t) => t.supportsReading),
  };

  /// [forMode], narrowed to the ones the user has actually connected.
  Iterable<Tracker> connectedForMode(ContentMode mode) =>
      forMode(mode).where((t) => t.isConnected);

  /// Whether the "as you watch" writes are allowed through. Reads defensively
  /// so a context without [PlaybackPrefs] registered (tests, early startup)
  /// behaves as it always did rather than silently going quiet.
  static bool get _autoTrackOn =>
      !sl.isRegistered<PlaybackPrefs>() || sl<PlaybackPrefs>().autoTrack;

  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    // Only ever called on playback start, so there's no manual path to spare.
    if (!_autoTrackOn) return;
    if (IncognitoMode.on) return; // incognito: pause auto-tracking
    await _fan(
      (t) => t.markWatching(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        kind: kind,
      ),
    );
  }

  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    int? season,
    int? seasonEpisode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
    bool auto = true,
    String? sourceId,
    String? showUrl,
    String? chapterUrl,
  }) async {
    // [auto] false = the user asked for this one by hand ("Mark as watched"),
    // so the auto-track preference doesn't apply. Incognito still does.
    if (auto && !_autoTrackOn) return;
    if (IncognitoMode.on) return; // incognito: pause auto-scrobble
    await _fan(
      novel: novel,
      (t) => t is NovelUpdatesService
          // [sourceId]/[showUrl]/[chapterUrl] say where the chapter was read.
          // Only NovelUpdates can use them — a chapter read through its own
          // source IS one of its releases — so they go to it alone rather
          // than onto the interface every tracker implements.
          ? t.scrobbleChapter(
              title: title,
              chapter: episode,
              sourceIdOf: sourceId,
              showUrl: showUrl,
              chapterUrl: chapterUrl,
            )
          : t.scrobble(
              malId: malId,
              title: title,
              tmdbId: tmdbId,
              tmdbIsTv: tmdbIsTv,
              imdbId: imdbId,
              episode: episode,
              season: season,
              seasonEpisode: seasonEpisode,
              kind: kind,
              novel: novel,
            ),
    );
  }

  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) => _fan(
    novel: novel,
    (t) => t.setStatus(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      status: status,
      kind: kind,
    ),
  );

  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) => _fan(
    novel: novel,
    (t) => t.removeFromList(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      kind: kind,
    ),
  );

  /// Read the user's entry for one title. Queries every connected tracker in
  /// parallel and returns the FIRST that has the title on the user's list —
  /// that becomes the sheet's editable state. Falls back
  /// to the first that returned any data (so total-episodes / next-airing still
  /// show even when the title isn't on a list yet). Null when nothing matched.
  /// [pinnedIds] maps a tracker's [Tracker.displayName] to a chosen native id.
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final results = await fetchEntries(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      pinnedIds: pinnedIds,
      kind: kind,
      novel: novel,
    );
    for (final r in results) {
      if (r.onList) return r;
    }
    return results.isEmpty ? null : results.first;
  }

  /// Every connected tracker's entry for one title, in connection order, with
  /// the ones that answered nothing dropped.
  ///
  /// [fetchEntry] collapses this to a single entry — the combined sheet needs
  /// them all so it can say when two trackers disagree instead of silently
  /// overwriting one with the other.
  Future<List<TrackerEntry>> fetchEntries({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final results = await Future.wait(
      _connectedFor(novel: novel).map((t) async {
        try {
          return await t.fetchEntry(
            malId: malId,
            title: title,
            tmdbId: tmdbId,
            tmdbIsTv: tmdbIsTv,
            imdbId: imdbId,
            pinnedId: pinnedIds?[t.displayName],
            kind: kind,
            novel: novel,
          );
        } catch (_) {
          return null;
        }
      }),
    );
    return [
      for (final r in results)
        if (r != null) r,
    ];
  }

  /// Write status/score/progress for one title to EVERY connected tracker at
  /// once (the sheet's Apply). Not gated by incognito — this is an explicit,
  /// deliberate edit, not passive auto-tracking.
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) => _fan(
    novel: novel,
    (t) => t.updateEntry(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      pinnedId: pinnedIds?[t.displayName],
      status: status,
      score: score,
      progress: progress,
      kind: kind,
    ),
  );

  /// Candidate matches from every connected tracker (the match-fixer), in
  /// connection order.
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final lists = await Future.wait(
      _connectedFor(novel: novel).map((t) async {
        try {
          return await t.searchEntries(query, kind: kind);
        } catch (_) {
          return const <TrackerSearchResult>[];
        }
      }),
    );
    return [for (final l in lists) ...l];
  }

  /// The connected trackers a call about one title goes to. A novels-only
  /// tracker is asked only when the caller says the title is a novel: its
  /// catalogue holds nothing else, so a manga or anime title could only ever
  /// resolve, by name, onto some unrelated novel.
  Iterable<Tracker> _connectedFor({required bool novel}) =>
      novel ? connected : connected.where((t) => !trackerIsNovelOnly(t));

  Future<void> _fan(
    Future<void> Function(Tracker) op, {
    bool novel = false,
  }) async {
    await Future.wait(
      _connectedFor(novel: novel).map((t) async {
        try {
          await op(t);
        } catch (_) {/* one tracker failing must not block the rest */}
      }),
    );
  }
}

/// Whether this tracker has an anime/film library at all. The mirror of
/// [Tracker.supportsReading]: false for MangaBaka and NovelUpdates, which are
/// reading-only.
///
/// A function rather than another getter on [Tracker] on purpose — the
/// interface is `implements`-only, so a new member would force every other
/// tracker and every test fake to declare it, for one exception. A second
/// reading-only tracker (NovelUpdates) is listed here for the same reason.
bool trackerSupportsVideo(Tracker t) =>
    t is! MangaBakaService && t is! NovelUpdatesService;

/// Whether this tracker catalogues novels and nothing else — NovelUpdates.
/// Same reasoning as [trackerSupportsVideo] for being a function: one
/// exception does not earn a member on the interface.
bool trackerIsNovelOnly(Tracker t) => t is NovelUpdatesService;
