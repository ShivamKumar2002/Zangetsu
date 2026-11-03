import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/novelupdates_parser.dart';
import 'package:watch_app/core/tracker/novelupdates_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';

/// Novel Updates has no API, so these drive the service against a fake site:
/// [_FakeSite] serves the page shapes the parser tests pin (reconstructed from
/// the existing clients' selectors, not captured) and records every request,
/// so each test can say exactly which calls a sync makes — and which it must
/// not.

const _site = 'https://www.novelupdates.com';

String _listPage({
  required List<(int, String)> lists,
  required List<
    (String slug, String title, String? read, String? readId, String? latest)
  >
  rows,
}) {
  final tabs = [
    for (final (i, name) in lists)
      '<a href="$_site/reading-list/?list=$i">$name</a>',
  ].join();
  final trs = [
    for (final (i, r) in rows.indexed)
      '<tr><td><input type="checkbox" id="chklist$i"></td>'
          '<td><a href="$_site/series/${r.$1}/">${r.$2}</a></td>'
          '<td>${r.$3 == null ? '<span id="mystatus$i"></span>' : '<a id="mystatus$i" href="${r.$4 == null ? '#' : '$_site/extnu/${r.$4}/'}">${r.$3}</a>'}</td>'
          '<td>${r.$5 == null ? '' : '<a id="mylatest$i" href="#">${r.$5}</a>'}</td></tr>',
  ].join();
  // An empty list still renders its table header row; the checkbox table
  // only exists with rows, which is the case the parser keys on.
  return '<html><body>$tabs<table id="myTable">$trs</table></body></html>';
}

const _series = '''
<div class="seriestitlenu">The Legendary Mechanic</div>
<input type="hidden" id="mypostid" value="104271">
''';

const _releases = '''
<ol>
<li class="sp_li_chp"><a href="//www.novelupdates.com/extnu/5000003/">c12</a></li>
<li class="sp_li_chp"><a href="//www.novelupdates.com/extnu/5000002/">c10-11</a></li>
<li class="sp_li_chp"><a href="//www.novelupdates.com/extnu/5000009/">c9</a></li>
</ol>
''';

const _searchPage = '''
<div class="search_main_box_nu"><div class="search_title">
<a href="https://www.novelupdates.com/series/the-legendary-mechanic/">The Legendary Mechanic</a>
</div></div>
''';

class _FakeSite {
  _FakeSite({
    this.lists = const [
      (0, 'Reading List'),
      (1, 'Completed'),
      (5, 'Korean Picks'),
    ],
    Map<int, List<(String, String, String?, String?, String?)>>? rows,
  }) : rows =
           rows ??
           {
             0: [
               (
                 'the-legendary-mechanic',
                 'The Legendary Mechanic',
                 'c10-11',
                 '5000002',
                 'c12',
               ),
               ('volume-novel', 'Volume Novel', 'v3c12', null, 'v5c3'),
             ],
             1: [('done-novel', 'Done Novel', 'c40', null, 'c40')],
             5: [('korean-one', 'Korean One', null, null, 'c7')],
           };

  final List<(int, String)> lists;
  final Map<int, List<(String, String, String?, String?, String?)>> rows;
  final List<String> requests = [];
  bool cloudflare = false;
  bool signedOut = false;

  Future<NuResponse> fetch(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    requests.add(method == 'POST' ? 'POST $url $body' : url);
    if (cloudflare)
      return (status: 403, body: 'Just a moment', cloudflare: true);
    final u = Uri.parse(url);
    if (u.path == '/reading-list/') {
      if (signedOut) {
        return (
          status: 200,
          body: '<form><input name="log"><input name="pwd"></form>',
          cloudflare: false,
        );
      }
      final i = int.parse(u.queryParameters['list'] ?? '0');
      return (
        status: 200,
        body: _listPage(lists: lists, rows: rows[i] ?? const []),
        cloudflare: false,
      );
    }
    if (u.path.startsWith('/series/')) {
      return (status: 200, body: _series, cloudflare: false);
    }
    if (u.path == '/wp-admin/admin-ajax.php') {
      return (status: 200, body: _releases, cloudflare: false);
    }
    if (u.path == '/series-finder/') {
      return (status: 200, body: _searchPage, cloudflare: false);
    }
    // The write endpoints answer 200 with nothing worth reading.
    return (status: 200, body: '', cloudflare: false);
  }

  Iterable<String> get writes => requests.where(
    (r) => r.contains('readinglist_update.php') || r.contains('updatelist.php'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _FakeSite site;
  late NovelUpdatesService svc;

  const loggedIn =
      'cf_clearance=x; wordpress_logged_in_ab12=reader%7C1%7Ct%7Ch';

  NovelUpdatesService make({String? cookie = loggedIn}) => NovelUpdatesService(
    fetch: site.fetch,
    signIn: () async => cookie,
    gap: Duration.zero,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('novelupdates_test');
    Hive.init(dir.path);
    await NovelUpdatesService.init();
    site = _FakeSite();
    svc = make();
  });

  tearDown(() async {
    svc.dispose();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('connect', () {
    test('a sign-in that lands names the account', () async {
      expect(await svc.connect(), isTrue);
      expect(svc.isConnected, isTrue);
      expect(svc.viewerName, 'reader');
    });

    test('backing out of the sign-in connects nothing', () async {
      svc = make(cookie: null);
      expect(await svc.connect(), isFalse);
      expect(svc.isConnected, isFalse);
    });

    test(
      'disconnect forgets the account but leaves the browser alone',
      () async {
        await svc.connect();
        await svc.disconnect();
        expect(svc.isConnected, isFalse);
        expect(site.requests, isEmpty, reason: 'no sign-out call to the site');
      },
    );

    test('never relayed to the TV: the session is browser cookies', () async {
      await svc.connect();
      expect(svc.exportSession(), isNull);
    });
  });

  group('fetchList', () {
    test('reads every list, with statuses from the list names', () async {
      await svc.connect();
      final items = await svc.fetchList();
      expect(items.map((e) => e.item.title), [
        'The Legendary Mechanic',
        'Volume Novel',
        'Done Novel',
        'Korean One',
      ]);
      expect(items.map((e) => e.status), [
        WatchStatus.watching,
        WatchStatus.watching,
        WatchStatus.completed,
        WatchStatus.planning,
      ]);
      expect(items.every((e) => e.item.type == ProviderType.novel), isTrue);
      expect(site.requests, [
        '$_site/reading-list/?list=0',
        '$_site/reading-list/?list=1',
        '$_site/reading-list/?list=5',
      ]);
    });

    test('progress and the newest release when they compare', () async {
      await svc.connect();
      final items = await svc.fetchList();
      final tlm = items.first;
      expect(tlm.progress, 11);
      // "One past what is out": released so far = 12.
      expect(tlm.nextAiringEpisode, 13);
      // v3c12 vs v5c3: progress shown, but no "new chapters" claim.
      final vol = items[1];
      expect(vol.progress, 12);
      expect(vol.nextAiringEpisode, isNull);
    });

    test('a list its name does not place shows as a custom list', () async {
      await svc.connect();
      final items = await svc.fetchList();
      expect(items.last.customLists, ['Korean Picks']);
      expect(items.first.customLists, isEmpty);
    });

    test(
      'without the Novel Updates source the entries are plain stubs',
      () async {
        await svc.connect();
        final first = (await svc.fetchList()).first;
        expect(first.item.sourceId, isEmpty);
        expect(first.item.url, isEmpty);
        expect(
          first.item.id,
          'tracker:novelupdates:novel:the-legendary-mechanic',
        );
      },
    );

    test('kept for a while: a second read makes no requests', () async {
      await svc.connect();
      await svc.fetchList();
      site.requests.clear();
      await svc.fetchList();
      expect(site.requests, isEmpty);
    });

    test('Cloudflare: nothing, and says why', () async {
      await svc.connect();
      site.cloudflare = true;
      expect(await svc.fetchList(), isEmpty);
      expect(svc.lastFailure, NovelUpdatesFailure.cloudflare);
      expect(svc.isConnected, isTrue, reason: 'a challenge is not a sign-out');
    });

    test('the sign-in form means the session has gone', () async {
      await svc.connect();
      site.signedOut = true;
      expect(await svc.fetchList(), isEmpty);
      expect(svc.lastFailure, NovelUpdatesFailure.signedOut);
      expect(svc.isConnected, isFalse);
    });

    test('disconnected: no requests at all', () async {
      expect(await svc.fetchList(), isEmpty);
      expect(site.requests, isEmpty);
    });
  });

  group('scrobbleChapter', () {
    test('read through the Novel Updates source: that exact release', () async {
      await svc.connect();
      await svc.scrobbleChapter(
        chapter: 3, // the plugin's position, NOT the chapter — must be ignored
        sourceIdOf: NovelUpdatesService.sourceId,
        showUrl: 'series/the-legendary-mechanic/',
        chapterUrl: 'extnu/5000003/',
      );
      expect(site.writes, [
        '$_site/readinglist_update.php?rid=5000003&sid=104271&checked=yes',
      ]);
      expect(
        site.requests.where((r) => r.contains('series-finder')),
        isEmpty,
        reason: 'the url names the series; no title search',
      );
    });

    test('read elsewhere: matched by number', () async {
      await svc.connect();
      await svc.scrobbleChapter(title: 'The Legendary Mechanic', chapter: 12);
      expect(site.writes, [
        '$_site/readinglist_update.php?rid=5000003&sid=104271&checked=yes',
      ]);
    });

    test('never moves the marker backwards', () async {
      await svc.connect();
      // Marker is on c10-11; re-reading 9 must leave it there.
      await svc.scrobbleChapter(title: 'The Legendary Mechanic', chapter: 9);
      expect(site.writes, isEmpty);
    });

    test('the release already marked is not marked again', () async {
      await svc.connect();
      await svc.scrobbleChapter(
        chapter: 1,
        sourceIdOf: NovelUpdatesService.sourceId,
        showUrl: 'series/the-legendary-mechanic/',
        chapterUrl: 'extnu/5000002/',
      );
      expect(site.writes, isEmpty);
    });

    test(
      'a series on none of the lists goes on the reading list first',
      () async {
        site = _FakeSite(rows: {0: const [], 1: const [], 5: const []});
        svc = make();
        await svc.connect();
        await svc.scrobbleChapter(title: 'The Legendary Mechanic', chapter: 12);
        expect(site.writes, [
          '$_site/updatelist.php?sid=104271&lid=0&act=move',
          '$_site/readinglist_update.php?rid=5000003&sid=104271&checked=yes',
        ]);
      },
    );

    test('auto-sync off: not a single request', () async {
      await svc.connect();
      svc.autoSync = false;
      await svc.scrobbleChapter(title: 'The Legendary Mechanic', chapter: 12);
      expect(site.requests, isEmpty);
    });

    test('the post id is fetched once and kept', () async {
      await svc.connect();
      await svc.scrobbleChapter(title: 'The Legendary Mechanic', chapter: 12);
      site.requests.clear();
      await svc.scrobbleChapter(title: 'The Legendary Mechanic', chapter: 12);
      expect(site.requests.where((r) => r.contains('/series/')), isEmpty);
    });
  });

  group('status writes', () {
    test('a status moves the series to the list named for it', () async {
      await svc.connect();
      await svc.setStatus(
        title: 'The Legendary Mechanic',
        status: WatchStatus.completed,
        kind: MediaKind.manga,
      );
      expect(site.writes, ['$_site/updatelist.php?sid=104271&lid=1&act=move']);
    });

    test('no list named for the status: no write', () async {
      await svc.connect();
      await svc.setStatus(
        title: 'The Legendary Mechanic',
        status: WatchStatus.dropped,
        kind: MediaKind.manga,
      );
      expect(site.writes, isEmpty);
    });

    test('anime never reaches the site', () async {
      await svc.connect();
      await svc.setStatus(
        title: 'The Legendary Mechanic',
        status: WatchStatus.completed,
      );
      expect(site.requests, isEmpty);
    });
  });

  test('fetchEntry reads the entry off the lists', () async {
    await svc.connect();
    final e = await svc.fetchEntry(
      title: 'The Legendary Mechanic',
      kind: MediaKind.manga,
    );
    expect(e?.onList, isTrue);
    expect(e?.status, WatchStatus.watching);
    expect(e?.progress, 11);
    expect(e?.url, '$_site/series/the-legendary-mechanic/');
  });

  group('matching a title to a search hit', () {
    const hits = [
      NuSearchHit(slug: 'a', title: 'Legendary Mechanic: Side'),
      NuSearchHit(slug: 'b', title: 'The Legendary Mechanic'),
    ];

    test('exact after normalising beats an earlier near-miss', () {
      expect(
        NovelUpdatesService.bestMatch('legendary mechanic', hits)?.slug,
        'b',
      );
    });

    test('nothing alike among several: no match', () {
      expect(NovelUpdatesService.bestMatch('Solo Leveling', hits), isNull);
    });

    test('a lone hit is taken', () {
      expect(
        NovelUpdatesService.bestMatch('x', const [
          NuSearchHit(slug: 'only', title: 'Something'),
        ])?.slug,
        'only',
      );
    });
  });

  group('forward check', () {
    NuListRow row(String? read, [String? id]) =>
        NuListRow(slug: 's', title: 't', lastRead: read, lastReadId: id);

    test('forward, backward, same, unknown', () {
      const c12 = NuRelease(id: '12', label: 'c12');
      expect(NovelUpdatesService.isForward(row('c11'), c12), isTrue);
      expect(NovelUpdatesService.isForward(row('c13'), c12), isFalse);
      expect(NovelUpdatesService.isForward(row('c12', '12'), c12), isFalse);
      expect(NovelUpdatesService.isForward(row(null), c12), isTrue);
      expect(NovelUpdatesService.isForward(row('v2c3'), c12), isTrue);
    });
  });

  group('TrackerHub keeps Novel Updates to novels', () {
    test('modes: novel yes, manga and anime no', () {
      final hub = TrackerHub([svc]);
      expect(hub.forMode(ContentMode.novel), [svc]);
      expect(hub.forMode(ContentMode.manga), isEmpty);
      expect(hub.forMode(ContentMode.anime), isEmpty);
      expect(trackerIsNovelOnly(svc), isTrue);
      expect(trackerSupportsVideo(svc), isFalse);
    });

    test('a write not marked novel never reaches it', () async {
      await svc.connect();
      final hub = TrackerHub([svc]);
      await hub.setStatus(
        title: 'The Legendary Mechanic',
        status: WatchStatus.completed,
        kind: MediaKind.manga,
      );
      expect(site.requests, isEmpty);
      await hub.setStatus(
        title: 'The Legendary Mechanic',
        status: WatchStatus.completed,
        kind: MediaKind.manga,
        novel: true,
      );
      expect(site.writes, ['$_site/updatelist.php?sid=104271&lid=1&act=move']);
    });

    test('a novel scrobble carries where it was read', () async {
      await svc.connect();
      final hub = TrackerHub([svc]);
      await hub.scrobble(
        title: 'ignored when the url names the series',
        episode: 1,
        kind: MediaKind.manga,
        novel: true,
        sourceId: NovelUpdatesService.sourceId,
        showUrl: 'series/the-legendary-mechanic/',
        chapterUrl: 'extnu/5000003/',
      );
      expect(site.writes, [
        '$_site/readinglist_update.php?rid=5000003&sid=104271&checked=yes',
      ]);
    });
  });
}
