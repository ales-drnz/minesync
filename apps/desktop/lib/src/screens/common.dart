// Pezzi comuni alle schermate dei server: cornice di pagina, schede,
// lock, testo con grassetti, copia negli appunti, testi degli errori.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../app.dart';
import '../l10n/l10n.dart';
import '../state/app_state.dart';

/// Contenuto di una schermata: scorre in verticale, margini del canvas
/// (24 sopra, 32 ai lati, 40 sotto), larghezza massima del design.
class ScreenBody extends StatelessWidget {
  const ScreenBody({super.key, required this.children, this.gap = 16});

  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(g.d(24), g.d(20), g.d(24), g.d(24)),
      // tutta la larghezza della finestra: niente spazio vuoto a destra
      child: MsStack(gap: gap, children: children),
    );
  }
}

/// Colonne affiancate che vanno a capo sotto [minWidth] (come le griglie
/// flex del canvas): ogni figlio ha un peso.
///
/// Affiancate sono alte uguali ([MsEqualRow]): un pannello riempie la
/// colonna con il piede in fondo, una colonna di più pannelli usa
/// `MsStack(fillLast: true)` così l'ultimo arriva al fondo della vicina.
/// Con [equal] falso ogni colonna resta alta quanto il suo contenuto (es.
/// un dettaglio accanto a un elenco lungo).
class Columns extends StatelessWidget {
  const Columns({
    super.key,
    required this.children,
    this.minWidth = 380,
    this.gap = 16,
    this.equal = true,
  });

  final List<(int, Widget)> children;

  /// Colonne alte uguali quando sono affiancate.
  final bool equal;

  /// Larghezza minima della colonna più stretta, in px di design.
  final double minWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        // affiancate solo se anche la colonna più stretta (flex minore) è
        // larga almeno [minWidth]: con 5:3 la colonna da 3 non va sotto
        final flexes = [for (final e in children) e.$1];
        final total = flexes.fold(0, (a, b) => a + b);
        final least = flexes.reduce((a, b) => a < b ? a : b);
        final need = g.d(minWidth) * total / least + (children.length - 1) * g.d(gap);
        if (c.maxWidth < need) {
          return MsStack(gap: gap, children: [for (final e in children) e.$2]);
        }
        if (equal) {
          return MsEqualRow(
            gap: gap,
            flex: [for (final e in children) e.$1],
            children: [for (final e in children) e.$2],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: g.d(gap),
          children: [for (final e in children) Expanded(flex: e.$1, child: e.$2)],
        );
      },
    );
  }
}

/// Griglia di elementi larghi almeno [minWidth] (auto-fill del canvas).
class AutoGrid extends StatelessWidget {
  const AutoGrid({
    super.key,
    required this.children,
    this.minWidth = 300,
    this.gap = 16,
    this.minColumns = 1,
  });

  final List<Widget> children;
  final double minWidth;
  final double gap;

  /// Con pochi figli non si usano più colonne del necessario, ma almeno
  /// [minColumns]: una card sola prende metà riga invece di un terzo.
  final int minColumns;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final gap = g.d(this.gap);
        final fit = ((c.maxWidth + gap) / (g.d(minWidth) + gap)).floor().clamp(1, 99);
        final want = children.length < minColumns ? minColumns : children.length;
        final cols = minColumns > 1 ? fit.clamp(1, want) : fit;
        // righe di elementi alti uguali (come le colonne affiancate): due
        // card vicine finiscono sulla stessa riga anche con testi diversi
        return MsStack(
          gap: this.gap,
          children: [
            for (var i = 0; i < children.length; i += cols)
              MsEqualRow(
                gap: this.gap,
                children: [
                  for (var j = i; j < i + cols; j++)
                    j < children.length ? children[j] : const SizedBox.shrink(),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Testo con parti in grassetto.
class RichLine extends StatelessWidget {
  const RichLine(this.parts, {super.key, this.kind = MsTextKind.body, this.tone});

  final Rich parts;
  final MsTextKind kind;
  final MsTextTone? tone;

  @override
  Widget build(BuildContext context) => MsText.rich(
    [for (final p in parts) MsSpan(p.$1, strong: p.$2)],
    kind: kind,
    tone: tone ?? MsTextTone.primary,
  );
}

/// Schede del server: Panoramica, Sessione, Mod, Storia.
enum ServerTab { overview, mods, history }

class ServerTabs extends StatelessWidget {
  const ServerTabs({super.key, required this.space, required this.current});

  final String space;
  final ServerTab current;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.server;
    final sp = app.space(space);
    final head = sp?.head?.n;
    return MsTabs<ServerTab>(
      semanticLabel: s.tabsLabel,
      value: current,
      tabs: [
        MsTab(value: ServerTab.overview, label: s.tabOverview, icon: const MsIcon(MsIcons.server)),
        if (sp?.profile != Profile.generic)
          MsTab(
            value: ServerTab.mods,
            label: context.s.modpack.tab,
            icon: const MsIcon(MsIcons.mods),
            count: (sp?.world?.mods ?? 0) > 0 ? '${sp!.world!.mods}' : null,
          ),
        MsTab(
          value: ServerTab.history,
          label: s.tabHistory,
          icon: const MsIcon(MsIcons.history),
          count: head?.toString(),
        ),
      ],
      onChanged: (t) => app.go(switch (t) {
        ServerTab.overview => ServerRoute(space),
        ServerTab.mods => ModpackRoute(space),
        ServerTab.history => HistoryRoute(space),
      }),
    );
  }
}

/// Come appare il lock di un server a chi guarda.
enum LockView { free, play, stale, mine }

LockView lockViewOf(SpaceSummary sp, Me? me) {
  final l = sp.lock;
  if (l == null) return LockView.free;
  if (l.stale) return LockView.stale;
  if (me != null && l.memberId == me.id) return LockView.mine;
  return LockView.play;
}

/// Riga secondaria di [MsListRow] con più dati brevi (autore, ora,
/// dimensione…): [MsListRow] la riconosce e mostra ogni dato come
/// etichetta piatta ([MsMeta]), senza separatori a schermo. I dati vuoti
/// si saltano.
String listMeta(Iterable<String?> items) => [
  for (final i in items)
    if (i != null && i.isNotEmpty) i,
].join(' · ');

/// Il lock di [sp] come [MsLock].
Widget lockBadge(BuildContext context, SpaceSummary sp, {bool big = false}) {
  final app = AppStateScope.of(context);
  final s = context.s.server;
  final l = sp.lock;
  return switch (lockViewOf(sp, app.me)) {
    LockView.free => MsLock(label: s.lockFree, big: big),
    LockView.play => MsLock(label: s.lockPlay, state: MsLockState.play, meta: l!.name, big: big),
    LockView.mine => MsLock(label: s.lockPlay, state: MsLockState.play, meta: s.you, big: big),
    LockView.stale => MsLock(
      label: s.lockStale,
      state: MsLockState.stale,
      meta: l!.memberId == app.me?.id ? s.you : l.name,
      big: big,
    ),
  };
}

/// Texture del riquadro di un server, scelta in modo stabile dall'id.
MsTextureKind textureFor(String id) {
  const kinds = [
    MsTextureKind.grass,
    MsTextureKind.stone,
    MsTextureKind.amethyst,
    MsTextureKind.wood,
    MsTextureKind.copper,
    MsTextureKind.dirt,
    MsTextureKind.slate,
  ];
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return kinds[h % kinds.length];
}

/// Riquadro quadrato del server: la sua `server-icon.png` dall'hub
/// ([iconUrl]) disegnata a pixel netti, o una texture scelta dall'id se non
/// c'è.
class ServerTile extends StatelessWidget {
  const ServerTile({super.key, required this.id, this.iconUrl, this.size = 56});

  final String id;
  final Uri? iconUrl;

  /// Lato esterno in px di design.
  final double size;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final inner = g.d(size - 8);
    final texture = MsTexture(textureFor(id), width: inner, height: inner);
    final url = iconUrl;
    return MsSlot.square(
      side: size,
      child: url == null
          ? texture
          : Image.network(
              url.toString(),
              width: inner,
              height: inner,
              fit: BoxFit.cover,
              // l'icona è pixel art 64×64: niente sfumature
              filterQuality: FilterQuality.none,
              isAntiAlias: false,
              gaplessPlayback: true,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => texture,
            ),
    );
  }
}

/// Icona di un server nella barra laterale: la sua `server-icon.png` se
/// c'è, altrimenti l'icona generica dei server.
class ServerNavIcon extends StatelessWidget {
  const ServerNavIcon({super.key, required this.url});
  final Uri? url;

  @override
  Widget build(BuildContext context) {
    const fallback = MsIcon(MsIcons.server);
    final u = url;
    if (u == null) return fallback;
    // riempie lo spazio dell'icona della voce (24 px nella barra laterale)
    final side = IconTheme.of(context).size ?? PixelScope.of(context).d(16);
    return Image.network(
      u.toString(),
      width: side,
      height: side,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.none,
      isAntiAlias: false,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

/// URL dell'icona del server [id] sull'hub, legato alla versione [n] perché
/// la cache dell'immagine cambi quando cambia l'icona.
Uri? serverIconUrl(AppState app, String id, int? n) =>
    app.client?.base.resolve('api/v1/spaces/${Uri.encodeComponent(id)}/icon?v=${n ?? 0}');

/// Indirizzi con cui gli amici entrano in [sp]: [fixed] è il nome DNS
/// dell'hub (`zerotier.<id>.<zona>`, sempre lo stesso chiunque ospiti; la
/// porta arriva dal record SRV), [direct] l'IP di chi ospita visto dall'hub,
/// con la porta. Null quando non si sanno (DNS spento, nessuno ospita).
typedef JoinAddresses = ({String? fixed, String? direct});

JoinAddresses joinAddresses(SpaceSummary sp, {List<String> local = const [], int? port}) {
  final l = sp.lock;
  final fixed = sp.dnsName == null || sp.dnsName!.isEmpty ? null : sp.dnsName;
  final p = port ?? l?.info.port ?? defaultMcPort;
  // l'IP registrato dall'hub; in mancanza (hub vecchio, lock appena preso)
  // quello dichiarato dal client o il primo di questo PC
  final ip = [
    l?.ip,
    l?.info.address,
    ...local,
  ].firstWhere((a) => a != null && a.isNotEmpty, orElse: () => null);
  return (fixed: fixed, direct: ip == null ? null : '$ip:$p');
}

/// L'indirizzo principale per entrare in [sp]: quello fisso se c'è,
/// altrimenti l'IP diretto.
String? joinAddress(SpaceSummary sp) {
  final a = joinAddresses(sp);
  return a.fixed ?? a.direct;
}

/// Colore del badge di un evento dell'attività: neutro per la vita normale
/// (salvataggi, partite), giallo da guardare, rosso quando qualcosa non va.
/// Così il colore si nota solo quando serve.
MsBadgeKind eventBadgeKind(HubEvent e) => switch (e.type) {
  EventType.force || EventType.gcError => MsBadgeKind.force,
  EventType.stale || EventType.telegramError => MsBadgeKind.disk,
  EventType.port => e.data['state'] == 'reachable' ? MsBadgeKind.neutral : MsBadgeKind.force,
  EventType.disk => e.data['level'] == 'full' ? MsBadgeKind.force : MsBadgeKind.disk,
  EventType.ztnet => e.data['state'] == 'ok' ? MsBadgeKind.neutral : MsBadgeKind.disk,
  EventType.restore || EventType.restoreFile => MsBadgeKind.restore,
  _ => MsBadgeKind.neutral,
};

/// Porta di Minecraft se server.properties non dice altro.
const defaultMcPort = 25565;

/// Copia [text] negli appunti e lo dice con una notifica.
Future<void> copyText(BuildContext context, String text, String done) async {
  final toasts = ToastScope.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  toasts.show(MsToastData(title: done, tone: MsToastTone.ok));
}

/// Mostra una notifica a comparsa.
void toast(BuildContext context, String title, {String? text, MsToastTone tone = MsToastTone.ok}) =>
    ToastScope.of(context).show(MsToastData(title: title, text: text, tone: tone));

/// Testo per l'utente di un errore del sync o dell'hub.
String errorText(AppStrings s, Object e) {
  final c = s.common;
  String cap(String t) => t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  if (e is SyncException) {
    return cap(switch (e.kind) {
      SyncErrorKind.dirtyLocal => s.server.dirtyText(
        diverged: e.diverged,
        changed: e.changed.length,
        removed: e.removed.length,
      ),
      SyncErrorKind.staleBase => c.errStaleBase,
      SyncErrorKind.massDelete => c.errMassDelete(e.removed.length),
      SyncErrorKind.emptyRemote => c.errEmptyRemote,
      SyncErrorKind.lockLost => c.errLockLost,
      SyncErrorKind.spaceGone => c.errSpaceGone,
      SyncErrorKind.badManifest => c.errBadManifest,
      SyncErrorKind.corruptDownload => c.errCorruptDownload,
      SyncErrorKind.blobRejected => c.errBlobRejected,
      SyncErrorKind.localDiskFull => c.errLocalDiskFull,
      SyncErrorKind.hubDiskFull => c.errHubDiskFull,
      SyncErrorKind.dirSymlink => c.errDirSymlink(e.path ?? ''),
      SyncErrorKind.outboxNoSpace => c.errOutboxNoSpace,
      SyncErrorKind.snapshotStale => c.errSnapshotStale,
      SyncErrorKind.cancelled => c.errCancelled,
    });
  }
  if (e is HubUnreachable) return s.server.unreachable;
  if (e is TransferStalled) return cap(c.errStalled);
  if (e is ApiError) {
    return cap(switch (e.code) {
      ErrorCode.locked => c.errLocked(_holder(e) ?? '?'),
      ErrorCode.lockLost => c.errLockLost,
      ErrorCode.unauthenticated => c.errUnauthenticated,
      ErrorCode.forbidden => c.errForbidden,
      ErrorCode.spaceGone || ErrorCode.notFound => c.errSpaceGone,
      ErrorCode.diskFull => c.errHubDiskFull,
      _ => e.message,
    });
  }
  return '$e';
}

String? _holder(ApiError e) {
  final l = e.details['lock'];
  return l is Map<String, Object?> ? l['name'] as String? : null;
}

/// Scorciatoie da tastiera di una schermata. Una scorciatoia senza
/// callback è spenta; nessuna scatta mentre si scrive in un campo di testo,
/// così le lettere arrivano al campo.
class KeyShortcuts extends StatelessWidget {
  const KeyShortcuts({super.key, required this.bindings, required this.child});

  final Map<ShortcutActivator, VoidCallback?> bindings;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final entries = bindings.entries.toList();
    return Shortcuts(
      shortcuts: {for (var i = 0; i < entries.length; i++) entries[i].key: _KeyIntent(i)},
      child: Actions(
        actions: {
          _KeyIntent: _KeyAction([for (final e in entries) e.value]),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _KeyIntent extends Intent {
  const _KeyIntent(this.index);
  final int index;
}

class _KeyAction extends Action<_KeyIntent> {
  _KeyAction(this.callbacks);
  final List<VoidCallback?> callbacks;

  @override
  bool isEnabled(_KeyIntent intent) =>
      callbacks[intent.index] != null &&
      FocusManager.instance.primaryFocus?.context?.widget is! EditableText;

  @override
  Object? invoke(_KeyIntent intent) {
    callbacks[intent.index]!();
    return null;
  }
}

/// Gioca su [id]: collega la cartella proposta se serve, ferma il
/// pre-scarico e avvia la sessione (con [force] prende il lock di chi lo
/// tiene). Se la sessione non può partire da qui (es. ne gira già una) si va
/// comunque alla sua schermata, che spiega cosa succede.
Future<void> startPlay(AppState app, String id, {bool force = false}) async {
  final ss = app.spaceState(id);
  if (!ss.linked) await ss.linkTo(ss.suggestedFolder);
  await ss.settle();
  try {
    await app.play(id, force: force);
  } on StateError {
    app.go(ServerRoute(id));
  }
}
