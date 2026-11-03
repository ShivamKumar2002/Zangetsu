import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/home_row.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/home/cubit/tracker_home_rows.dart';

/// "New chapters" for novels comes only from a tracker that says how far the
/// releases have got (NovelUpdates' newest release). A series total — what
/// AniList, MAL and MangaBaka report — must never light it: a finished novel
/// read halfway has unread chapters, not new ones.

TrackerListItem _entry({
  ProviderType type = ProviderType.novel,
  int? progress,
  int? total,
  int? nextAiring,
}) => TrackerListItem(
  item: MediaItem(id: 'x', title: 'X', url: '', type: type, sourceId: ''),
  status: WatchStatus.watching,
  progress: progress,
  totalEpisodes: total,
  nextAiringEpisode: nextAiring,
);

void main() {
  test('a novel with newer releases than progress has new chapters', () {
    expect(
      hasNewEpisode(_entry(progress: 11, nextAiring: 13), ZKind.novel),
      isTrue,
    );
  });

  test('caught up: nothing new', () {
    expect(
      hasNewEpisode(_entry(progress: 12, nextAiring: 13), ZKind.novel),
      isFalse,
    );
  });

  test('a series total alone never counts as new chapters', () {
    expect(
      hasNewEpisode(_entry(progress: 5, total: 300), ZKind.novel),
      isFalse,
    );
  });

  test('manga never has a new-chapters row', () {
    expect(
      hasNewEpisode(
        _entry(type: ProviderType.manga, progress: 1, nextAiring: 9),
        ZKind.manga,
      ),
      isFalse,
    );
    expect(trackerRowIdsFor(ZKind.manga), isNot(contains(newEpisodesRowId)));
  });

  test('a novel layout offers the row', () {
    expect(trackerRowIdsFor(ZKind.novel), contains(newEpisodesRowId));
  });

  test('the row is built for novels with new releases', () {
    final rows = buildTrackerHomeRows(
      trackerName: 'NovelUpdates',
      library: [_entry(progress: 11, nextAiring: 13)],
      kind: ZKind.novel,
    );
    expect(rows.map((r) => r.id), contains(newEpisodesRowId));
  });
}
