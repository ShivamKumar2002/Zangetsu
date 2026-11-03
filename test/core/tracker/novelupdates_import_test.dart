import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/novelupdates_import.dart';
import 'package:watch_app/core/tracker/novelupdates_parser.dart';
import 'package:watch_app/core/tracker/novelupdates_service.dart';

/// The import against a real My List and status store, with the cloud and
/// the site faked. Page shapes are the reconstructed ones the parser tests
/// pin — see novelupdates_parser_test.dart.

const _site = 'https://www.novelupdates.com';

String _page(List<(String slug, String title)> rows) =>
    '<html><body>'
    '<a href="$_site/reading-list/?list=0">Reading List</a>'
    '<a href="$_site/reading-list/?list=1">Completed</a>'
    '<table>${[for (final (i, r) in rows.indexed) '<tr><td><input type="checkbox" id="chklist$i"></td>'
          '<td><a href="$_site/series/${r.$1}/">${r.$2}</a></td></tr>'].join()}</table></body></html>';

/// Records the batch upserts; nothing else of the remote is reached here.
class _Remote implements MyListRemote {
  final List<List<Map<String, dynamic>>> batches = [];

  @override
  Future<void> upsertAll(List<Map<String, dynamic>> rows) async =>
      batches.add(rows);

  @override
  Future<void> upsert(Map<String, dynamic> row) async => batches.add([row]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Remote remote;
  late MyListStore myList;
  late ListStatusStore statuses;
  late NovelUpdatesService nu;
  late List<String> requests;
  var cloudflare = false;

  NovelUpdatesImporter importer({
    bool sourceInstalled = true,
    bool signedIn = true,
  }) => NovelUpdatesImporter(
    tracker: nu,
    myList: myList,
    statuses: statuses,
    sourceInstalled: sourceInstalled,
    signedIn: signedIn,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nu_import_test');
    Hive.init(dir.path);
    await MyListStore.init();
    await ListStatusStore.init();
    await NovelUpdatesService.init();
    remote = _Remote();
    statuses = ListStatusStore();
    myList = MyListStore(
      SupabaseService(),
      () => 'user1',
      remote: remote,
      statusOf: (m) => statuses.statusOf(m)?.name,
    );
    requests = [];
    cloudflare = false;
    nu = NovelUpdatesService(
      gap: Duration.zero,
      signIn: () async => 'wordpress_logged_in_x=reader%7C1',
      fetch: (url, {method = 'GET', headers = const {}, body}) async {
        requests.add(url);
        if (cloudflare) return (status: 403, body: '', cloudflare: true);
        final list = Uri.parse(url).queryParameters['list'];
        return (
          status: 200,
          body: list == '1'
              ? _page([('done-novel', 'Done Novel')])
              : _page([
                  ('the-legendary-mechanic', 'The Legendary Mechanic'),
                  ('already-here', 'Already Here'),
                ]),
          cloudflare: false,
        );
      },
    );
    await nu.connect();
  });

  tearDown(() async {
    nu.dispose();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('adds every novel with its list status, in one cloud batch', () async {
    await myList.add(
      NovelUpdatesImporter.importItem(
        const NuListRow(slug: 'already-here', title: 'Already Here'),
      ),
    );
    await statuses.setStatus(
      NovelUpdatesImporter.importItem(
        const NuListRow(slug: 'already-here', title: 'Already Here'),
      ),
      WatchStatus.dropped,
    );
    remote.batches.clear();

    final r = await importer().run();
    expect(r.problem, isNull);
    expect(r.added, 2);
    expect(r.skipped, 1);

    final byId = {for (final m in myList.all()) m.id: m};
    expect(byId.keys.toSet(), {
      'series/the-legendary-mechanic/',
      'series/already-here/',
      'series/done-novel/',
    });
    final tlm = byId['series/the-legendary-mechanic/']!;
    expect(tlm.sourceId, NovelUpdatesService.sourceId);
    expect(statuses.statusOf(tlm), WatchStatus.watching);
    expect(
      statuses.statusOf(byId['series/done-novel/']!),
      WatchStatus.completed,
    );
    // An import never overwrites what the user set here.
    expect(
      statuses.statusOf(byId['series/already-here/']!),
      WatchStatus.dropped,
    );

    expect(remote.batches, hasLength(1));
    expect(remote.batches.single.map((r) => r['status']).toSet(), {
      'watching',
      'completed',
    }, reason: 'rows carry their status — it is set before the add');
  });

  test('reads the site, never writes to it', () async {
    await importer().run();
    expect(
      requests.where(
        (u) =>
            u.contains('readinglist_update.php') ||
            u.contains('updatelist.php'),
      ),
      isEmpty,
    );
  });

  test('without the Novel Updates source: nothing, and says so', () async {
    final r = await importer(sourceInstalled: false).run();
    expect(r.problem, NovelUpdatesImportProblem.noSource);
    expect(myList.all(), isEmpty);
    expect(requests, isEmpty);
  });

  test('signed out of the app: nothing, and says so', () async {
    final r = await importer(signedIn: false).run();
    expect(r.problem, NovelUpdatesImportProblem.notSignedIn);
    expect(requests, isEmpty);
  });

  test(
    'lists unreadable: nothing added, failure kept for the message',
    () async {
      cloudflare = true;
      final r = await importer().run();
      expect(r.problem, NovelUpdatesImportProblem.listsUnavailable);
      expect(nu.lastFailure, NovelUpdatesFailure.cloudflare);
      expect(myList.all(), isEmpty);
    },
  );
}
