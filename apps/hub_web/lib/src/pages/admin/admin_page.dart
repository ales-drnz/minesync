// Area Admin (`/admin/<sezione>`): intestazione con l'ultima modifica e la
// ricerca di un'impostazione, menu delle sezioni con i loro segnali (membri,
// disco, server con valori propri, Telegram) e i server, strip di stato
// (ZTNET, disco, Telegram, aggiornamenti), la sezione e la barra delle
// modifiche non salvate. I membri vedono «Area riservata agli admin».
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../router.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';
import '../../widgets/page.dart';
import 'admin_data.dart';
import 'admin_widgets.dart';
import 'sections/basic_sections.dart';
import 'sections/exclusions_section.dart';
import 'sections/history_section.dart';
import 'sections/members_section.dart';
import 'sections/system_section.dart';
import 'sections/telegram_section.dart';

class AdminPage extends StatelessWidget {
  const AdminPage({super.key, this.section});

  /// null = l'area (`/admin`), che apre Generale.
  final AdminSection? section;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    if (app.me != null && !app.isAdmin) return const AdminOnly();
    return _AdminArea(section: section);
  }

  static String sectionLabel(AdminStrings s, AdminSection sec) => switch (sec) {
    AdminSection.general => s.general,
    AdminSection.members => s.members,
    AdminSection.history => s.history,
    AdminSection.sessions => s.sessions,
    AdminSection.protection => s.protection,
    AdminSection.exclusions => s.exclusions,
    AdminSection.telegram => s.telegram,
    AdminSection.stats => s.stats,
    AdminSection.system => s.system,
  };

  static MsIconData sectionIcon(AdminSection sec) => switch (sec) {
    AdminSection.general => MsIcons.gear,
    AdminSection.members => MsIcons.players,
    AdminSection.history => MsIcons.history,
    AdminSection.sessions => MsIcons.play,
    AdminSection.protection => MsIcons.shield,
    AdminSection.exclusions => MsIcons.filter,
    AdminSection.telegram => MsIcons.bell,
    AdminSection.stats => MsIcons.chart,
    AdminSection.system => MsIcons.terminal,
  };
}

class _AdminArea extends StatefulWidget {
  const _AdminArea({required this.section});

  final AdminSection? section;

  @override
  State<_AdminArea> createState() => _AdminAreaState();
}

class _AdminAreaState extends State<_AdminArea> {
  late final AdminData _data;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _data = AdminData(HubStateScope.read(context))
      ..onSaved = _saved
      ..onSaveError = _saveError;
    _data.load();
    _data.loadDetails();
    _q.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(_AdminArea old) {
    super.didUpdateWidget(old);
    // cambiando sezione le bozze rimaste si salvano subito
    if (old.section != widget.section) unawaited(_data.flush());
  }

  void _saved(int n) {
    if (!mounted) return;
    final s = context.s.admin;
    toast(context, s.savedTitle, text: s.savedText(n));
  }

  void _saveError(Object e) {
    if (mounted) toastError(context, e);
  }

  @override
  void dispose() {
    _data.dispose();
    _q.dispose();
    super.dispose();
  }

  AdminSection get _current => widget.section ?? AdminSection.general;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final a = s.admin;
    final g = PixelScope.of(context);
    return AdminScope(
      data: _data,
      child: Builder(
        builder: (context) {
          final d = AdminScope.of(context);
          final body = PageBody(
            title: widget.section == null ? a.title : AdminPage.sectionLabel(a, widget.section!),
            children: [
              _Head(search: _q),
              if (_q.text.trim().isNotEmpty) _SearchResults(query: _q.text, onPick: _q.clear),
              LayoutBuilder(
                builder: (context, box) {
                  final nav = _Menu(current: _current);
                  final content = MsStack(
                    gap: 24,
                    children: [const _StatusStrip(), _sectionBody(d)],
                  );
                  if (box.maxWidth < g.d(256 + 24 + 640)) {
                    return MsStack(gap: 24, children: [nav, content]);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: g.d(24),
                    children: [
                      SizedBox(width: g.d(256), child: nav),
                      Expanded(child: content),
                    ],
                  );
                },
              ),
              // spazio per la barra delle modifiche
              if (d.pending > 0) SizedBox(height: g.d(72)),
            ],
          );
          return Stack(
            children: [
              Positioned.fill(child: body),
              if (d.pending > 0 || d.saving)
                Positioned(
                  left: g.d(16),
                  right: g.d(16),
                  bottom: g.d(16),
                  child: const Align(alignment: Alignment.bottomCenter, child: _SaveBar()),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionBody(AdminData d) {
    final s = context.s.admin;
    if (d.settings == null &&
        _current != AdminSection.system &&
        _current != AdminSection.telegram) {
      return MsPanel(
        child: LoadState(error: d.settingsError, title: s.loadError, onRetry: d.reloadSettings),
      );
    }
    return switch (_current) {
      AdminSection.general => const GeneralSection(),
      AdminSection.members => const MembersSection(),
      AdminSection.history => const HistorySection(),
      AdminSection.sessions => const SessionsSection(),
      AdminSection.protection => const ProtectionSection(),
      AdminSection.exclusions => const ExclusionsSection(),
      AdminSection.telegram => const TelegramSection(),
      AdminSection.stats => const StatsSection(),
      AdminSection.system => const SystemSection(),
    };
  }
}

/// Titolo, ultima modifica e ricerca.
class _Head extends StatelessWidget {
  const _Head({required this.search});

  final TextEditingController search;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final d = AdminScope.of(context);
    final s = context.s;
    final a = s.admin;
    final g = PixelScope.of(context);
    final ch = d.settings?.changed;
    final lead = ch == null
        ? a.leadHot
        : '${a.leadHot} ${a.lastChange(ch.by, s.fmt.when(app.localTime(ch.at), app.now()))}';
    return Wrap(
      spacing: g.d(16),
      runSpacing: g.d(16),
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: g.d(720)),
          child: MsStack(
            gap: 4,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsEyebrow(a.eyebrow(app.hub?.name ?? 'MineSync')),
              if (narrow(context)) MsText.h2(a.title) else MsText.h1(a.title),
              MsText(lead, tone: MsTextTone.secondary),
            ],
          ),
        ),
        SizedBox(
          width: g.d(320),
          child: MsTextInput(
            controller: search,
            placeholder: a.searchPlaceholder,
            semanticLabel: a.searchLabel,
          ),
        ),
      ],
    );
  }
}

/// Voci cercabili: sezione e testi delle sue impostazioni, più qualche
/// parola chiave che non compare nei testi (es. «autosave»).
List<(AdminSection, String, String)> searchIndex(AdminStrings a) => [
  for (final (sec, t) in _labels(a))
    (
      sec,
      t,
      switch (t) {
        _ when t == a.autosave => 'autosave',
        _ when t == a.manual => 'gc',
        _ when t == a.minFree => 'disk disco',
        _ when t == a.access.trust => 'ztnet',
        _ => '',
      },
    ),
];

List<(AdminSection, String)> _labels(AdminStrings a) {
  final x = a.access;
  final b = a.bot;
  return [
    for (final t in [a.nameLabel, a.langLabel]) (AdminSection.general, t),
    for (final t in [x.trust, x.refresh, x.ztUrl, x.ztToken, x.ztNetwork, x.checkNow])
      (AdminSection.members, t),
    for (final t in [a.keepLast, a.keepHours, a.keepDays, a.minFree, a.manual, a.perServer])
      (AdminSection.history, t),
    for (final t in [a.autosave, a.autostop, a.crash, a.portTest]) (AdminSection.sessions, t),
    for (final t in [a.ratio, a.minFiles]) (AdminSection.protection, t),
    for (final t in [b.exTitle, b.testTitle, b.newPattern]) (AdminSection.exclusions, t),
    for (final t in [
      b.enabled,
      b.token,
      b.chat,
      b.language,
      b.announce,
      b.coalesce,
      b.pushWarn,
      b.topics,
      b.sendTest,
    ])
      (AdminSection.telegram, t),
    (AdminSection.stats, a.statsKept),
    for (final t in [
      x.version,
      x.uptime,
      x.http,
      x.dns,
      x.hosts,
      x.dataDir,
      x.admins,
      x.signing,
      x.tz,
      x.web,
    ])
      (AdminSection.system, t),
  ];
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.query, required this.onPick});

  final String query;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final a = context.s.admin;
    final q = query.trim().toLowerCase();
    final hits = [
      for (final (sec, t, keys) in searchIndex(a))
        if (t.toLowerCase().contains(q) ||
            keys.contains(q) ||
            AdminPage.sectionLabel(a, sec).toLowerCase().contains(q))
          (sec, t),
    ];
    return MsPanel(
      title: a.searchLabel,
      child: hits.isEmpty
          ? MsText(a.searchNone, tone: MsTextTone.secondary)
          : MsList(
              children: [
                for (final (sec, t) in hits.take(8))
                  MsListRow(
                    title: t,
                    meta: AdminPage.sectionLabel(a, sec),
                    lead: MsIcon(AdminPage.sectionIcon(sec)),
                    onTap: () {
                      onPick();
                      context.go(HubRoutes.adminSection(sec));
                    },
                  ),
              ],
            ),
    );
  }
}

/// Menu delle sezioni e dei server.
class _Menu extends StatelessWidget {
  const _Menu({required this.current});

  final AdminSection current;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final d = AdminScope.of(context);
    final s = context.s;
    final a = s.admin;
    final disk = d.usage?.disk ?? app.hub?.disk;
    Widget? trail(AdminSection sec) {
      switch (sec) {
        case AdminSection.members:
          final n = d.members?.members.where((m) => m.authorized).length;
          return n == null ? null : MsNavTrail(text: '$n');
        case AdminSection.history:
          if (disk == null) return null;
          final tone = diskTone(disk);
          final pct = s.fmt.percentSpaced(diskUsed(disk));
          return tone == MsStatusTone.ok ? MsNavTrail(text: pct) : MsPill(pct, tone: tone);
        case AdminSection.sessions || AdminSection.protection:
          final n = d.overriding(sec.slug).length;
          return n == 0 ? null : MsNavTrail(text: a.navOwn(n));
        case AdminSection.telegram:
          final t = d.telegram;
          if (t == null) return null;
          return MsNavTrail(
            text: switch (t.state) {
              TelegramState.active => a.navActive,
              TelegramState.disabled => a.pillOff,
              TelegramState.incomplete => a.tgIncomplete,
              TelegramState.error => a.pillError,
            },
          );
        default:
          return null;
      }
    }

    final g = PixelScope.of(context);
    return Semantics(
      container: true,
      label: a.navLabel,
      child: MsPanel(
        padding: MsPanelPadding.none,
        child: Padding(
          padding: EdgeInsets.all(g.d(8)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MsSidebarSection(a.navHub),
              MsNav(
                children: [
                  for (final sec in AdminSection.values)
                    MsNavItem(
                      label: sec == AdminSection.sessions
                          ? a.sessionsNav
                          : AdminPage.sectionLabel(a, sec),
                      icon: MsIcon(AdminPage.sectionIcon(sec)),
                      current: sec == current,
                      trailing: trail(sec),
                      onPressed: () => context.go(HubRoutes.adminSection(sec)),
                    ),
                ],
              ),
              if (app.spaces.isNotEmpty) ...[
                const PixelGap(0, 8),
                MsSidebarSection(a.navServers),
                MsNav(
                  children: [
                    for (final sp in app.spaces)
                      MsNavItem(
                        label: sp.name,
                        icon: MsTexture(textureFor(sp.id), width: g.d(16), height: g.d(16)),
                        trailing: MsNavTrail(
                          dot: sp.lock == null
                              ? MsNavDotKind.free
                              : sp.lock!.stale
                              ? MsNavDotKind.stale
                              : MsNavDotKind.play,
                        ),
                        onPressed: () => context.go(HubRoutes.server(sp.id, ServerTab.admin)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Quattro riquadri: ZTNET, disco, Telegram, aggiornamenti.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final d = AdminScope.of(context);
    final s = context.s;
    final a = s.admin;
    Widget card(AdminSection sec, Widget pill, String title, String text) => MsCard(
      semanticLabel: '$title: $text',
      onTap: () => context.go(HubRoutes.adminSection(sec)),
      child: Row(
        children: [
          pill,
          const PixelGap(10, 0),
          Expanded(
            child: MsStack(
              gap: 0,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MsText(title, weight: 600, maxLines: 1),
                MsText.small(text, tone: MsTextTone.secondary, maxLines: 1),
              ],
            ),
          ),
        ],
      ),
    );
    final z = d.members?.ztnet;
    final admins = d.members?.members.where((m) => m.role == MemberRole.admin && m.authorized);
    final disk = d.usage?.disk ?? app.hub?.disk;
    final t = d.telegram;
    final sys = d.system;
    final cards = <Widget>[
      card(
        AdminSection.members,
        switch (z?.state) {
          ZtnetState.ok => MsPill(a.pillOk, tone: MsStatusTone.ok),
          ZtnetState.error => MsPill(a.pillError, tone: MsStatusTone.err),
          _ => MsPill(a.pillOff),
        },
        a.statusZtnet,
        z == null ? '—' : a.ztnetSummary(z.members, admins?.length ?? 0),
      ),
      if (disk != null)
        card(
          AdminSection.history,
          MsPill(s.fmt.percentSpaced(diskUsed(disk)), tone: diskTone(disk)),
          a.statusDisk,
          a.diskFree(s.fmt.size(disk.free)),
        ),
      card(
        AdminSection.telegram,
        switch (t?.state) {
          TelegramState.active => MsPill(a.pillOk, tone: MsStatusTone.ok),
          TelegramState.error => MsPill(a.pillError, tone: MsStatusTone.err),
          TelegramState.incomplete => MsPill(a.tgIncomplete, tone: MsStatusTone.warn),
          _ => MsPill(a.pillOff),
        },
        a.statusTelegram,
        switch (t) {
          null => '—',
          TelegramStatus(state: TelegramState.disabled) => a.pillOff,
          TelegramStatus(lastSentAt: final at?) => a.tgLast(
            s.fmt.eventTime(app.localTime(at), app.now()),
          ),
          _ => a.tgNever,
        },
      ),
      card(
        AdminSection.system,
        switch (sys == null ? null : signingOf(sys.updates)) {
          SigningState.all => MsPill(a.pillOk, tone: MsStatusTone.ok),
          SigningState.some ||
          SigningState.unsigned => MsPill(a.pillError, tone: MsStatusTone.warn),
          _ => MsPill(a.pillOff),
        },
        a.statusUpdates,
        switch (sys == null ? null : signingOf(sys.updates)) {
          SigningState.all => a.updatesSigned(sys!.updates.length),
          SigningState.some || SigningState.unsigned => a.updatesUnsigned,
          SigningState.none => a.updatesNone,
          null => '—',
        },
      ),
    ];
    return Semantics(
      container: true,
      label: a.statusLabel,
      child: AutoGrid(minWidth: 200, gap: 12, children: cards),
    );
  }
}

/// Barra in basso con le modifiche in attesa: Annulla, Salva e applica.
class _SaveBar extends StatelessWidget {
  const _SaveBar();

  @override
  Widget build(BuildContext context) {
    final d = AdminScope.of(context);
    final a = context.s.admin;
    final g = PixelScope.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: g.d(MsSize.maxWidth - 48)),
      child: Semantics(
        container: true,
        label: a.unsavedRegion,
        child: MsPanel(
          raised: true,
          child: MsRow(
            gap: 16,
            children: [
              MsPill(d.pending == 0 ? a.saving : a.unsaved(d.pending), tone: MsStatusTone.warn),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: g.d(520)),
                child: MsText.small(a.autosaveSoon, tone: MsTextTone.secondary),
              ),
              MsButton(
                label: a.discard,
                variant: MsButtonVariant.ghost,
                onPressed: d.saving ? null : d.discard,
              ),
              MsButton(
                label: a.saveNow,
                variant: MsButtonVariant.primary,
                icon: const MsIcon(MsIcons.save),
                loading: d.saving,
                onPressed: d.saving || d.pending == 0 ? null : d.flush,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pagina per chi non è admin: "Area riservata agli admin".
class AdminOnly extends StatelessWidget {
  const AdminOnly({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s.shell;
    return PageBody(
      title: s.adminOnlyTitle,
      children: [
        Padding(
          padding: EdgeInsets.only(top: PixelScope.of(context).d(40)),
          child: MsEmptyState(
            title: s.adminOnlyTitle,
            text: s.adminOnlyText,
            art: const MsIcon(MsIcons.shield, size: 32),
            action: MsButton(
              label: s.backToServers,
              variant: MsButtonVariant.primary,
              icon: const MsIcon(MsIcons.server),
              onPressed: () => context.go(HubRoutes.overview),
            ),
          ),
        ),
      ],
    );
  }
}
