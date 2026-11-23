// Header dell'hub web: marchio, schede Server / Download / Admin (solo
// admin), pillola dal vivo con la latenza, "nome · ruolo", IT/EN e tema.
// Sotto i 760 px di design diventa due righe (marchio e comandi, poi le
// schede); sotto i 480 resta solo il logo e la pillola dal vivo passa
// accanto alle schede. Il nome utente compare solo con l'header largo.
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_protocol/ms_protocol.dart' show Me;
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../router.dart';
import '../state/hub_state.dart';
import '../widgets/page.dart';

/// Versione della web UI (quella del pacchetto).
const webVersion = '0.1.0';

/// Scheda principale corrente da un percorso.
enum HubNav { servers, download, admin, none }

HubNav navFor(String path) {
  if (path == '/' || path.startsWith('/server')) return HubNav.servers;
  if (path == HubRoutes.download || path.startsWith('${HubRoutes.download}/')) {
    return HubNav.download;
  }
  if (path == HubRoutes.admin || path.startsWith('${HubRoutes.admin}/')) return HubNav.admin;
  return HubNav.none;
}

class HubHeader extends StatelessWidget {
  const HubHeader({super.key, required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.shell;
    final denied = app.connection == HubConnection.denied;
    final current = navFor(location);
    final nav = denied
        ? const <Widget>[]
        : [
            MsHeaderLink(
              label: s.navServers,
              icon: const MsIcon(MsIcons.server),
              current: current == HubNav.servers,
              onTap: () => context.go(HubRoutes.overview),
            ),
            MsHeaderLink(
              label: s.navDownload,
              icon: const MsIcon(MsIcons.download),
              current: current == HubNav.download,
              onTap: () => context.go(HubRoutes.download),
            ),
            if (app.isAdmin)
              MsHeaderLink(
                label: s.navAdmin,
                icon: const MsIcon(MsIcons.shield),
                current: current == HubNav.admin,
                onTap: () => context.go(HubRoutes.admin),
              ),
          ];
    return LayoutBuilder(
      builder: (context, c) {
        final w = designWidth(context, c.maxWidth);
        final narrow = w < 760;
        final tiny = w < 480;
        final brand = MsHeaderBrand(
          // sul telefono solo il logo: il nome dell'hub è in cima alla pagina
          name: tiny ? '' : _short(app.hub?.name ?? 'MineSync', narrow ? 18 : 28),
          version: narrow ? null : s.version(app.hub?.version ?? webVersion),
          logo: const MsLogo(size: 32),
          onTap: denied ? null : () => context.go(HubRoutes.overview),
        );
        final end = [
          if (!denied && !tiny) _LivePill(compact: narrow),
          if (!narrow && app.me != null) _User(me: app.me!),
          const _LangSwitch(),
          const _ThemeButton(),
        ];
        if (!narrow) {
          return MsHeader(navLabel: s.navLabel, brand: brand, nav: nav, end: end);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MsHeader(brand: brand, end: end),
            if (nav.isNotEmpty)
              MsHeader(
                navLabel: s.navLabel,
                nav: nav,
                // sul telefono la pillola dal vivo sta accanto alle schede
                end: [if (tiny) const _LivePill(compact: true)],
              ),
          ],
        );
      },
    );
  }
}

/// [name] al massimo di [max] caratteri, con i puntini.
String _short(String name, int max) =>
    name.characters.length <= max ? name : '${name.characters.take(max - 1)}…';

class _LivePill extends StatelessWidget {
  const _LivePill({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.shell;
    return switch (app.connection) {
      HubConnection.online => MsTooltip(
        message: s.liveTip,
        child: MsLive(compact || app.latencyMs == null ? s.liveShort : s.live(app.latencyMs!)),
      ),
      HubConnection.offline => MsLive(s.offline, online: false),
      HubConnection.connecting || HubConnection.denied => MsLive(s.connecting, online: false),
    };
  }
}

class _User extends StatelessWidget {
  const _User({required this.me});
  final Me me;

  @override
  Widget build(BuildContext context) {
    final s = context.s.shell;
    return MsText.rich(
      [MsSpan(me.name, strong: true), MsSpan(' (${me.admin ? s.roleAdmin : s.roleMember})')],
      kind: MsTextKind.small,
      tone: MsTextTone.secondary,
    );
  }
}

class _LangSwitch extends StatelessWidget {
  const _LangSwitch();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    return MsSegmented<Lang>(
      semanticLabel: context.s.shell.langLabel,
      value: app.lang,
      segments: const [
        MsSegment(value: Lang.it, label: 'IT', semanticLabel: 'Italiano'),
        MsSegment(value: Lang.en, label: 'EN', semanticLabel: 'English'),
      ],
      onChanged: app.setLang,
    );
  }
}

class _ThemeButton extends StatelessWidget {
  const _ThemeButton();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.shell;
    final dark = MsTheme.of(context).brightness == Brightness.dark;
    return MsButton.icon(
      icon: const MsIcon(MsIcons.sun),
      semanticLabel: dark ? s.toLight : s.toDark,
      variant: MsButtonVariant.ghost,
      onPressed: () => app.setTheme(dark ? ThemeChoice.light : ThemeChoice.dark),
    );
  }
}
