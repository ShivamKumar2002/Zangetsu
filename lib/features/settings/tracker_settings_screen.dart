import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/repository/source_actions.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/novelupdates_import.dart';
import '../../core/tracker/novelupdates_parser.dart';
import '../../core/tracker/novelupdates_service.dart';
import '../../l10n/l10n.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_binding_store.dart';
import '../../core/ui/app_dialog.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';

/// Connect / disconnect any [Tracker] (AniList, MyAnimeList, Simkl) and toggle
/// its auto-sync. Connecting opens the provider's OAuth consent in the browser;
/// the token returns via the `zangetsu://…` deep link captured by the service.
class TrackerSettingsScreen extends StatefulWidget {
  const TrackerSettingsScreen({super.key, required this.tracker});

  final Tracker tracker;

  @override
  State<TrackerSettingsScreen> createState() => _TrackerSettingsScreenState();
}

class _TrackerSettingsScreenState extends State<TrackerSettingsScreen> {
  Tracker get _t => widget.tracker;
  bool _busy = false;
  bool _importing = false;

  Future<void> _connect() async {
    setState(() => _busy = true);
    final ok = await _t.connect();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? context.l10n.connectedAs(_t.viewerName ?? '')
              : context.l10n.trackerConnectionCanceled(_t.displayName),
        ),
      ),
    );
  }

  Future<void> _disconnect() async {
    final ok = await AppDialog.confirm(
      context,
      title: context.l10n.disconnectTrackerQuestion(_t.displayName),
      message: context.l10n.trackerDisconnectBody(_t.displayName),
      confirmLabel: context.l10n.disconnect,
      destructive: true,
    );
    if (ok == true) await _t.disconnect();
  }

  /// Novel Updates only: copy the reading lists into My List, once.
  Future<void> _importNovelUpdates(NovelUpdatesService nu) async {
    setState(() => _importing = true);
    final result = await NovelUpdatesImporter(
      tracker: nu,
      myList: sl<MyListStore>(),
      statuses: sl<ListStatusStore>(),
      sourceInstalled:
          sl.isRegistered<LnReaderManager>() &&
          sl<LnReaderManager>().metaFor('novelupdates') != null,
      signedIn: sl<AuthCubit>().state.isLoggedIn,
      bindings: sl.isRegistered<TrackerBindingStore>()
          ? sl<TrackerBindingStore>()
          : null,
    ).run();
    if (!mounted) return;
    setState(() => _importing = false);
    final l10n = context.l10n;
    final problem = result.problem;
    final cloudflare =
        problem == NovelUpdatesImportProblem.listsUnavailable &&
        nu.lastFailure == NovelUpdatesFailure.cloudflare;
    final message = switch (problem) {
      null => l10n.novelUpdatesImported(result.added, result.skipped),
      NovelUpdatesImportProblem.notConnected ||
      NovelUpdatesImportProblem.listsUnavailable => switch (nu.lastFailure) {
        NovelUpdatesFailure.cloudflare => l10n.novelUpdatesCloudflare,
        NovelUpdatesFailure.signedOut => l10n.novelUpdatesSignedOut,
        _ => l10n.novelUpdatesUnreachable,
      },
      NovelUpdatesImportProblem.noSource => l10n.novelUpdatesNeedsSource,
      NovelUpdatesImportProblem.notSignedIn => l10n.novelUpdatesNeedsAccount,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        // The challenge is passed by visiting the site once in the in-app
        // browser, whose clearance the tracker's requests then carry.
        action: cloudflare
            ? SnackBarAction(
                label: l10n.novelUpdatesOpenSite,
                onPressed: () => openUrlInSourceWebView(
                  '${NovelUpdatesParser.site}/',
                  title: 'Novel Updates',
                ),
              )
            : null,
      ),
    );
  }

  /// The import row, for a connected Novel Updates account.
  Widget _novelUpdatesImport(NovelUpdatesService nu) => SettingsCard(
    children: [
      SettingsTile(
        icon: Icons.playlist_add_rounded,
        title: _importing
            ? context.l10n.novelUpdatesImporting
            : context.l10n.novelUpdatesImport,
        subtitle: _importing ? null : context.l10n.novelUpdatesImportSubtitle,
        onTap: _importing ? null : () => _importNovelUpdates(nu),
        trailing: _importing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(_t.displayName),
      ),
      body: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          final connected = _t.isConnected;
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              _header(connected),
              if (!connected)
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.link_rounded,
                      title: _busy ? context.l10n.connectingEllipsis : context.l10n.connectTracker(_t.displayName),
                      subtitle: _busy ? null : context.l10n.signInToLinkYourAccount,
                      onTap: _busy ? null : _connect,
                      trailing: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : null,
                    ),
                  ],
                )
              else ...[
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.sync_rounded,
                      title: context.l10n.autoSync,
                      subtitle: context.l10n.updateTrackerAsYouWatch(_t.displayName),
                      trailing: Switch.adaptive(
                        value: _t.autoSync,
                        activeThumbColor: AppColors.accent,
                        onChanged: (v) => setState(() => _t.autoSync = v),
                      ),
                    ),
                  ],
                ),
                if (_t case final NovelUpdatesService nu)
                  _novelUpdatesImport(nu),
                SettingsCard(
                  children: [
                    SettingsTile(
                      icon: Icons.logout_rounded,
                      title: context.l10n.disconnect,
                      destructive: true,
                      onTap: _disconnect,
                    ),
                  ],
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(
                  _t is NovelUpdatesService
                      ? context.l10n.novelUpdatesAbout
                      : 'When you start an anime it’s marked Watching, each '
                            'episode you finish updates the count, and a status '
                            'you set on a title is pushed to ${_t.displayName}. '
                            'Anime only.',
                  style: AppText.caption,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(bool connected) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          if (connected && (_t.viewerAvatar?.isNotEmpty ?? false))
            ClipOval(
              child: CachedNetworkImage(
                imageUrl: _t.viewerAvatar!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _fallbackAvatar(),
              ),
            )
          else
            _fallbackAvatar(),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? (_t.viewerName ?? _t.displayName) : _t.displayName,
                  style: AppText.headline.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  connected ? 'Connected' : 'Not connected',
                  style: AppText.caption.copyWith(
                    color: connected ? AppColors.accent : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fallbackAvatar() => Container(
    width: 52,
    height: 52,
    decoration: BoxDecoration(
      color: AppColors.surface2,
      shape: BoxShape.circle,
    ),
    child: const Icon(Icons.person_rounded, color: AppColors.textTertiary),
  );
}
