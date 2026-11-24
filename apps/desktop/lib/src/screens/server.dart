// Panoramica di un server: intestazione con modpack e menu "Altro" (scarica,
// carica, verifica, apri cartella), il pannello "Gioca" secondo chi tiene il
// lock (libero, un altro, stale, io), come si entra (pacchetto per i
// giocatori, indirizzo), cosa c'è su questo PC con le sue impostazioni
// (cartella, Java, memoria, spegnimento) e il trasferimento in corso.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import '../state/space_state.dart';
import 'common.dart';
import 'dialogs.dart';

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key, required this.space});

  /// Id dello spazio.
  final String space;

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  @override
  void initState() {
    super.initState();
    _loadAfterFrame();
  }

  @override
  void didUpdateWidget(ServerScreen old) {
    super.didUpdateWidget(old);
    if (old.space != widget.space) _loadAfterFrame();
  }

  /// Le letture notificano subito: mai durante il build (anche le card della
  /// Home ascoltano lo stesso server).
  void _loadAfterFrame() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _load();
  });

  void _load() {
    final app = AppStateScope.read(context);
    final ss = app.spaceState(widget.space)..ensureLoaded();
    // impostazioni delle sessioni dell'hub (spegnimento automatico)
    unawaited(app.loadDetails(widget.space));
    if (app.space(widget.space)?.profile == Profile.minecraft && ss.linked) {
      unawaited(ss.ensureJava());
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final sp = app.space(widget.space);
    if (sp == null) return _Gone(id: widget.space);
    final ss = app.spaceState(sp.id);
    return ListenableBuilder(
      listenable: ss,
      builder: (context, _) {
        _maybeLoadHistory(app, sp, ss);
        final online = app.connection == Connection.online;
        final view = lockViewOf(sp, app.me);
        return ScreenBody(
          children: [
            ServerTabs(space: sp.id, current: ServerTab.overview),
            _Header(space: sp, state: ss, view: view),
            switch (view) {
              LockView.free => _FreePanel(space: sp, state: ss, online: online),
              LockView.play => _OtherPanel(space: sp),
              LockView.stale => _StalePanel(space: sp),
              LockView.mine => _MinePanel(space: sp),
            },
            if (view == LockView.stale && sp.head != null && sp.lock?.memberId != app.me?.id)
              _WorldWhere(space: sp),
            if (_visible(ss.outcome)) _Outcome(state: ss),
            if (ss.transfer != null) _TransferPanel(space: sp, state: ss),
            _PcPanel(space: sp, state: ss),
            // sotto, a tutta larghezza su una riga: non dipende dall'altezza
            // di «Sul tuo PC»
            _JoinPanel(space: sp, view: view),
          ],
        );
      },
    );
  }

  /// Rilegge la storia quando cambia la testa (dopo un salvataggio).
  void _maybeLoadHistory(AppState app, SpaceSummary sp, SpaceState ss) {
    final head = sp.head?.n;
    if (head == null || ss.historyLoading || ss.historyError != null) return;
    if (ss.history.isNotEmpty && ss.history.first.n == head) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ss.loadHistory());
    });
  }

  static bool _visible(SpaceOutcome? o) => switch (o) {
    null => false,
    PullDone(:final background) => !background,
    OpFailed(:final background, :final error) =>
      !background && !(error is SyncException && error.kind == SyncErrorKind.cancelled),
    _ => true,
  };
}

class _Gone extends StatelessWidget {
  const _Gone({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s;
    final t = s.common.errSpaceGone;
    return ScreenBody(
      children: [
        MsPanel(
          child: MsEmptyState(
            title: t[0].toUpperCase() + t.substring(1),
            art: const MsArt(MsArts.crackedBlock),
            error: true,
            action: MsButton(
              label: s.shell.home,
              icon: const MsIcon(MsIcons.home),
              onPressed: () => app.go(const HomeRoute()),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.space, required this.state, required this.view});
  final SpaceSummary space;
  final SpaceState state;
  final LockView view;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.server;
    final g = PixelScope.of(context);
    final l = state.layout;
    // la copia su questo PC se c'è, altrimenti quello che l'hub sa della HEAD
    final w = space.world;
    final loader = l?.loader ?? w?.loader?.name;
    final loaderVersion = l?.loader != null ? l?.loaderVersion : w?.loaderVersion;
    final mcVersion = l?.mcVersion ?? w?.mcVersion;
    final mods = l != null && state.scan.exists ? state.scan.mods : (w?.mods ?? 0);
    final canSync = state.linked && !state.busy && app.connection == Connection.online;
    return Row(
      children: [
        ServerTile(id: space.id, size: 64, iconUrl: serverIconUrl(app, space.id, space.head?.n)),
        SizedBox(width: g.d(20)),
        Expanded(
          child: MsStack(
            gap: 8,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsText.h2(space.name, maxLines: 1),
              MsRow(
                gap: 6,
                children: [
                  if (space.profile == Profile.generic) MsChip(s.genericFolder),
                  if (loader != null && loader != 'vanilla')
                    MsChip([s.loaderName(loader), ?loaderVersion].join(' ')),
                  if (mcVersion != null) MsChip(s.minecraft(mcVersion)),
                  if (mods > 0) MsChip(s.mods(mods), icon: const MsIcon(MsIcons.mods)),
                ],
              ),
            ],
          ),
        ),
        SizedBox(width: g.d(20)),
        MsMenuButton(
          label: s.more,
          items: [
            MsMenuItem(
              label: s.pull,
              icon: const MsIcon(MsIcons.download),
              onSelected: canSync ? state.pull : null,
            ),
            MsMenuItem(
              label: s.push,
              icon: const MsIcon(MsIcons.upload),
              onSelected: canSync && view == LockView.free ? state.push : null,
            ),
            MsMenuItem(
              label: s.verify,
              icon: const MsIcon(MsIcons.shield),
              onSelected: canSync ? state.verify : null,
            ),
            MsMenuItem(
              label: s.openFolder,
              icon: const MsIcon(MsIcons.folder),
              onSelected: state.folder != null ? state.openFolder : null,
            ),
          ],
        ),
      ],
    );
  }
}

/// Pannello in rilievo dello stato del server, compatto come una riga di
/// impostazione: a sinistra titolo e una riga di testo, a destra
/// un'informazione breve ([value]), il pulsante secondario e quello
/// principale, con lo stesso margine sopra, sotto e a destra. Tutti gli
/// stati hanno la stessa forma: cambiando stato il contenuto sotto non salta.
class _PlayFrame extends StatelessWidget {
  const _PlayFrame({
    required this.label,
    required this.title,
    required this.text,
    this.value,
    this.secondary,
    this.primary,
  });
  final String label;
  final Widget title;
  final String text;
  final String? value;
  final Widget? secondary;
  final Widget? primary;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final left = MsStack(
      gap: 4,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        MsText(text, tone: MsTextTone.secondary),
      ],
    );
    final right = MsRow(
      gap: 12,
      wrap: false,
      children: [
        if (value != null) MsText.small(value!, tone: MsTextTone.secondary, maxLines: 1),
        ?secondary,
        ?primary,
      ],
    );
    return MsPanel(
      raised: true,
      semanticLabel: label,
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < g.d(720)
            ? MsStack(
                gap: 12,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [left, right],
              )
            : Row(
                children: [
                  Expanded(child: left),
                  SizedBox(width: g.d(24)),
                  right,
                ],
              ),
      ),
    );
  }
}

class _FreePanel extends StatelessWidget {
  const _FreePanel({required this.space, required this.state, required this.online});
  final SpaceSummary space;
  final SpaceState state;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.server;
    final head = space.head;
    final pending = state.pending;
    // cosa succede premendo Gioca quando c'è da aspettare, altrimenti
    // l'ultimo salvataggio
    final value = !state.linked && head != null
        ? s.firstDownload(strings.fmt.size(head.stats.size))
        : pending != null
        ? s.toDownload(pending.files)
        : head != null
        ? '${s.lastSave}: ${s.lastSaveValue(head.author, strings.fmt.ago(app.localTime(head.ts), app.now()))}'
        : null;
    return _PlayFrame(
      label: s.play,
      title: MsRow(gap: 12, children: [MsText.h3(s.freeTitle), lockBadge(context, space)]),
      text: s.freeText(space.name),
      value: value,
      primary: MsButton(
        label: s.play,
        variant: MsButtonVariant.primary,
        size: MsButtonSize.lg,
        icon: const MsIcon(MsIcons.play),
        onPressed: online ? () => startPlay(app, state.id) : null,
      ),
    );
  }
}

class _OtherPanel extends StatelessWidget {
  const _OtherPanel({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.server;
    final l = space.lock!;
    final since = strings.fmt.duration(app.now().difference(app.localTime(l.since)));
    final notify = app.notifyWhenFree(space.id);
    // l'indirizzo per entrare sta in «Per entrare»
    return _PlayFrame(
      label: s.playingTitle(l.name),
      title: MsRow(gap: 12, children: [MsAvatar(l.name), MsText.h3(s.playingTitle(l.name))]),
      text: s.playingText(since, l.info.players.length),
      secondary: (app.me?.admin ?? false)
          ? MsButton(
              label: s.forceAdmin,
              variant: MsButtonVariant.ghost,
              icon: const MsIcon(MsIcons.unlock),
              onPressed: () => showForceDialog(context, space.id),
            )
          : null,
      primary: MsButton(
        label: notify ? s.notifyOn : s.notifyMe,
        size: MsButtonSize.lg,
        variant: notify ? MsButtonVariant.secondary : MsButtonVariant.primary,
        icon: MsIcon(notify ? MsIcons.check : MsIcons.bell),
        onPressed: () => app.setNotifyWhenFree(space.id, !notify),
      ),
    );
  }
}

class _StalePanel extends StatelessWidget {
  const _StalePanel({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.server;
    final f = strings.fmt;
    final l = space.lock!;
    final now = app.now();
    final beat = app.localTime(l.lastBeat);
    // la sessione rimasta appesa è la propria (MineSync chiuso mentre si
    // ospitava): si riprende senza le conferme del forzare un altro
    if (app.me != null && l.memberId == app.me!.id) {
      return _PlayFrame(
        label: s.staleMineTitle,
        title: MsText.h3(s.staleMineTitle),
        text: s.staleMineText,
        value: s.lastSignal(f.ago(beat, now)),
        // giallo: riprende una sessione interrotta, non è un Gioca normale
        primary: MsButton(
          label: s.resume,
          variant: MsButtonVariant.warn,
          size: MsButtonSize.lg,
          icon: const MsIcon(MsIcons.play),
          onPressed: app.connection == Connection.online
              ? () => startPlay(app, space.id, force: true)
              : null,
        ),
      );
    }
    // cosa è al sicuro e cosa no sta nel pannello «Dove si trova il mondo»
    return _PlayFrame(
      label: s.staleTitle(l.name),
      title: MsText.h3(s.staleTitle(l.name)),
      text: s.staleText(f.clock(beat), f.ago(beat, now)),
      secondary: MsButton(
        label: s.wait(l.name),
        variant: MsButtonVariant.ghost,
        icon: const MsIcon(MsIcons.clock),
        onPressed: () async {
          await app.setNotifyWhenFree(space.id, true);
          if (context.mounted) toast(context, s.willNotify, tone: MsToastTone.info);
        },
      ),
      primary: MsButton(
        label: s.forcePlay,
        variant: MsButtonVariant.danger,
        size: MsButtonSize.lg,
        icon: const MsIcon(MsIcons.unlock),
        onPressed: app.connection == Connection.online
            ? () => showForceDialog(context, space.id)
            : null,
      ),
    );
  }
}

/// Sotto il pannello di un server che non risponde: cosa c'è sull'hub e cosa
/// forse solo sul PC di chi ospitava.
class _WorldWhere extends StatelessWidget {
  const _WorldWhere({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.server;
    final f = strings.fmt;
    final l = space.lock!;
    final head = space.head!;
    return MsPanel(
      title: s.worldWhere,
      child: MsStack(
        gap: 8,
        children: [
          MsFacts([
            MsFact(s.safeOnHub, s.safeValue(head.n, head.author, f.clock(app.localTime(head.ts)))),
            MsFact(s.maybeOnly(l.name), s.maybeValue(f.clock(app.localTime(head.ts)))),
          ]),
          MsText.small(s.staleAdvice(l.name, head.n), tone: MsTextTone.secondary),
        ],
      ),
    );
  }
}

class _MinePanel extends StatelessWidget {
  const _MinePanel({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final s = context.s.server;
    return _PlayFrame(label: s.mineTitle, title: MsText.h3(s.mineTitle), text: s.mineText);
  }
}

/// Esito dell'ultima operazione, finché non lo si chiude.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.state});
  final SpaceState state;

  @override
  Widget build(BuildContext context) {
    final strings = context.s;
    final s = strings.server;
    final close = MsButton(
      label: s.close,
      variant: MsButtonVariant.ghost,
      size: MsButtonSize.sm,
      onPressed: state.clearOutcome,
    );
    final o = state.outcome!;
    return switch (o) {
      PullDone(:final result) => MsAlert(
        tone: MsAlertTone.ok,
        title: s.pulledTitle(result.n),
        text: [
          s.pulledText(result.written, result.deleted),
          if (result.backup != null) s.backupText(result.backup!),
        ].join(' '),
        actions: [close],
      ),
      PushDone(:final result) => MsAlert(
        tone: MsAlertTone.ok,
        title: result.generation == null ? s.nothingToPush : s.pushedTitle(result.generation!.n),
        text: result.kept.isEmpty ? null : s.keptText(result.kept.length, result.kept.first),
        actions: [close],
      ),
      VerifyDone(:final files, :final diff) =>
        diff.isEmpty
            ? MsAlert(
                tone: MsAlertTone.ok,
                title: s.verifyOkTitle,
                text: s.verifyOkText(files),
                actions: [close],
              )
            : MsAlert(
                tone: MsAlertTone.warn,
                title: s.verifyDiffTitle,
                text: s.verifyDiffText(diff.changed.length, diff.removed.length, diff.added.length),
                actions: [close],
              ),
      OpFailed(:final error)
          when error is SyncException && error.kind == SyncErrorKind.dirtyLocal =>
        MsAlert(
          tone: MsAlertTone.warn,
          title: s.dirtyTitle,
          text: s.dirtyText(
            diverged: error.diverged,
            changed: error.changed.length,
            removed: error.removed.length,
          ),
          actions: [
            close,
            if (error.diverged)
              MsButton(
                label: s.downloadAnyway,
                size: MsButtonSize.sm,
                onPressed: () => state.pull(discardLocal: true),
              )
            else
              MsButton(
                label: s.uploadMine,
                variant: MsButtonVariant.primary,
                size: MsButtonSize.sm,
                onPressed: state.push,
              ),
          ],
        ),
      OpFailed(:final op, :final error) => MsAlert(
        tone: MsAlertTone.err,
        title: s.failedTitle(SyncOpName.values[op.index]),
        text: errorText(strings, error),
        actions: [close],
      ),
    };
  }
}

/// Riga di una versione: numero, titolo, autore e quando, conteggi.
class GenerationRow extends StatelessWidget {
  const GenerationRow({
    super.key,
    required this.gen,
    required this.isHead,
    this.meta,
    this.selected = false,
    this.onTap,
  });

  final GenerationSummary gen;
  final bool isHead;
  final String? meta;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.server;
    final st = gen.stats;
    return MsListRow(
      // il titolo va a capo invece di ridursi a poche lettere accanto a «Attuale»
      titleMaxLines: 2,
      selected: selected,
      onTap: onTap,
      // colonna fissa: i quadrati restano allineati anche con #10 e oltre
      lead: SizedBox(
        width: PixelScope.of(context).d(48),
        child: Align(alignment: Alignment.centerLeft, child: MsLevel('#${gen.n}')),
      ),
      title: s.genTitle(
        kind: gen.kind.name,
        author: gen.author,
        message: gen.message,
        restoredFrom: gen.restoredFrom,
      ),
      // il conteggio dei file sta tra i dati: a destra resta solo «Attuale»,
      // il titolo ha lo spazio che serve
      meta: listMeta([
        meta ?? listMeta([gen.author, strings.fmt.ago(app.localTime(gen.ts), app.now())]),
        s.statsLabel(st.added, st.changed, st.removed),
      ]),
      trail: isHead ? MsPill(s.head, tone: MsStatusTone.ok) : null,
    );
  }
}

/// Come si entra: il pacchetto per i giocatori (le mod lato giocatore e la
/// versione giusta) e l'indirizzo fisso, se l'hub ha il DNS.
class _JoinPanel extends StatelessWidget {
  const _JoinPanel({required this.space, required this.view});
  final SpaceSummary space;
  final LockView view;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.server;
    final w = space.world;
    final loader = w?.loader?.name;
    final modded = loader != null && loader != 'vanilla';
    final addrs = joinAddresses(space);
    // l'indirizzo fisso c'è sempre; mentre qualcuno gioca, senza DNS, si
    // mostra l'IP diretto di chi ospita
    final address = addrs.fixed ?? (view == LockView.play ? addrs.direct : null);
    return MsPanel(
      title: s.joinTitle,
      child: MsStack(
        gap: 14,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final g = PixelScope.of(context);
              final text = MsText(
                s.joinNeeds([
                  if (w?.mcVersion != null) s.minecraft(w!.mcVersion!),
                  if (modded) [s.loaderName(loader), ?w?.loaderVersion].join(' '),
                ], modded),
              );
              final pack = modded && space.profile == Profile.minecraft
                  ? MsButton(
                      label: s.joinPack,
                      size: MsButtonSize.sm,
                      icon: const MsIcon(MsIcons.players),
                      onPressed: () => app.go(ModpackRoute(space.id, client: true)),
                    )
                  : null;
              if (pack == null) return text;
              // stretto (accanto a «Sul tuo PC»): il pulsante va sotto la frase
              if (box.maxWidth < g.d(460)) {
                return MsStack(
                  gap: 10,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [text, pack],
                );
              }
              return Row(
                children: [
                  Expanded(child: text),
                  SizedBox(width: g.d(16)),
                  pack,
                ],
              );
            },
          ),
          if (address != null)
            MsFacts([
              MsFact(
                s.address,
                '',
                child: MsRow(
                  gap: 8,
                  children: [
                    MsText.mono(address, weight: 700),
                    MsButton.icon(
                      icon: const MsIcon(MsIcons.copy),
                      size: MsButtonSize.sm,
                      semanticLabel: s.copyAddressLabel(address),
                      onPressed: () => copyText(context, address, s.copied),
                    ),
                  ],
                ),
              ),
            ]),
          if (view == LockView.play && addrs.fixed != null && addrs.direct != null)
            MsText.rich(
              [MsSpan('${s.fixedNote} '), MsSpan(addrs.direct!, strong: true), const MsSpan('.')],
              kind: MsTextKind.small,
              tone: MsTextTone.secondary,
            ),
        ],
      ),
    );
  }
}

/// Questo server su questo PC: copia locale, cartella, Java, memoria e
/// spegnimento automatico (preferenze di questo PC).
class _PcPanel extends StatelessWidget {
  const _PcPanel({required this.space, required this.state});
  final SpaceSummary space;
  final SpaceState state;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.server;
    final t = strings.settings;
    final ss = state;
    final id = space.id;
    final mc = space.profile == Profile.minecraft;
    final head = space.headN;
    final base = ss.baseN;
    final pending = ss.pending;
    final java = ss.java;
    final prefs = ServerPrefs.fromPrefs(app.config.prefs, id);
    // senza una scelta su questo PC vale quella dell'hub per il server
    // (letta da _load, mai durante il build)
    final hub = app.sessionSettings(id);
    final xmxGb = ((prefs.xmxMiB ?? 6144) / 1024).round().clamp(2, 16);
    final pill = !ss.linked
        ? null
        : pending != null
        ? MsPill(s.toDownload(pending.files), tone: MsStatusTone.warn)
        : ss.upToDate
        ? MsPill(s.upToDate, tone: MsStatusTone.ok)
        : null;
    final l = ss.layout;
    Widget change(String label, VoidCallback on) => MsButton(
      label: s.change,
      size: MsButtonSize.sm,
      semanticLabel: '${s.change} $label',
      onPressed: on,
    );
    return MsPanel(
      title: s.onPc,
      actions: [?pill],
      child: MsStack(
        gap: 12,
        children: [
          // righe come nelle impostazioni: icona, titolo con valore e
          // spiegazione sotto, controllo a destra
          MsSettingList(
            children: [
              MsSettingRow(
                icon: const MsIcon(MsIcons.folder),
                title: s.folder,
                description: ss.linked
                    ? (base == null && head == 0
                          ? s.copyNever
                          : (base ?? 0) < head
                          ? s.copyBehind(base ?? 0, head)
                          : null)
                    : s.folderLater,
                value: MsText.mono(
                  app.displayPath(ss.folder ?? ss.suggestedFolder),
                  weight: 500,
                  maxLines: 1,
                ),
                control: change(s.folder, () => showServerSettingsDialog(context, ss)),
              ),
              if (mc) ...[
                MsSettingRow(
                  icon: const MsIcon(MsIcons.java),
                  title: s.java,
                  description: prefs.javaPath == null ? t.javaAuto : null,
                  value: MsText(
                    java == null
                        ? (ss.javaLoading || ss.javas == null ? s.javaSearching : s.javaNone)
                        : s.javaOption(java.major),
                    maxLines: 1,
                  ),
                  control: change(s.java, () => showJavaDialog(context, ss)),
                ),
                // una riga sola: l'interruttore accende la barra accanto (che
                // resta visibile, spenta, al suo valore)
                MsSettingRow(
                  icon: const MsIcon(MsIcons.chart),
                  title: t.memoryMax,
                  description: t.memoryHint,
                  value: MsText(t.gb(xmxGb), tabular: true, maxLines: 1),
                  control: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: PixelScope.of(context).d(220),
                        child: MsSlider(
                          value: xmxGb.toDouble(),
                          min: 2,
                          max: 16,
                          step: 1,
                          semanticLabel: t.memoryMax,
                          semanticFormatter: (v) => t.gb(v.round()),
                          onChanged: prefs.xmxMiB == null
                              ? null
                              : (v) => app.setServerPref(id, 'xmx', v.round() * 1024),
                        ),
                      ),
                      SizedBox(width: PixelScope.of(context).d(16)),
                      MsSwitch(
                        value: prefs.xmxMiB != null,
                        semanticLabel: t.memorySet,
                        onChanged: (v) => app.setServerPref(id, 'xmx', v ? xmxGb * 1024 : null),
                      ),
                    ],
                  ),
                ),
                MsSettingRow(
                  icon: const MsIcon(MsIcons.stop),
                  title: t.autostop,
                  description: t.autostopHint(hub.autostopMinutes),
                  control: MsSwitch(
                    value: prefs.autostop ?? hub.autostop,
                    semanticLabel: t.autostop,
                    onChanged: (v) => app.setServerPref(id, 'autostop', v),
                  ),
                ),
              ],
            ],
          ),
          if (mc && l != null && !l.empty && l.launch == null)
            MsAlert(tone: MsAlertTone.warn, title: s.launchMissing),
          if (mc && ss.javaTooOld)
            MsAlert(
              tone: MsAlertTone.warn,
              title: s.javaOldTitle(java!.major),
              text: s.javaOldText(ss.requiredJava, ss.betterJava?.major),
              actions: [
                if (ss.betterJava != null)
                  MsButton(
                    label: s.useJava(ss.betterJava!.major),
                    size: MsButtonSize.sm,
                    onPressed: () => ss.useJava(ss.betterJava),
                  ),
              ],
            )
          else if (mc && ss.javas != null && java == null && ss.requiredJava > 0)
            MsAlert(
              tone: MsAlertTone.warn,
              title: s.javaNoneTitle(ss.requiredJava),
              text: s.javaNoneText(ss.requiredJava),
            ),
        ],
      ),
    );
  }
}

class _TransferPanel extends StatelessWidget {
  const _TransferPanel({required this.space, required this.state});
  final SpaceSummary space;
  final SpaceState state;

  @override
  Widget build(BuildContext context) {
    final strings = context.s;
    final s = strings.server;
    final f = strings.fmt;
    final t = state.transfer!;
    final op = SyncOpName.values[t.op.index];
    final frac = t.fraction;
    final eta = t.eta;
    return MsPanel(
      title: s.transfer,
      actions: [
        if (t.background) MsText.small(s.inBackground, tone: MsTextTone.secondary),
        MsButton(
          label: s.cancel,
          variant: MsButtonVariant.ghost,
          size: MsButtonSize.sm,
          onPressed: state.cancel,
        ),
      ],
      child: MsStack(
        gap: 12,
        children: [
          MsProgressMeta(
            start: RichLine([
              (s.transferTitle(t.phase, op, t.target), true),
              if (t.totalFiles > 0) (' (${s.filesOf(t.files, t.totalFiles)})', false),
            ], kind: MsTextKind.small),
            end: frac == null ? null : MsText.small(f.percent(frac), weight: 700, tabular: true),
          ),
          if (frac == null)
            MsProgress.indeterminate(semanticLabel: s.transferLabel(space.name))
          else
            MsProgress(value: frac, semanticLabel: s.transferLabel(space.name)),
          if (t.total > 0)
            MsProgressMeta(
              start: MsText.small(
                s.bytesOf(
                  f.size(t.done),
                  f.size(t.total),
                  t.bytesPerSecond == null ? null : f.speed(t.bytesPerSecond!),
                ),
                tabular: true,
              ),
              end: eta == null ? null : MsText.small(s.eta(f.duration(eta)), tabular: true),
            ),
        ],
      ),
    );
  }
}
