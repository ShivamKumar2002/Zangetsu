import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../playback/list_status_store.dart';
import '../playback/my_list.dart';
import 'novelupdates_parser.dart';
import 'novelupdates_service.dart';
import 'tracker_binding_store.dart';

/// Why an import didn't run, when it didn't.
enum NovelUpdatesImportProblem {
  /// No Novel Updates account is connected.
  notConnected,

  /// The Novel Updates novel source isn't installed. Imported titles open
  /// through it, so without it they would be dead entries.
  noSource,

  /// My List belongs to an app account, and none is signed in.
  notSignedIn,

  /// The reading lists couldn't be read — see
  /// [NovelUpdatesService.lastFailure] for why.
  listsUnavailable,
}

/// What an import did.
class NovelUpdatesImportResult {
  const NovelUpdatesImportResult({
    this.added = 0,
    this.skipped = 0,
    this.problem,
  });

  /// Titles newly added to My List.
  final int added;

  /// Titles already in My List, left exactly as they were.
  final int skipped;

  /// Set when the import didn't run; [added] and [skipped] are then 0.
  final NovelUpdatesImportProblem? problem;
}

/// One-time copy of the user's Novel Updates reading lists into My List.
///
/// Each series becomes the Novel Updates source's own item, so it opens
/// straight into that source and its later chapter reads are marked on the
/// site exactly (see [NovelUpdatesService.scrobbleChapter]). Its status comes
/// from the list it is on. A title already in My List is skipped untouched —
/// an import never overwrites a status the user set here.
///
/// Read-only on the Novel Updates side: nothing is written to the site.
class NovelUpdatesImporter {
  NovelUpdatesImporter({
    required this.tracker,
    required this.myList,
    required this.statuses,
    required this.sourceInstalled,
    required this.signedIn,
    this.bindings,
  });

  final NovelUpdatesService tracker;
  final MyListStore myList;
  final ListStatusStore statuses;
  final bool sourceInstalled;
  final bool signedIn;

  /// Where the matches are pinned, so the sync sheet shows each imported
  /// title as a confirmed match rather than a guess. Optional: the source's
  /// url already names the series.
  final TrackerBindingStore? bindings;

  Future<NovelUpdatesImportResult> run() async {
    if (!tracker.isConnected) {
      return const NovelUpdatesImportResult(
        problem: NovelUpdatesImportProblem.notConnected,
      );
    }
    if (!sourceInstalled) {
      return const NovelUpdatesImportResult(
        problem: NovelUpdatesImportProblem.noSource,
      );
    }
    if (!signedIn) {
      return const NovelUpdatesImportResult(
        problem: NovelUpdatesImportProblem.notSignedIn,
      );
    }
    // Fresh, not the cached copy: the user is asking for what is on the site
    // now.
    final library = await tracker.library(force: true);
    if (library == null) {
      return const NovelUpdatesImportResult(
        problem: NovelUpdatesImportProblem.listsUnavailable,
      );
    }

    final toAdd = <({MediaItem item, WatchStatus status})>[];
    final seen = <String>{};
    var skipped = 0;
    for (final e in library) {
      final item = importItem(e.row);
      // The site files a series on one list at a time, but a page read twice
      // must still not add it twice.
      if (!seen.add(e.row.slug) || myList.contains(item)) {
        skipped++;
        continue;
      }
      toAdd.add((item: item, status: NovelUpdatesParser.statusForList(e.list)));
    }
    // Status first: the cloud row is built from the local status at the
    // moment it is written, so setting it after would push rows without one.
    for (final a in toAdd) {
      await statuses.setStatus(a.item, a.status);
    }
    final added = await myList.addAll([for (final a in toAdd) a.item]);
    final pins = bindings;
    if (pins != null) {
      for (final (:item, status: _) in toAdd) {
        final slug = NovelUpdatesParser.seriesSlug(item.url);
        if (slug == null) continue;
        await pins.set(
          TrackerBindingStore.keyOf(item.sourceId, item.url),
          tracker.displayName,
          slug,
        );
      }
    }
    return NovelUpdatesImportResult(added: added, skipped: skipped);
  }

  /// The Novel Updates source's own item for a reading-list row — the same
  /// id, url and source id the source gives the series when browsed, so the
  /// import and a later browse are one title, not two.
  static MediaItem importItem(NuListRow row) {
    final path = 'series/${row.slug}/';
    return MediaItem(
      id: path,
      title: row.title,
      cover: row.cover,
      url: path,
      type: ProviderType.novel,
      sourceId: NovelUpdatesService.sourceId,
    );
  }
}
