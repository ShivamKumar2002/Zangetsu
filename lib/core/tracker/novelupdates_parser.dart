// Portions of the page structure this file reads (the reading-list row ids,
// the release checkbox ids, the list-move and read-marker endpoints) were
// learned from NovelNotifier (MIT, PatchScratch) and Novel Library
// (Apache-2.0, gmathi). See NOTICE.md.
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../models/watch_status.dart';

/// One release on Novel Updates — one translator group's post of one chapter
/// (or range). Novel Updates tracks reading by RELEASE, not by chapter number:
/// the same chapter posted by two groups is two releases with two ids.
class NuRelease {
  const NuRelease({required this.id, required this.label});

  /// The release id, as in `/extnu/<id>/` and the `chklist<id>` checkbox.
  final String id;

  /// The site's own short label: `c12`, `v2c15`, `c10-12`, `prologue`…
  final String label;
}

/// One series on one of the user's reading lists.
class NuListRow {
  const NuListRow({
    required this.slug,
    required this.title,
    this.cover,
    this.lastRead,
    this.lastReadId,
    this.latest,
  });

  /// The series slug — `series/<slug>/` on the site.
  final String slug;
  final String title;
  final String? cover;

  /// Label of the release the user's read marker is on, or null when the
  /// marker isn't set.
  final String? lastRead;

  /// That release's id, when the row links to it.
  final String? lastReadId;

  /// Label of the newest release Novel Updates knows of.
  final String? latest;
}

/// One of the user's reading lists. [index] is what the site's own move call
/// takes (`updatelist.php?lid=`) and what `/reading-list/?list=` pages by.
class NuList {
  const NuList({required this.index, required this.name});

  final int index;
  final String name;
}

/// One series-finder search hit.
class NuSearchHit {
  const NuSearchHit({required this.slug, required this.title, this.cover});

  final String slug;
  final String title;
  final String? cover;
}

/// The numbers a release label carries. Either may be null: `prologue` has
/// neither, `v3` only a volume.
typedef NuLabelNumbers = ({double? volume, double? chapter});

/// Pure HTML → data for Novel Updates pages. No I/O, so every rule here is
/// pinned by tests against saved page shapes.
///
/// Novel Updates has no API: everything below reads the same pages a browser
/// gets. When the site changes its markup, this file is where it shows.
abstract final class NovelUpdatesParser {
  static const String site = 'https://www.novelupdates.com';

  // ── ids from urls ────────────────────────────────────────────────────────

  static final RegExp _seriesPath = RegExp(r'(?:^|/)series/([^/?#]+)');
  static final RegExp _releasePath = RegExp(r'(?:^|/)extnu/(\d+)');

  /// The slug in a series url or path — `https://www.novelupdates.com/series/
  /// foo-bar/` and the LNReader plugin's `series/foo-bar/` both give `foo-bar`.
  static String? seriesSlug(String urlOrPath) =>
      _seriesPath.firstMatch(urlOrPath)?.group(1);

  /// The release id in a release link — the LNReader plugin's chapter path is
  /// exactly that link (`extnu/123456/`), which is what lets a chapter read
  /// through that source be marked on Novel Updates exactly, without matching
  /// on chapter numbers at all.
  static String? releaseId(String urlOrPath) =>
      _releasePath.firstMatch(urlOrPath)?.group(1);

  /// A series slug's page url.
  static String seriesUrl(String slug) => '$site/series/$slug/';

  // ── series page ──────────────────────────────────────────────────────────

  /// The series' numeric post id (`input#mypostid`), which every write and
  /// the release list are keyed by. Null when the page has none — a
  /// challenge page, a removed series, or a redesign.
  static String? postId(String seriesHtml) {
    final v = html_parser
        .parse(seriesHtml)
        .querySelector('input#mypostid')
        ?.attributes['value']
        ?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// The series title on its own page — the same `.seriestitlenu` the
  /// LNReader plugin reads.
  static String? seriesTitle(String seriesHtml) {
    final t = _text(
      html_parser.parse(seriesHtml).querySelector('.seriestitlenu'),
    );
    return t.isEmpty ? null : t;
  }

  // ── release list ─────────────────────────────────────────────────────────

  /// Releases from the `nd_getchapters` admin-ajax response, in the order the
  /// site sends them (newest first).
  ///
  /// Each `li.sp_li_chp` holds the release link (`//www.novelupdates.com/
  /// extnu/<id>/`); its text is the label. Rows without a release link are
  /// skipped rather than guessed at.
  static List<NuRelease> releases(String ajaxHtml) {
    final doc = html_parser.parse(ajaxHtml);
    final out = <NuRelease>[];
    final seen = <String>{};
    for (final li in doc.querySelectorAll('li.sp_li_chp')) {
      String? id;
      for (final a in li.querySelectorAll('a[href]')) {
        id = releaseId(a.attributes['href']!);
        if (id != null) break;
      }
      if (id == null || !seen.add(id)) continue;
      final label = _text(li);
      if (label.isEmpty) continue;
      out.add(NuRelease(id: id, label: label));
    }
    return out;
  }

  // ── search ───────────────────────────────────────────────────────────────

  /// Series-finder results (`/series-finder/?sf=1&sh=…`). Same selectors as
  /// the LNReader Novel Updates plugin, which runs against this page in-app.
  static List<NuSearchHit> searchResults(String html) {
    final doc = html_parser.parse(html);
    final out = <NuSearchHit>[];
    final seen = <String>{};
    for (final box in doc.querySelectorAll('div.search_main_box_nu')) {
      final a = box.querySelector('.search_title > a');
      final slug = seriesSlug(a?.attributes['href'] ?? '');
      final title = _text(a);
      if (slug == null || title.isEmpty || !seen.add(slug)) continue;
      out.add(
        NuSearchHit(
          slug: slug,
          title: title,
          cover: _src(box.querySelector('img')),
        ),
      );
    }
    return out;
  }

  // ── reading lists ────────────────────────────────────────────────────────

  static final RegExp _listParam = RegExp(r'[?&]list=(\d+)');

  /// The user's reading lists, from the list links on a `/reading-list/`
  /// page, in index order. Empty when the page carries none — the caller
  /// falls back to the default list alone.
  static List<NuList> listNames(String readingListHtml) {
    final doc = html_parser.parse(readingListHtml);
    final byIndex = <int, String>{};
    for (final a in doc.querySelectorAll('a[href*="reading-list"]')) {
      final m = _listParam.firstMatch(a.attributes['href'] ?? '');
      if (m == null) continue;
      final index = int.parse(m.group(1)!);
      final name = _text(a);
      // The same list is linked more than once (menu + tabs); the first name
      // wins. A link with no text (an icon) names nothing.
      if (name.isEmpty || name.length > 60) continue;
      byIndex.putIfAbsent(index, () => name);
    }
    final indexes = byIndex.keys.toList()..sort();
    return [for (final i in indexes) NuList(index: i, name: byIndex[i]!)];
  }

  /// The series on ONE reading-list page.
  ///
  /// Only rows of the table holding the site's own per-row list checkboxes
  /// (`input[id^=chklist]`) count. The same page carries "Latest Series" and
  /// suggestion widgets with identical series links, and taking any series
  /// link on the page is how those leak into a user's library — so when that
  /// table isn't there the answer is no rows, not a guess.
  static List<NuListRow> readingList(String html) {
    final doc = html_parser.parse(html);
    final mark = doc.querySelector('input[id^="chklist"]');
    final table = mark == null ? null : _closest(mark, 'table');
    if (table == null) return const [];
    final out = <NuListRow>[];
    final seen = <String>{};
    for (final tr in table.querySelectorAll('tr')) {
      final a = tr.querySelector('a[href*="/series/"]');
      final slug = seriesSlug(a?.attributes['href'] ?? '');
      final title = _text(a);
      if (slug == null || title.isEmpty || !seen.add(slug)) continue;
      final status = tr.querySelector('[id^="mystatus"]');
      final latest = tr.querySelector('[id^="mylatest"]');
      out.add(
        NuListRow(
          slug: slug,
          title: title,
          cover: _src(tr.querySelector('img')),
          lastRead: _nonEmpty(_text(status)),
          lastReadId: releaseId(status?.attributes['href'] ?? ''),
          latest: _nonEmpty(_text(latest)),
        ),
      );
    }
    return out;
  }

  /// Whether [html] is a signed-out page: the WordPress login form's own
  /// field names (`log` / `pwd`) are on it. A reading-list request answered
  /// with this means the session has gone, not that the lists are empty.
  static bool isSignedOut(String html) {
    final doc = html_parser.parse(html);
    return doc.querySelector('input[name="log"]') != null &&
        doc.querySelector('input[name="pwd"]') != null;
  }

  // ── session ──────────────────────────────────────────────────────────────

  static final RegExp _loggedInCookie = RegExp(
    r'(?:^|;\s*)wordpress_logged_in_[^=]*=([^;]+)',
  );

  /// The account name in a WordPress `wordpress_logged_in_*` cookie, from a
  /// `name=value; name=value` cookie header. WordPress writes that cookie's
  /// value as `<username>|<expiry>|<token>|<hmac>`, url-encoded; only the
  /// first field is read. Null when the cookie isn't there — not signed in.
  static String? usernameFromCookies(String cookieHeader) {
    final raw = _loggedInCookie.firstMatch(cookieHeader)?.group(1);
    if (raw == null) return null;
    String value;
    try {
      value = Uri.decodeComponent(raw.trim());
    } catch (_) {
      value = raw.trim();
    }
    final name = value.split('|').first.trim();
    return name.isEmpty ? null : name;
  }

  // ── labels and matching ──────────────────────────────────────────────────

  static final RegExp _volume = RegExp(
    r'(?<![a-z])v(?:ol(?:ume)?)?\.?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  );
  static final RegExp _chapter = RegExp(
    r'(?<![a-z])c(?:h(?:apter)?)?\.?\s*(\d+(?:\.\d+)?)'
    r'(?:\s*-\s*(?:c(?:h(?:apter)?)?\.?\s*)?(\d+(?:\.\d+)?))?',
    caseSensitive: false,
  );
  static final RegExp _bareNumber = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*$');

  /// The volume and chapter a release label names.
  ///
  /// A range (`c10-12`) counts as its END: marking it says the user read
  /// through 12. That is also why a range is never picked for a lower
  /// chapter — see [releaseFor].
  static NuLabelNumbers labelNumbers(String label) {
    final v = _volume.firstMatch(label);
    final c = _chapter.firstMatch(label);
    double? chapter;
    if (c != null) {
      chapter = double.parse(c.group(2) ?? c.group(1)!);
    } else {
      final bare = _bareNumber.firstMatch(label);
      if (bare != null) chapter = double.parse(bare.group(1)!);
    }
    return (
      volume: v == null ? null : double.parse(v.group(1)!),
      chapter: chapter,
    );
  }

  /// The release to mark after reading [chapter] on another source, or null
  /// when none can be chosen honestly.
  ///
  /// Highest-numbered release at or below [chapter]; among releases of that
  /// number (several groups), the first in [releases] — the site's order,
  /// newest first. A release that would claim more than was read (a range
  /// ending past [chapter]) is never chosen: under-claiming is the safe side.
  ///
  /// Releases with a volume are left out. `v2c5` restarts its count per
  /// volume, and a source's chapter 5 can't be told apart from `v1c5`; with
  /// only volume-numbered releases there is no match at all.
  static NuRelease? releaseFor(List<NuRelease> releases, num chapter) {
    NuRelease? best;
    double? bestNumber;
    for (final r in releases) {
      final n = labelNumbers(r.label);
      final c = n.chapter;
      if (n.volume != null || c == null || c > chapter) continue;
      if (bestNumber == null || c > bestNumber) {
        best = r;
        bestNumber = c;
      }
    }
    return best;
  }

  /// The chapter count two labels can honestly be compared on, or null.
  ///
  /// Both must name a chapter, and either neither names a volume or both name
  /// the SAME one — `v3c12` against `v5c3` says nothing about how many
  /// chapters lie between them.
  static ({double read, double latest})? comparable(
    String? lastRead,
    String? latest,
  ) {
    if (lastRead == null || latest == null) return null;
    final a = labelNumbers(lastRead);
    final b = labelNumbers(latest);
    if (a.chapter == null || b.chapter == null) return null;
    if (a.volume != b.volume) return null;
    return (read: a.chapter!, latest: b.chapter!);
  }

  // ── list names ↔ statuses ────────────────────────────────────────────────

  /// The status a list's NAME implies, or null for a list the name doesn't
  /// place. Users rename and add lists freely, so this goes by words rather
  /// than by position.
  static WatchStatus? statusForListName(String name) {
    final n = name.toLowerCase();
    // Order matters: "Plan to Read" contains "read", "Completed reading"
    // contains "reading".
    if (n.contains('complet') || n.contains('finish')) {
      return WatchStatus.completed;
    }
    if (n.contains('plan') || n.contains('later')) return WatchStatus.planning;
    if (n.contains('hold') || n.contains('pause')) return WatchStatus.paused;
    if (n.contains('drop')) return WatchStatus.dropped;
    if (n.contains('reading') || n.contains('current')) {
      return WatchStatus.watching;
    }
    return null;
  }

  /// The status of a series on [list]. A list the name doesn't place reads as
  /// "reading" when it is the default list (index 0) and "plan to read"
  /// otherwise — the same fallback every tracker here uses for a state it
  /// can't read.
  static WatchStatus statusForList(NuList list) =>
      statusForListName(list.name) ??
      (list.index == 0 ? WatchStatus.watching : WatchStatus.planning);

  /// The list to move a series to for [status], or null when none of the
  /// user's lists is named for it — the write is skipped rather than landing
  /// on a list that means something else. "Reading" falls back to the
  /// default list, which is the site's own reading list.
  static NuList? listFor(List<NuList> lists, WatchStatus status) {
    for (final l in lists) {
      if (statusForListName(l.name) == status) return l;
    }
    if (status == WatchStatus.watching) {
      for (final l in lists) {
        if (l.index == 0) return l;
      }
    }
    return null;
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  static String _text(dom.Element? e) =>
      (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  static String? _nonEmpty(String s) => s.isEmpty ? null : s;

  static String? _src(dom.Element? img) {
    final s = img?.attributes['src']?.trim();
    if (s == null || s.isEmpty || s.startsWith('data:')) return null;
    return s.startsWith('//') ? 'https:$s' : s;
  }

  static dom.Element? _closest(dom.Element e, String tag) {
    dom.Element? n = e;
    while (n != null) {
      if (n.localName == tag) return n;
      n = n.parent;
    }
    return null;
  }
}
