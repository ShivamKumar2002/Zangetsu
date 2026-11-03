// The endpoints used here (the read-marker and list-move calls, the release
// list, the reading-list pages) and the sign-in cookie were learned from
// NovelNotifier (MIT, PatchScratch) and Novel Library (Apache-2.0, gmathi).
// See NOTICE.md.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../di/injector.dart';
import '../lnreader/lnreader_manager.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import 'novelupdates_parser.dart';
import 'tracker.dart';
import 'tracker_binding_store.dart';

/// What one request to Novel Updates came back with.
typedef NuResponse = ({int status, String body, bool cloudflare});

/// How the service reaches the site — the native novel client in the app, a
/// fake in tests.
typedef NuFetch =
    Future<NuResponse> Function(
      String url, {
      String method,
      Map<String, String> headers,
      String? body,
    });

/// Why the last read of the user's lists came back empty-handed, so a screen
/// can say something more useful than "nothing found".
enum NovelUpdatesFailure {
  /// Cloudflare wants a human. Opening the site once in the in-app browser
  /// clears it.
  cloudflare,

  /// The site answered with its sign-in form: the session has gone.
  signedOut,

  /// No answer, or one this build can't read.
  unreachable,
}

/// The Novel Updates tracker — **light and web novels only**, which is all the
/// site catalogues.
///
/// Novel Updates has no API and no OAuth. Everything here is what the site's
/// own pages do in a browser, through the app's native novel client
/// (`zangetsu/novel_http`, see NovelHttp.kt): that client already carries the
/// in-app browser's cookies and the device's own User-Agent, which is what
/// gets requests through Novel Updates' Cloudflare. So signing in is simply
/// signing in to the site in the in-app browser; this class never holds a
/// password or the session cookie, only the account name.
///
/// That session is SHARED with the Novel Updates novel source, which reads
/// the same browser cookies. [disconnect] therefore forgets the account here
/// but does not sign the browser out — that would sign the source out too.
/// The browser's own "Clear cookies" is the full sign-out.
///
/// Reading progress on the site is a single marker per series, set on a
/// RELEASE (one group's post of a chapter), not on a chapter number. A chapter
/// read through the Novel Updates source IS a release link, so it is marked
/// exactly ([scrobbleChapter]); one read elsewhere is matched to a release by
/// number ([NovelUpdatesParser.releaseFor]).
///
/// Android only for now: the sign-in needs the native in-app browser.
class NovelUpdatesService extends ChangeNotifier implements Tracker {
  NovelUpdatesService({
    NuFetch? fetch,
    Future<String?> Function()? signIn,
    Duration gap = const Duration(milliseconds: 1200),
  }) : _fetch = fetch ?? _nativeFetch,
       _signIn = signIn ?? _nativeSignIn,
       _gap = gap;

  final NuFetch _fetch;
  final Future<String?> Function() _signIn;

  /// The least time between two requests to the site. Novel Updates publishes
  /// no rate limit; one request at a time, spaced out, is the polite reading
  /// of that — a list sync is a handful of pages, not a crawl.
  final Duration _gap;

  static const String boxName = 'novelupdates';

  /// The LNReader Novel Updates plugin's source id in this app.
  static const String sourceId = 'lnr:novelupdates';

  static const String _site = NovelUpdatesParser.site;
  static const String _loginUrl = '$_site/login/';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  Box get _box => Hive.box(boxName);

  @override
  String get displayName => 'NovelUpdates';

  @override
  bool get supportsReading => true;

  @override
  bool get isConnected =>
      (_box.get('viewerName') as String?)?.isNotEmpty == true;

  @override
  String? get viewerName => _box.get('viewerName') as String?;

  /// The site shows avatars only on the page itself; there is nothing stable
  /// to read one from, so the row shows initials.
  @override
  String? get viewerAvatar => null;

  @override
  bool get autoSync => (_box.get('autoSync') as bool?) ?? true;
  @override
  set autoSync(bool value) {
    _box.put('autoSync', value);
    notifyListeners();
  }

  NovelUpdatesFailure? _lastFailure;

  /// Why the most recent read of the user's lists failed, or null when it
  /// worked.
  NovelUpdatesFailure? get lastFailure => _lastFailure;

  // ── transport ────────────────────────────────────────────────────────────

  static const MethodChannel _novelHttp = MethodChannel('zangetsu/novel_http');
  static const MethodChannel _mihon = MethodChannel('zangetsu/mihon');

  static Future<NuResponse> _nativeFetch(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final res = await _novelHttp.invokeMapMethod<String, dynamic>('request', {
      'url': url,
      'method': method,
      'headers': headers,
      'body': body,
    });
    return (
      status: (res?['status'] as num?)?.toInt() ?? 0,
      body: res?['body'] as String? ?? '',
      cloudflare: res?['cloudflare'] == true,
    );
  }

  /// Opens the site's sign-in page in the in-app browser and waits for it to
  /// close. Answers the `wordpress_logged_in_*` cookie, or null when the user
  /// left without signing in.
  static Future<String?> _nativeSignIn() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _mihon.invokeMethod<String>('signInWebView', {
        'url': _loginUrl,
        'doneCookie': 'wordpress_logged_in',
        'title': 'Novel Updates',
      });
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[nu] sign-in failed: $e');
      return null;
    }
  }

  Future<void> _queue = Future.value();
  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// One request, after every earlier one and at least [_gap] after the last.
  /// Null when the request threw — the callers all treat that as "no answer".
  Future<NuResponse?> _request(
    String url, {
    String method = 'GET',
    String? form,
    String? referer,
  }) {
    final run = _queue.then((_) async {
      final wait = _gap - DateTime.now().difference(_lastRequestAt);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      _lastRequestAt = DateTime.now();
      try {
        return await _fetch(
          url,
          method: method,
          headers: {
            'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': referer ?? '$_site/',
            if (form != null)
              'Content-Type':
                  'application/x-www-form-urlencoded; charset=UTF-8',
            if (form != null) 'X-Requested-With': 'XMLHttpRequest',
          },
          body: form,
        );
      } catch (e) {
        debugPrint('[nu] $method $url failed: $e');
        return null;
      } finally {
        _lastRequestAt = DateTime.now();
      }
    });
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// A page's HTML, or null when it couldn't be had. Records why in
  /// [lastFailure].
  Future<String?> _page(String url, {String? referer}) async {
    final r = await _request(url, referer: referer);
    if (r == null) {
      _lastFailure = NovelUpdatesFailure.unreachable;
      return null;
    }
    if (r.cloudflare) {
      _lastFailure = NovelUpdatesFailure.cloudflare;
      return null;
    }
    if (r.status != 200) {
      _lastFailure = NovelUpdatesFailure.unreachable;
      return null;
    }
    return r.body;
  }

  // ── connect / disconnect ─────────────────────────────────────────────────

  @override
  Future<bool> connect() async {
    final cookie = await _signIn();
    final name = cookie == null
        ? null
        : NovelUpdatesParser.usernameFromCookies(cookie);
    if (name == null) return false;
    await _box.put('viewerName', name);
    _forgetLibrary();
    notifyListeners();
    return true;
  }

  @override
  Future<void> disconnect() async {
    // The site lists and post ids stay: they describe the site, not the
    // account, and a reconnect would only fetch them again.
    await _box.delete('viewerName');
    _forgetLibrary();
    notifyListeners();
  }

  /// The site answered with its sign-in form. Say so in the UI by dropping
  /// the account, rather than failing quietly on every call from here on.
  Future<void> _onSignedOut() async {
    _lastFailure = NovelUpdatesFailure.signedOut;
    await _box.delete('viewerName');
    _forgetLibrary();
    notifyListeners();
  }

  // ── the user's lists ─────────────────────────────────────────────────────

  /// The library is a handful of page fetches, so it is kept for a few
  /// minutes: a chapter finished every few minutes must not re-read every
  /// list each time.
  static const Duration _libraryTtl = Duration(minutes: 10);

  List<({NuList list, NuListRow row})>? _library;
  DateTime? _libraryAt;

  void _forgetLibrary() {
    _library = null;
    _libraryAt = null;
  }

  /// Every series on every one of the user's lists, or null when any list
  /// could not be read — a partial library would read as "not on your list"
  /// for whatever was missed.
  Future<List<({NuList list, NuListRow row})>?> library({
    bool force = false,
  }) async {
    if (!isConnected) return null;
    final at = _libraryAt;
    if (!force &&
        _library != null &&
        at != null &&
        DateTime.now().difference(at) < _libraryTtl) {
      return _library;
    }
    _lastFailure = null;
    final first = await _page('$_site/reading-list/?list=0');
    if (first == null) return null;
    if (NovelUpdatesParser.isSignedOut(first)) {
      await _onSignedOut();
      return null;
    }
    var lists = NovelUpdatesParser.listNames(first);
    if (!lists.any((l) => l.index == 0)) {
      lists = [const NuList(index: 0, name: 'Reading List'), ...lists];
    }
    await _box.put('lists', [
      for (final l in lists) {'index': l.index, 'name': l.name},
    ]);
    final out = <({NuList list, NuListRow row})>[];
    for (final list in lists) {
      final html = list.index == 0
          ? first
          : await _page('$_site/reading-list/?list=${list.index}');
      if (html == null) return null;
      for (final row in NovelUpdatesParser.readingList(html)) {
        out.add((list: list, row: row));
      }
    }
    _library = out;
    _libraryAt = DateTime.now();
    return out;
  }

  /// The user's lists, from the last read of them — fetched when there is
  /// none yet. Empty when they can't be had.
  Future<List<NuList>> _lists() async {
    var lists = _storedLists();
    if (lists.isEmpty) {
      await library();
      lists = _storedLists();
    }
    return lists;
  }

  List<NuList> _storedLists() {
    final stored = _box.get('lists');
    if (stored is! List) return const [];
    return [
      for (final e in stored)
        if (e is Map && e['index'] is int && e['name'] is String)
          NuList(index: e['index'] as int, name: e['name'] as String),
    ];
  }

  ({NuList list, NuListRow row})? _entryIn(
    List<({NuList list, NuListRow row})> library,
    String slug,
  ) {
    for (final e in library) {
      if (e.row.slug == slug) return e;
    }
    return null;
  }

  // ── reads ────────────────────────────────────────────────────────────────

  @override
  Future<List<TrackerListItem>> fetchList() async {
    final lib = await library();
    if (lib == null) return const [];
    return [for (final e in lib) listItemFor(e.list, e.row)];
  }

  /// One reading-list row as a tracker list entry.
  ///
  /// When the Novel Updates novel source is installed, the entry IS that
  /// source's item — same id, url and source id the source gives the series —
  /// so tapping it opens the series straight away instead of searching for it
  /// by name. Without the source it is a plain stub, like the other trackers'.
  ///
  /// Progress and the newest release are only turned into numbers when the
  /// two can be compared (see [NovelUpdatesParser.comparable]); the newest
  /// release goes in [TrackerListItem.nextAiringEpisode] as "one past what is
  /// out", which is how the home rows read "released so far" for every
  /// tracker.
  @visibleForTesting
  TrackerListItem listItemFor(NuList list, NuListRow row) {
    final linked = _sourceInstalled();
    final path = 'series/${row.slug}/';
    final both = NovelUpdatesParser.comparable(row.lastRead, row.latest);
    final read =
        both?.read ??
        (row.lastRead == null
            ? null
            : NovelUpdatesParser.labelNumbers(row.lastRead!).chapter);
    final placed = NovelUpdatesParser.statusForListName(list.name) != null;
    return TrackerListItem(
      item: MediaItem(
        id: linked ? path : 'tracker:novelupdates:novel:${row.slug}',
        title: row.title,
        cover: row.cover ?? '',
        url: linked ? path : '',
        type: ProviderType.novel,
        sourceId: linked ? sourceId : '',
      ),
      status: NovelUpdatesParser.statusForList(list),
      progress: read?.floor(),
      nextAiringEpisode: both == null ? null : both.latest.floor() + 1,
      // A list its name doesn't place is the user's own grouping — show it
      // the way AniList's custom lists are shown.
      customLists: placed ? const [] : [list.name],
    );
  }

  bool _sourceInstalled() =>
      sl.isRegistered<LnReaderManager>() &&
      sl<LnReaderManager>().metaFor('novelupdates') != null;

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    if (!isConnected || kind != MediaKind.manga) return null;
    final slug = await _slugFor(title: title, pinnedId: pinnedId);
    if (slug == null) return null;
    final lib = await library();
    final e = lib == null ? null : _entryIn(lib, slug);
    if (e == null) {
      return TrackerEntry(
        trackerName: displayName,
        title: _box.get('title:$slug') as String? ?? title,
        url: NovelUpdatesParser.seriesUrl(slug),
      );
    }
    final read = e.row.lastRead == null
        ? null
        : NovelUpdatesParser.labelNumbers(e.row.lastRead!).chapter;
    return TrackerEntry(
      trackerName: displayName,
      onList: true,
      title: e.row.title,
      status: NovelUpdatesParser.statusForList(e.list),
      progress: read?.floor(),
      url: NovelUpdatesParser.seriesUrl(slug),
    );
  }

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    if (kind != MediaKind.manga) return const [];
    final hits = await _search(query);
    return [
      for (final h in hits)
        TrackerSearchResult(
          trackerName: displayName,
          id: h.slug,
          title: h.title,
          cover: h.cover,
        ),
    ];
  }

  Future<List<NuSearchHit>> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final html = await _page(
      '$_site/series-finder/?sf=1&sh=${Uri.encodeQueryComponent(q)}'
      '&sort=srank&order=asc',
    );
    return html == null ? const [] : NovelUpdatesParser.searchResults(html);
  }

  // ── resolution ───────────────────────────────────────────────────────────

  final Map<String, String> _slugByTitle = {};

  /// The series slug for a title, or null when it can't be resolved honestly.
  ///
  /// In order: a series read through the Novel Updates source names its slug
  /// in its own url; a match the user fixed by hand ([pinnedId], or the
  /// binding stored for [sourceIdOf]/[showUrl]); then a title search.
  Future<String?> _slugFor({
    String? title,
    String? pinnedId,
    String? sourceIdOf,
    String? showUrl,
  }) async {
    if (sourceIdOf == sourceId && showUrl != null) {
      final s = NovelUpdatesParser.seriesSlug(showUrl);
      if (s != null) return s;
    }
    final pinned = pinnedId?.trim() ?? '';
    if (pinned.isNotEmpty) {
      return NovelUpdatesParser.seriesSlug(pinned) ?? pinned;
    }
    if (sourceIdOf != null &&
        showUrl != null &&
        sl.isRegistered<TrackerBindingStore>()) {
      final bound = sl<TrackerBindingStore>().get(
        TrackerBindingStore.keyOf(sourceIdOf, showUrl),
      )[displayName];
      if (bound != null && bound.isNotEmpty) return bound;
    }
    final q = (title ?? '').trim();
    if (q.isEmpty) return null;
    final known = _slugByTitle[q];
    if (known != null) return known;
    final hit = bestMatch(q, await _search(q));
    if (hit != null) _slugByTitle[q] = hit.slug;
    return hit?.slug;
  }

  /// The search hit that is the same series as [title], or null.
  ///
  /// Stricter than taking the first hit: a write that lands on a different
  /// novel with a similar name is worse than no write. Exact after
  /// normalising (case, punctuation, a leading "the"); otherwise a lone hit,
  /// or the first hit whose title contains the other.
  @visibleForTesting
  static NuSearchHit? bestMatch(String title, List<NuSearchHit> hits) {
    if (hits.isEmpty) return null;
    final want = _norm(title);
    if (want.isEmpty) return null;
    for (final h in hits) {
      if (_norm(h.title) == want) return h;
    }
    if (hits.length == 1) return hits.first;
    for (final h in hits) {
      final got = _norm(h.title);
      if (got.contains(want) || want.contains(got)) return h;
    }
    return null;
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'^the\s+'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');

  /// The site's post id for a series, which every write is keyed by. Kept on
  /// disk: it never changes for a series.
  Future<String?> _postIdFor(String slug) async {
    final cached = _box.get('sid:$slug') as String?;
    if (cached != null && cached.isNotEmpty) return cached;
    final html = await _page(NovelUpdatesParser.seriesUrl(slug));
    if (html == null) return null;
    final sid = NovelUpdatesParser.postId(html);
    if (sid == null) return null;
    await _box.put('sid:$slug', sid);
    final t = NovelUpdatesParser.seriesTitle(html);
    if (t != null) await _box.put('title:$slug', t);
    return sid;
  }

  final Map<String, ({List<NuRelease> releases, DateTime at})> _releases = {};

  /// A series' releases, newest first. Kept for the session's next few
  /// chapters, like the library.
  Future<List<NuRelease>?> _releasesFor(String postId, String slug) async {
    final hit = _releases[postId];
    if (hit != null && DateTime.now().difference(hit.at) < _libraryTtl) {
      return hit.releases;
    }
    final r = await _request(
      '$_site/wp-admin/admin-ajax.php',
      method: 'POST',
      form: 'action=nd_getchapters&mygrr=0&mypostid=$postId',
      referer: NovelUpdatesParser.seriesUrl(slug),
    );
    if (r == null || r.cloudflare || r.status != 200) return null;
    final list = NovelUpdatesParser.releases(r.body);
    _releases[postId] = (releases: list, at: DateTime.now());
    return list;
  }

  // ── site writes ──────────────────────────────────────────────────────────

  /// A GET to one of the site's own write endpoints. True on a 200.
  Future<bool> _write(String path, String slug) async {
    final r = await _request(
      '$_site$path',
      referer: NovelUpdatesParser.seriesUrl(slug),
    );
    final ok = r != null && !r.cloudflare && r.status == 200;
    if (!ok) debugPrint('[nu] write $path -> ${r?.status}');
    return ok;
  }

  /// Moves the series to list [index] — the site's own move call. Adds it to
  /// that list when it is on none.
  Future<bool> _move(String postId, String slug, int index) async {
    final ok = await _write(
      '/updatelist.php?sid=$postId&lid=$index&act=move',
      slug,
    );
    if (ok) _forgetLibrary();
    return ok;
  }

  /// Puts the series' read marker on release [releaseId]. The site keeps one
  /// marker per series and clears the old one itself.
  Future<bool> _mark(String postId, String slug, NuRelease release) async {
    final ok = await _write(
      '/readinglist_update.php?rid=${release.id}&sid=$postId&checked=yes',
      slug,
    );
    if (ok) _patchMarker(slug, release);
    return ok;
  }

  /// Keeps the cached library in step with a marker just written, so the
  /// next chapter's forward check doesn't need the lists read again.
  void _patchMarker(String slug, NuRelease release) {
    final lib = _library;
    if (lib == null) return;
    for (var i = 0; i < lib.length; i++) {
      final e = lib[i];
      if (e.row.slug != slug) continue;
      lib[i] = (
        list: e.list,
        row: NuListRow(
          slug: e.row.slug,
          title: e.row.title,
          cover: e.row.cover,
          lastRead: release.label,
          lastReadId: release.id,
          latest: e.row.latest,
        ),
      );
    }
  }

  /// Puts the series on the list named for [status]. False when no list is
  /// named for it — see [NovelUpdatesParser.listFor].
  Future<bool> _moveTo(String postId, String slug, WatchStatus status) async {
    final list = NovelUpdatesParser.listFor(await _lists(), status);
    if (list == null) {
      debugPrint('[nu] no list for ${status.name}; skipped');
      return false;
    }
    return _move(postId, slug, list.index);
  }

  /// Reading-only, novels-only. TrackerHub only asks this tracker about
  /// titles it knows to be novels; this guards the rest.
  bool _canWrite(MediaKind kind) => isConnected && kind == MediaKind.manga;

  // ── writes ───────────────────────────────────────────────────────────────

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!_canWrite(kind) || !autoSync) return;
    final slug = await _slugFor(title: title);
    if (slug == null) return;
    final sid = await _postIdFor(slug);
    if (sid == null) return;
    final lib = await library();
    if (lib != null && _entryIn(lib, slug) == null) {
      await _moveTo(sid, slug, WatchStatus.watching);
    }
  }

  @override
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
  }) {
    if (kind != MediaKind.manga) return Future.value();
    return scrobbleChapter(title: title, chapter: episode);
  }

  /// Record that [chapter] of a novel was read.
  ///
  /// [sourceIdOf], [showUrl] and [chapterUrl] say where it was read. Through
  /// the Novel Updates source, [chapterUrl] is the release itself and is
  /// marked as-is; anywhere else the release is matched by number. Either way
  /// the marker only moves FORWARD — re-reading an old chapter must not undo
  /// the user's place — and a series on none of the user's lists is put on
  /// their reading list first, as every other tracker does on a first read.
  Future<void> scrobbleChapter({
    String? title,
    required int chapter,
    String? sourceIdOf,
    String? showUrl,
    String? chapterUrl,
  }) async {
    if (!_canWrite(MediaKind.manga) || !autoSync) return;
    final slug = await _slugFor(
      title: title,
      sourceIdOf: sourceIdOf,
      showUrl: showUrl,
    );
    if (slug == null) return;
    final sid = await _postIdFor(slug);
    if (sid == null) return;

    final exactId = sourceIdOf == sourceId && chapterUrl != null
        ? NovelUpdatesParser.releaseId(chapterUrl)
        : null;
    final releases = await _releasesFor(sid, slug);
    NuRelease? release;
    if (exactId != null) {
      // The release list only supplies the label for the forward check. A
      // release missing from it (newer than the list, or the list failed to
      // load) is still the right one to mark; with no label the check can't
      // compare and lets the write through.
      release =
          releases?.where((r) => r.id == exactId).firstOrNull ??
          NuRelease(id: exactId, label: '');
    } else if (releases != null) {
      release = NovelUpdatesParser.releaseFor(releases, chapter);
    }
    if (release == null) return;

    final lib = await library();
    if (lib == null) return;
    final entry = _entryIn(lib, slug);
    if (entry == null) {
      if (!await _moveTo(sid, slug, WatchStatus.watching)) return;
    } else if (!isForward(entry.row, release)) {
      return;
    }
    await _mark(sid, slug, release);
  }

  /// Whether marking [release] moves the marker on [row] forward. Unknown
  /// (no marker yet, or labels that can't be compared) counts as forward:
  /// the first mark has to be allowed, and a label we can't read is no
  /// evidence of going backwards.
  @visibleForTesting
  static bool isForward(NuListRow row, NuRelease release) {
    if (row.lastReadId == release.id) return false;
    final both = NovelUpdatesParser.comparable(row.lastRead, release.label);
    if (both == null) return true;
    return both.latest > both.read;
  }

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!_canWrite(kind)) return;
    final slug = await _slugFor(title: title);
    if (slug == null) return;
    final sid = await _postIdFor(slug);
    if (sid == null) return;
    await _moveTo(sid, slug, status);
  }

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!_canWrite(kind)) return;
    final slug = await _slugFor(title: title, pinnedId: pinnedId);
    if (slug == null) return;
    final sid = await _postIdFor(slug);
    if (sid == null) return;
    if (status != null) await _moveTo(sid, slug, status);
    // An explicit edit, so no forward-only rule: the user set this number.
    if (progress != null && progress > 0) {
      final releases = await _releasesFor(sid, slug);
      final r = releases == null
          ? null
          : NovelUpdatesParser.releaseFor(releases, progress);
      if (r != null) await _mark(sid, slug, r);
    }
    // [score]: the site's ratings are not wired up here — no client of the
    // site that this was checked against writes them either.
  }

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
  }) async {
    if (!_canWrite(kind)) return;
    final slug = await _slugFor(title: title, pinnedId: pinnedId);
    if (slug == null) return;
    final sid = await _postIdFor(slug);
    if (sid == null) return;
    // `checked=noo` is Novel Library's remove-from-list call, kept verbatim:
    // `no` only clears the read marker.
    if (await _write(
      '/readinglist_update.php?rid=0&sid=$sid&checked=noo',
      slug,
    )) {
      _forgetLibrary();
    }
  }

  // ── session relay (TV) ───────────────────────────────────────────────────

  /// Not relayable: the session is the in-app browser's cookies, which never
  /// leave this device, so an account name alone would make the TV think it
  /// was signed in when it can't make a single request.
  @override
  Map<String, dynamic>? exportSession() => null;

  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}
