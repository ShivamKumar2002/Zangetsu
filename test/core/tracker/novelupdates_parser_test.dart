import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/novelupdates_parser.dart';

/// The page shapes below are RECONSTRUCTED, not captured: they reproduce the
/// elements the existing Novel Updates clients select on (the LNReader plugin
/// this app already runs, NovelNotifier and Novel Library), with the
/// surrounding markup trimmed. They pin what the parser does with those
/// shapes; they cannot prove the live site still serves them. When the site
/// changes, replace a fixture with the real page and let these fail.

const _seriesPage = '''
<html><body>
  <div class="seriestitlenu">The Legendary  Mechanic</div>
  <div class="seriesimg"><img src="https://cdn.novelupdates.com/images/2018/01/tlm.jpg"></div>
  <input type="hidden" id="mypostid" value="104271">
</body></html>
''';

// `nd_getchapters` admin-ajax answer: newest first. The first anchor of each
// row is the site's go-to-chapter helper; the release link is the second.
const _releases = '''
<ol class="sp_chp">
  <li class="sp_li_chp"><a href="//www.novelupdates.com/nu_goto_chapter/?sid=104271"></a><a href="//www.novelupdates.com/extnu/5000003/" data-id="5000003"><span title="c12">c12</span></a></li>
  <li class="sp_li_chp"><a href="//www.novelupdates.com/nu_goto_chapter/?sid=104271"></a><a href="//www.novelupdates.com/extnu/5000002/" data-id="5000002"><span title="c10-11">c10-11</span></a></li>
  <li class="sp_li_chp"><a href="//www.novelupdates.com/nu_goto_chapter/?sid=104271"></a><a href="//www.novelupdates.com/extnu/5000009/" data-id="5000009"><span title="c9">c9</span></a></li>
  <li class="sp_li_chp"><a href="//www.novelupdates.com/nu_goto_chapter/?sid=104271"></a><a href="//www.novelupdates.com/extnu/5000001/" data-id="5000001"><span title="c9">c9</span></a></li>
  <li class="sp_li_chp"><a href="//www.novelupdates.com/extnu/5000000/"><span>prologue</span></a></li>
  <li class="sp_li_chp"><span>no link here</span></li>
</ol>
''';

const _search = '''
<div class="search_main_box_nu">
  <div class="search_img_nu"><img src="//cdn.novelupdates.com/img/a.jpg"></div>
  <div class="search_body_nu">
    <div class="search_title"><a href="https://www.novelupdates.com/series/the-legendary-mechanic/">The Legendary Mechanic</a></div>
  </div>
</div>
<div class="search_main_box_nu">
  <div class="search_body_nu">
    <div class="search_title"><a href="https://www.novelupdates.com/series/legendary-mechanic-side/">Legendary Mechanic: Side</a></div>
  </div>
</div>
<div class="search_main_box_nu"><div class="search_title"><a href="/not-a-series/">Noise</a></div></div>
''';

// A reading-list page: the list tabs, the user's table (with the per-row
// `chklist` checkboxes), and a "Latest Series" widget that must NOT be read
// as part of the library.
const _readingList = '''
<html><body>
  <div class="l-submain">
    <a href="https://www.novelupdates.com/reading-list/?list=0">Reading List</a>
    <a href="https://www.novelupdates.com/reading-list/?list=1">Completed</a>
    <a href="https://www.novelupdates.com/reading-list/?list=2">Plan to Read</a>
    <a href="https://www.novelupdates.com/reading-list/?list=5">Korean Picks</a>
    <a href="https://www.novelupdates.com/reading-list/?list=1"><i class="icon"></i></a>
    <a href="https://www.novelupdates.com/reading-list/">Reading Lists</a>
  </div>
  <table id="myTable">
    <tr><th>Series</th><th>Status</th></tr>
    <tr>
      <td><input type="checkbox" id="chklist104271"></td>
      <td><a href="https://www.novelupdates.com/series/the-legendary-mechanic/">The Legendary Mechanic</a></td>
      <td><a id="mystatus104271" href="https://www.novelupdates.com/extnu/5000002/">c10-11</a></td>
      <td><a id="mylatest104271" href="https://www.novelupdates.com/extnu/5000003/">c12</a></td>
    </tr>
    <tr>
      <td><input type="checkbox" id="chklist200"></td>
      <td><a href="https://www.novelupdates.com/series/volume-novel/">Volume Novel</a></td>
      <td><a id="mystatus200" href="#">v3c12</a></td>
      <td><a id="mylatest200" href="#">v5c3</a></td>
    </tr>
    <tr>
      <td><input type="checkbox" id="chklist300"></td>
      <td><a href="https://www.novelupdates.com/series/not-started/">Not Started</a></td>
      <td><span id="mystatus300"></span></td>
      <td><a id="mylatest300" href="#">c40</a></td>
    </tr>
  </table>
  <div class="widget">
    <h4>Latest Series</h4>
    <table><tr><td><a href="https://www.novelupdates.com/series/someone-elses/">Someone Else's</a> [c3]</td></tr></table>
  </div>
</body></html>
''';

void main() {
  group('ids from urls', () {
    test('series slug from a full url and from the plugin path', () {
      expect(
        NovelUpdatesParser.seriesSlug(
          'https://www.novelupdates.com/series/the-legendary-mechanic/',
        ),
        'the-legendary-mechanic',
      );
      expect(NovelUpdatesParser.seriesSlug('series/foo-bar/'), 'foo-bar');
      expect(NovelUpdatesParser.seriesSlug('extnu/123/'), isNull);
    });

    test('release id from a release link and from the plugin chapter path', () {
      expect(
        NovelUpdatesParser.releaseId('//www.novelupdates.com/extnu/5000003/'),
        '5000003',
      );
      expect(NovelUpdatesParser.releaseId('extnu/42/'), '42');
      expect(NovelUpdatesParser.releaseId('series/foo/'), isNull);
    });
  });

  group('series page', () {
    test('post id and title', () {
      expect(NovelUpdatesParser.postId(_seriesPage), '104271');
      expect(
        NovelUpdatesParser.seriesTitle(_seriesPage),
        'The Legendary Mechanic',
      );
    });

    test('a page without the post id answers null, not a guess', () {
      expect(
        NovelUpdatesParser.postId('<html>Just a moment...</html>'),
        isNull,
      );
      expect(
        NovelUpdatesParser.postId('<input id="mypostid" value="  ">'),
        isNull,
      );
    });
  });

  group('release list', () {
    test(
      'reads release ids and labels, in site order, skipping link-less rows',
      () {
        final r = NovelUpdatesParser.releases(_releases);
        expect(r.map((e) => e.id), [
          '5000003',
          '5000002',
          '5000009',
          '5000001',
          '5000000',
        ]);
        expect(r.map((e) => e.label), [
          'c12',
          'c10-11',
          'c9',
          'c9',
          'prologue',
        ]);
      },
    );
  });

  test('search hits: slug, title, protocol-relative cover made absolute', () {
    final hits = NovelUpdatesParser.searchResults(_search);
    expect(hits.map((h) => h.slug), [
      'the-legendary-mechanic',
      'legendary-mechanic-side',
    ]);
    expect(hits.first.title, 'The Legendary Mechanic');
    expect(hits.first.cover, 'https://cdn.novelupdates.com/img/a.jpg');
    expect(hits.last.cover, isNull);
  });

  group('reading list', () {
    test('list names by index, first name wins, icon-only links ignored', () {
      final lists = NovelUpdatesParser.listNames(_readingList);
      expect(lists.map((l) => l.index), [0, 1, 2, 5]);
      expect(lists.map((l) => l.name), [
        'Reading List',
        'Completed',
        'Plan to Read',
        'Korean Picks',
      ]);
    });

    test('rows come only from the checkbox table, not the side widgets', () {
      final rows = NovelUpdatesParser.readingList(_readingList);
      expect(rows.map((r) => r.slug), [
        'the-legendary-mechanic',
        'volume-novel',
        'not-started',
      ]);
      final first = rows.first;
      expect(first.title, 'The Legendary Mechanic');
      expect(first.lastRead, 'c10-11');
      expect(first.lastReadId, '5000002');
      expect(first.latest, 'c12');
      expect(rows.last.lastRead, isNull);
      expect(rows.last.latest, 'c40');
    });

    test('no checkbox table means no rows', () {
      expect(
        NovelUpdatesParser.readingList(
          '<a href="https://www.novelupdates.com/series/x/">X</a> [c1]',
        ),
        isEmpty,
      );
    });

    test('signed-out pages are recognised by the WordPress login fields', () {
      expect(
        NovelUpdatesParser.isSignedOut(
          '<form><input name="log"><input name="pwd" type="password"></form>',
        ),
        isTrue,
      );
      expect(NovelUpdatesParser.isSignedOut(_readingList), isFalse);
    });
  });

  group('session cookie', () {
    test('username is the first field of the logged-in cookie', () {
      const header =
          'cf_clearance=abc; '
          'wordpress_logged_in_9f3c=Some%20Reader%7C1790000000%7Ctok%7Chmac; '
          'other=1';
      expect(NovelUpdatesParser.usernameFromCookies(header), 'Some Reader');
    });

    test('no logged-in cookie, no user', () {
      expect(
        NovelUpdatesParser.usernameFromCookies(
          'cf_clearance=abc; wordpress_test_cookie=WP+Cookie+check',
        ),
        isNull,
      );
      expect(NovelUpdatesParser.usernameFromCookies(''), isNull);
    });
  });

  group('labels', () {
    NuLabelNumbers n(String s) => NovelUpdatesParser.labelNumbers(s);

    test('plain, volume, range, words and bare numbers', () {
      expect(n('c12'), (volume: null, chapter: 12.0));
      expect(n('v2c15'), (volume: 2.0, chapter: 15.0));
      expect(n('c10-12'), (volume: null, chapter: 12.0));
      expect(n('c100-c102'), (volume: null, chapter: 102.0));
      expect(n('Chapter 7'), (volume: null, chapter: 7.0));
      expect(n('ch 7.5'), (volume: null, chapter: 7.5));
      expect(n('c1 part2'), (volume: null, chapter: 1.0));
      expect(n('vol.3 c4'), (volume: 3.0, chapter: 4.0));
      expect(n('123'), (volume: null, chapter: 123.0));
      expect(n('prologue'), (volume: null, chapter: null));
      expect(n('v3'), (volume: 3.0, chapter: null));
      expect(n('ss'), (volume: null, chapter: null));
    });
  });

  group('choosing a release for a chapter read elsewhere', () {
    final releases = NovelUpdatesParser.releases(_releases);

    test('the exact chapter wins', () {
      expect(NovelUpdatesParser.releaseFor(releases, 12)?.id, '5000003');
    });

    test('a range is only chosen once its end has been read', () {
      // Read 10: c10-11 would claim 11 too, so the safe pick is c9.
      expect(NovelUpdatesParser.releaseFor(releases, 10)?.id, '5000009');
      expect(NovelUpdatesParser.releaseFor(releases, 11)?.id, '5000002');
    });

    test('two groups posting the same chapter: the newer (first) one', () {
      expect(NovelUpdatesParser.releaseFor(releases, 9)?.id, '5000009');
    });

    test('ahead of every release: the newest one below', () {
      expect(NovelUpdatesParser.releaseFor(releases, 500)?.id, '5000003');
    });

    test('nothing at or below: no write', () {
      expect(NovelUpdatesParser.releaseFor(releases, 1), isNull);
    });

    test('volume-numbered releases are never matched to a plain chapter', () {
      const vol = [
        NuRelease(id: '1', label: 'v1c5'),
        NuRelease(id: '2', label: 'v2c5'),
      ];
      expect(NovelUpdatesParser.releaseFor(vol, 5), isNull);
    });
  });

  group('comparable progress', () {
    test('plain chapters compare', () {
      expect(NovelUpdatesParser.comparable('c10-11', 'c12'), (
        read: 11.0,
        latest: 12.0,
      ));
    });

    test('same volume compares, different volumes do not', () {
      expect(NovelUpdatesParser.comparable('v3c2', 'v3c9'), (
        read: 2.0,
        latest: 9.0,
      ));
      expect(NovelUpdatesParser.comparable('v3c12', 'v5c3'), isNull);
      expect(NovelUpdatesParser.comparable('c3', 'v1c9'), isNull);
    });

    test('a missing side compares to nothing', () {
      expect(NovelUpdatesParser.comparable(null, 'c40'), isNull);
      expect(NovelUpdatesParser.comparable('prologue', 'c40'), isNull);
    });
  });

  group('lists and statuses', () {
    test('names place lists by their words', () {
      expect(
        NovelUpdatesParser.statusForListName('Reading List'),
        WatchStatus.watching,
      );
      expect(
        NovelUpdatesParser.statusForListName('Plan to Read'),
        WatchStatus.planning,
      );
      expect(
        NovelUpdatesParser.statusForListName('Completed'),
        WatchStatus.completed,
      );
      expect(
        NovelUpdatesParser.statusForListName('On Hold'),
        WatchStatus.paused,
      );
      expect(
        NovelUpdatesParser.statusForListName('Dropped'),
        WatchStatus.dropped,
      );
      expect(NovelUpdatesParser.statusForListName('Korean Picks'), isNull);
    });

    test('an unplaced list reads as reading only when it is the default', () {
      expect(
        NovelUpdatesParser.statusForList(const NuList(index: 0, name: 'Mine')),
        WatchStatus.watching,
      );
      expect(
        NovelUpdatesParser.statusForList(const NuList(index: 5, name: 'Mine')),
        WatchStatus.planning,
      );
    });

    test('a status goes to the list named for it, or nowhere', () {
      const lists = [
        NuList(index: 0, name: 'My Stuff'),
        NuList(index: 1, name: 'Completed'),
        NuList(index: 4, name: 'Dropped'),
      ];
      expect(
        NovelUpdatesParser.listFor(lists, WatchStatus.completed)?.index,
        1,
      );
      expect(NovelUpdatesParser.listFor(lists, WatchStatus.dropped)?.index, 4);
      // Reading falls back to the default list.
      expect(NovelUpdatesParser.listFor(lists, WatchStatus.watching)?.index, 0);
      // No list is named for it: skip rather than file it somewhere wrong.
      expect(NovelUpdatesParser.listFor(lists, WatchStatus.paused), isNull);
    });
  });
}
