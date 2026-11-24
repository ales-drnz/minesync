// Scheda Mod di un server: «Mod del server» (installate, aggiornamenti,
// ricerca su Modrinth, cambio di versione o loader, modifiche da applicare)
// e «Pacchetto per i giocatori». Le modifiche si accumulano nella barra in
// basso: sull'hub non va niente finché non si preme Applica. Mentre qualcuno
// gioca si cerca e si preparano le modifiche, ma non si applica.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_minecraft/ms_minecraft.dart' show pickJava, requiredJava;
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'client_pack.dart';
import 'common.dart';
import 'modpack_dialogs.dart';
import 'pack_browser.dart' show PackIcon;

class ModpackScreen extends StatefulWidget {
  const ModpackScreen({super.key, required this.space, this.client = false});

  final String space;

  /// Apre il pacchetto per i giocatori.
  final bool client;

  @override
  State<ModpackScreen> createState() => _ModpackScreenState();
}

class _ModpackScreenState extends State<ModpackScreen> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ModpackScreen old) {
    super.didUpdateWidget(old);
    if (old.space != widget.space) _load();
  }

  void _load() {
    final app = AppStateScope.read(context);
    final ss = app.spaceState(widget.space)..ensureLoaded();
    final mp = app.modpack(widget.space);
    if (mp.phase == PackPhase.idle) {
      unawaited(() async {
        if (!ss.loaded) await ss.refresh();
        await mp.load();
        if (mp.phase == PackPhase.ready && mp.updatesAt == null) await mp.checkUpdates();
      }());
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final sp = app.space(widget.space);
    if (sp == null) return const SizedBox.shrink();
    final mp = app.modpack(sp.id);
    return ListenableBuilder(
      listenable: Listenable.merge([mp, app.spaceState(sp.id)]),
      builder: (context, _) {
        final g = PixelScope.of(context);
        final bar =
            !widget.client &&
            mp.phase == PackPhase.ready &&
            (mp.dirty || mp.applyState is! ApplyIdle);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ScreenBody(
                children: [
                  ServerTabs(space: sp.id, current: ServerTab.mods),
                  _Header(space: sp, mp: mp, client: widget.client),
                  if (widget.client)
                    ClientPackView(space: sp, mp: mp)
                  else
                    ..._serverView(context, sp, mp),
                ],
              ),
            ),
            // la barra delle modifiche resta sempre in basso, fuori dallo scorrimento
            if (bar)
              Padding(
                padding: EdgeInsets.fromLTRB(g.d(24), g.d(8), g.d(24), g.d(16)),
                child: PendingBar(space: sp, mp: mp),
              ),
          ],
        );
      },
    );
  }

  List<Widget> _serverView(BuildContext context, SpaceSummary sp, ModpackController mp) {
    final s = context.s.modpack;
    switch (mp.phase) {
      case PackPhase.noFolder:
        return [NoFolderAlert(space: sp, mp: mp)];
      case PackPhase.idle || PackPhase.loading:
        return [
          MsPanel(child: MsRow(children: [const MsSpinner(), MsText(s.loading)])),
        ];
      case PackPhase.recognizing:
        return [
          MsPanel(
            child: MsStack(
              gap: 8,
              children: [
                MsRow(children: [const MsSpinner(), MsText(s.recognizing)]),
                MsText.small(s.recognizingText, tone: MsTextTone.secondary),
              ],
            ),
          ),
        ];
      case PackPhase.noVersion:
        return [MsAlert(title: s.noVersion, text: s.noVersionText, tone: MsAlertTone.warn)];
      case PackPhase.error:
        return [
          if (mp.modrinthDown)
            _ModrinthDown(mp: mp)
          else
            MsAlert(
              title: s.loadError,
              text: '${mp.loadError ?? ''}',
              tone: MsAlertTone.err,
              actions: [MsButton(label: s.retry, onPressed: () => mp.load(force: true))],
            ),
        ];
      case PackPhase.ready:
        break;
    }
    return [
      // durante la propria applicazione il lock è di chi applica: niente
      // «X sta giocando» a sé stessi
      if (mp.locked && !mp.applying) _LockedAlert(space: sp, mp: mp),
      if (mp.modrinthDown) _ModrinthDown(mp: mp),
      if (mp.watchReady && mp.watch != null)
        MsAlert(title: s.watchReady(mp.watch!.split('|').first), tone: MsAlertTone.ok),
      if (_retarget)
        RetargetPanel(mp: mp, space: sp, onClose: () => setState(() => _retarget = false))
      else
        Columns(
          minWidth: 300,
          equal: false,
          children: [
            (
              3,
              MsStack(
                gap: 24,
                children: [
                  if (mp.draft?.loader == Loader.vanilla && (mp.draft?.mods.isEmpty ?? true))
                    MsAlert(title: s.vanillaTitle, text: s.vanillaText, tone: MsAlertTone.info)
                  else ...[
                    _UpdatesPanel(mp: mp),
                    _InstalledPanel(mp: mp),
                  ],
                ],
              ),
            ),
            // il dettaglio di una mod è un dialogo: a destra resta solo la ricerca
            (
              2,
              mp.draft?.loader != Loader.vanilla
                  ? SearchPanel(mp: mp, space: sp)
                  : const SizedBox.shrink(),
            ),
          ],
        ),
    ];
  }

  var _retarget = false;

  /// Apre il pannello «Cambia versione o loader» (dal pulsante in testa).
  void openRetarget() => setState(() => _retarget = true);
}

// --- intestazione ---------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.space, required this.mp, required this.client});
  final SpaceSummary space;
  final ModpackController mp;
  final bool client;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final app = AppStateScope.of(context);
    final p = mp.draft ?? mp.base;
    final w = space.world;
    final mc = p?.mcVersion ?? w?.mcVersion;
    final loader = p?.loader ?? w?.loader;
    final lv = p?.loaderVersion ?? w?.loaderVersion;
    final ready = mp.phase == PackPhase.ready;
    final view = MsSegmented<bool>(
      semanticLabel: s.viewLabel,
      value: client,
      segments: [
        MsSegment(value: false, label: s.viewServer, icon: const MsIcon(MsIcons.server)),
        MsSegment(value: true, label: s.viewClient, icon: const MsIcon(MsIcons.players)),
      ],
      onChanged: (v) => app.go(ModpackRoute(space.id, client: v)),
    );
    // versione, loader e (per i giocatori) il numero di mod come etichette
    // piatte; senza pacchetto la riga non c'è
    final parts = client && mp.packIsNew
        ? const <String>[]
        : [
            if (mc != null) context.s.server.minecraft(mc),
            if (loader != null && loader != Loader.vanilla)
              [loaderLabel(context, loader), ?lv].join(' '),
            if (client)
              s.forPlayersCount(p?.mods.where((m) => !m.disabled && m.side.onClient).length ?? 0),
          ];
    final info = parts.isEmpty ? null : MsMeta(parts);
    final change = !client && ready
        ? MsButton(
            label: s.retarget,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.refresh),
            onPressed: () => context.findAncestorStateOfType<_ModpackScreenState>()?.openRetarget(),
          )
        : null;
    // la vista con sotto versione e loader; «Cambia…» a destra, o sotto a
    // tutto se la finestra è stretta
    final left = MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [view, ?info],
    );
    return LayoutBuilder(
      builder: (context, box) => change == null
          ? left
          : box.maxWidth < PixelScope.of(context).d(640)
          ? MsStack(gap: 12, crossAxisAlignment: CrossAxisAlignment.start, children: [left, change])
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Align(alignment: Alignment.topLeft, child: left),
                ),
                SizedBox(width: PixelScope.of(context).d(16)),
                change,
              ],
            ),
    );
  }
}

/// Il server non è su questo PC: un solo avviso con «Scarica il server».
class NoFolderAlert extends StatelessWidget {
  const NoFolderAlert({super.key, required this.space, required this.mp});
  final SpaceSummary space;
  final ModpackController mp;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final app = AppStateScope.of(context);
    return MsAlert(
      title: s.noFolder,
      tone: MsAlertTone.info,
      actions: [
        MsButton(
          label: s.getServer,
          variant: MsButtonVariant.primary,
          icon: const MsIcon(MsIcons.download),
          onPressed: () async {
            final ss = app.spaceState(space.id);
            await ss.linkTo(ss.suggestedFolder);
            await ss.pull();
            await mp.load(force: true);
          },
        ),
      ],
    );
  }
}

class _LockedAlert extends StatelessWidget {
  const _LockedAlert({required this.space, required this.mp});
  final SpaceSummary space;
  final ModpackController mp;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final app = AppStateScope.of(context);
    final on = app.notifyWhenFree(space.id);
    return MsAlert(
      title: s.lockedTitle(mp.holder ?? ''),
      text: s.lockedText,
      icon: const MsIcon(MsIcons.lock),
      tone: MsAlertTone.warn,
      actions: [
        MsButton(
          label: on ? s.notifyFreeOn : s.notifyFree,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.bell),
          onPressed: on ? null : () => app.setNotifyWhenFree(space.id, true),
        ),
      ],
    );
  }
}

class _ModrinthDown extends StatelessWidget {
  const _ModrinthDown({required this.mp});
  final ModpackController mp;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final at = mp.lastAttempt;
    return MsAlert(
      title: s.modrinthDown,
      text: [
        s.modrinthDownText,
        if (at != null) s.modrinthNext(context.s.fmt.clock(at), mp.env.retryEvery.inSeconds),
      ].join(' '),
      tone: MsAlertTone.warn,
      actions: [
        MsButton(
          label: s.retry,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.refresh),
          onPressed: mp.retryModrinth,
        ),
      ],
    );
  }
}

// --- aggiornamenti ---------------------------------------------------------------------

/// Aggiornamenti mostrati prima di "Mostra tutti": il pannello non deve
/// spingere giù l'elenco delle mod.
const _updatesShort = 3;

class _UpdatesPanel extends StatefulWidget {
  const _UpdatesPanel({required this.mp});
  final ModpackController mp;

  @override
  State<_UpdatesPanel> createState() => _UpdatesPanelState();
}

class _UpdatesPanelState extends State<_UpdatesPanel> {
  bool _all = false;

  ModpackController get mp => widget.mp;

  String _name(String projectId) => mp.draft?.byProject(projectId)?.name ?? projectId;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final app = AppStateScope.of(context);
    final all = mp.pendingUpdates;
    final list = _all ? all : all.take(_updatesShort).toList();
    final available = all.where(
      (u) => u.status == UpdateStatus.available && !mp.updateQueued(u.mod.key),
    );
    final at = mp.updatesAt;
    return MsPanel(
      title: s.updates,
      actions: [
        if (at != null)
          MsText.small(s.checkedAgo(context.s.fmt.ago(at, app.now())), tone: MsTextTone.secondary),
        if (available.isNotEmpty)
          MsButton(
            label: s.updateAll(available.length),
            size: MsButtonSize.sm,
            onPressed: mp.updateAll,
          )
        // durante il controllo lo dice solo il corpo del pannello
        else if (!mp.updatesLoading)
          MsButton(
            label: s.checkUpdates,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.refresh),
            onPressed: mp.modrinthDown ? null : mp.checkUpdates,
          ),
      ],
      child: list.isEmpty
          ? mp.updatesLoading
                ? MsRow(
                    children: [
                      const MsSpinner(),
                      MsText.small(s.checking, tone: MsTextTone.secondary),
                    ],
                  )
                : MsText.small(at == null ? s.notChecked : s.noUpdates, tone: MsTextTone.secondary)
          : MsStack(
              gap: 8,
              children: [
                MsList(
                  children: [
                    for (final u in list)
                      MsListRow(
                        // il nome, sotto le versioni; per quelli bloccati anche il motivo
                        title: modName(u.mod),
                        meta: listMeta([
                          s.fromTo(modVersion(u.mod), u.latest?.versionNumber ?? '?'),
                          if (u.status == UpdateStatus.blocked && u.blockers.isNotEmpty)
                            blockerText(s, u.blockers.first, _name),
                        ]),
                        lead: PackIcon(
                          url: mp.iconUrlOf(u.mod.projectId),
                          seed: u.mod.projectId ?? u.mod.key,
                          size: 32,
                        ),
                        trail: u.status == UpdateStatus.blocked
                            ? MsButton(
                                label: s.why,
                                size: MsButtonSize.sm,
                                variant: MsButtonVariant.ghost,
                                onPressed: () async {
                                  final c = await showBlockedUpdateDialog(context, u, name: _name);
                                  if (c == BlockedUpdateChoice.hide) mp.setPinned(u.mod.key, true);
                                },
                              )
                            : mp.updateQueued(u.mod.key)
                            ? MsChip(s.inChanges, tone: MsChipTone.accent)
                            : MsButton(
                                label: s.update,
                                size: MsButtonSize.sm,
                                onPressed: () => mp.update(u.mod.key),
                              ),
                      ),
                  ],
                ),
                if (all.length > _updatesShort)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MsButton(
                      label: _all ? s.showFewer : s.showAll(all.length),
                      size: MsButtonSize.sm,
                      variant: MsButtonVariant.ghost,
                      onPressed: () => setState(() => _all = !_all),
                    ),
                  ),
              ],
            ),
    );
  }
}

// --- installate -----------------------------------------------------------------------

/// Filtri dell'elenco: tutte, le due eccezioni di lato (solo server, solo
/// giocatori) e le disattivate. Il lato resta anche nel segnale delle righe.
enum ModFilter { all, server, client, disabled }

class _InstalledPanel extends StatefulWidget {
  const _InstalledPanel({required this.mp});
  final ModpackController mp;

  @override
  State<_InstalledPanel> createState() => _InstalledPanelState();
}

class _InstalledPanelState extends State<_InstalledPanel> {
  final _q = TextEditingController();
  var _filter = ModFilter.all;

  @override
  void initState() {
    super.initState();
    _q.addListener(() => setState(() {}));
    // le icone si leggono dopo il primo frame, mai durante il build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.mp.loadIcons());
    });
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  bool _keep(PackMod m) => switch (_filter) {
    ModFilter.all => true,
    ModFilter.server => m.side == PackSide.server,
    ModFilter.client => m.side == PackSide.client,
    ModFilter.disabled => m.disabled,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final mp = widget.mp;
    final d = mp.draft!;
    final removed = mp.changes?.removed ?? const <PackMod>[];
    final q = _q.text.trim().toLowerCase();
    final mods = [
      for (final m in d.mods)
        if (_keep(m) &&
            (q.isEmpty || modName(m).toLowerCase().contains(q) || m.file.toLowerCase().contains(q)))
          m,
    ]..sort((a, b) => modName(a).toLowerCase().compareTo(modName(b).toLowerCase()));
    int count(ModFilter f) {
      final keep = _filter;
      _filter = f;
      final n = d.mods.where(_keep).length;
      _filter = keep;
      return n;
    }

    final size = d.mods.fold(0, (a, m) => a + m.size);
    final requiredBy = <String, int>{};
    for (final m in d.mods) {
      for (final r in m.requires) {
        requiredBy[r] = (requiredBy[r] ?? 0) + 1;
      }
    }
    final locked = mp.locked;
    // prima volta: si avvisa solo se qualche mod non è stata trovata su Modrinth
    final manualKept =
        mp.packIsNew && (mp.base?.mods.any((m) => m.source == PackSource.manual) ?? false);
    return MsPanel(
      title: s.installed,
      actions: [
        MsMeta([s.installedCount(d.mods.length), context.s.fmt.size(size)]),
      ],
      foot: [MsText.small(locked ? s.readOnlyHint : s.installedFoot, tone: MsTextTone.secondary)],
      child: MsStack(
        gap: 12,
        children: [
          MsTextInput(controller: _q, placeholder: s.findInstalled, semanticLabel: s.findInstalled),
          MsScrollX(
            child: MsSegmented<ModFilter>(
              semanticLabel: s.filterLabel,
              value: _filter,
              segments: [
                MsSegment(value: ModFilter.all, label: '${s.filterAll} ${count(ModFilter.all)}'),
                MsSegment(
                  value: ModFilter.server,
                  label: '${s.filterServer} ${count(ModFilter.server)}',
                  icon: const MsIcon(MsIcons.server),
                ),
                MsSegment(
                  value: ModFilter.client,
                  label: '${s.filterClient} ${count(ModFilter.client)}',
                  icon: const MsIcon(MsIcons.user),
                ),
                MsSegment(
                  value: ModFilter.disabled,
                  label: '${s.filterDisabled} ${count(ModFilter.disabled)}',
                ),
              ],
              onChanged: (f) => setState(() => _filter = f),
            ),
          ),
          if (manualKept) MsText.small(s.manualKept, tone: MsTextTone.secondary),
          if (mods.isEmpty && removed.isEmpty)
            MsText.small(d.mods.isEmpty ? s.noMods : s.noMatch, tone: MsTextTone.secondary)
          else
            MsList(
              children: [
                for (final m in mods)
                  _ModRow(
                    mod: m,
                    mp: mp,
                    requiredBy: m.projectId == null ? 0 : (requiredBy[m.projectId!] ?? 0),
                    locked: locked,
                  ),
                for (final m in removed)
                  MsListRow(
                    title: modName(m),
                    meta: s.lineRemoved(modName(m)),
                    trail: MsChip(s.inChanges, tone: MsChipTone.accent),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ModRow extends StatelessWidget {
  const _ModRow({
    required this.mod,
    required this.mp,
    required this.requiredBy,
    required this.locked,
  });

  final PackMod mod;
  final ModpackController mp;
  final int requiredBy;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final before = mp.before(mod.key);
    final isNew = before == null && !mp.packIsNew;
    final upd = mp.pendingUpdates
        .where((u) => u.mod.key == mod.key && u.status == UpdateStatus.available)
        .firstOrNull;
    final queuedUpdate = before != null && before.versionId != mod.versionId;
    final queuedToggle = before != null && before.disabled != mod.disabled;
    final status = <String>[
      if (isNew) s.chipNew,
      if (mod.source == PackSource.manual) s.chipManual,
      if (queuedUpdate) s.toUpdate(modVersion(mod)),
      if (upd != null && !queuedUpdate) s.available(upd.latest?.versionNumber ?? ''),
      if (mod.disabled) s.chipDisabled,
      if (queuedToggle || queuedUpdate) s.inChanges,
    ];
    // nella riga solo quello che serve a colpo d'occhio: versione, file e
    // hash stanno nel dettaglio (la riga stessa o il pulsante "i")
    final meta = listMeta([
      ...status,
      if (mod.source == PackSource.manual)
        s.manualNote
      else if (requiredBy > 0 && mod.auto)
        s.requiredBy(requiredBy),
    ]);
    void open() => unawaited(showModDetailDialog(context, mp, mod.key));
    return MsListRow(
      lead: PackIcon(url: mp.iconUrlOf(mod.projectId), seed: mod.projectId ?? mod.key, size: 32),
      title: modName(mod),
      meta: meta.isEmpty ? null : meta,
      onTap: open,
      trail: MsRow(
        gap: 8,
        wrap: false,
        children: [
          sideMarker(context, mod.side),
          MsButton.icon(
            icon: const MsIcon(MsIcons.info),
            semanticLabel: '${s.detail}: ${modName(mod)}',
            size: MsButtonSize.sm,
            variant: MsButtonVariant.ghost,
            onPressed: open,
          ),
          MsSwitch(
            value: !mod.disabled,
            semanticLabel: '${s.toggleLabel}: ${modName(mod)}',
            onChanged: locked ? null : (_) => mp.toggle(mod.key),
          ),
          MsButton.icon(
            icon: const MsIcon(MsIcons.trash),
            semanticLabel: '${s.removeLabel}: ${modName(mod)}',
            size: MsButtonSize.sm,
            variant: MsButtonVariant.ghost,
            onPressed: locked ? null : () => removeMod(context, mp, mod.key),
          ),
        ],
      ),
    );
  }
}

/// Rimozione con il dialogo delle dipendenti.
Future<void> removeMod(BuildContext context, ModpackController mp, String key) async {
  final plan = mp.planRemoval(key);
  if (plan == null) return;
  if (await showRemoveDialog(context, plan)) mp.remove(plan);
}

// --- dettaglio --------------------------------------------------------------------------

/// Dettaglio di una mod in un dialogo a parte (dalla riga o dal pulsante
/// "i"): identità, file, dove serve, interruttori e «Rimuovi…». Segue le
/// modifiche dal vivo e si chiude da solo se la mod sparisce dall'elenco.
Future<void> showModDetailDialog(BuildContext context, ModpackController mp, String key) =>
    showMsDialog<void>(
      context: context,
      builder: (_) => _ModDetailDialog(host: context, mp: mp, modKey: key),
    );

class _ModDetailDialog extends StatefulWidget {
  const _ModDetailDialog({required this.host, required this.mp, required this.modKey});

  /// Contesto della scheda: «Rimuovi…» apre il suo dialogo da lì, dopo aver
  /// chiuso questo (mai due dialoghi uno sopra l'altro).
  final BuildContext host;
  final ModpackController mp;
  final String modKey;

  @override
  State<_ModDetailDialog> createState() => _ModDetailDialogState();
}

class _ModDetailDialogState extends State<_ModDetailDialog> {
  var _closing = false;

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  void _remove() {
    _close();
    final host = widget.host;
    if (host.mounted) unawaited(removeMod(host, widget.mp, widget.modKey));
  }

  @override
  Widget build(BuildContext context) {
    final mp = widget.mp;
    return ListenableBuilder(
      listenable: mp,
      builder: (context, _) {
        final mod = mp.draft?.byKey(widget.modKey);
        if (mod == null) {
          // rimossa o modifiche annullate: il dettaglio non ha più senso
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _close();
          });
          return const SizedBox.shrink();
        }
        return _dialog(context, mod);
      },
    );
  }

  Widget _dialog(BuildContext context, PackMod mod) {
    final s = context.s.modpack;
    final fmt = context.s.fmt;
    final mp = widget.mp;
    final manual = mod.source == PackSource.manual;
    final modrinth = mod.source == PackSource.modrinth;
    final locked = mp.locked;
    // fonte, dimensione e la nota per quelle aggiunte a mano, come etichette
    final line = <String>[
      ?switch (mod.source) {
        PackSource.modrinth => 'Modrinth',
        PackSource.curseforge => 'CurseForge',
        PackSource.manual => null,
      },
      fmt.size(mod.size),
      if (manual) s.manualAdded,
    ];
    return MsDialog(
      title: modName(mod),
      onDismiss: _close,
      body: MsStack(
        gap: 16,
        children: [
          MsRow(
            gap: 12,
            wrap: false,
            children: [
              PackIcon(url: mp.iconUrlOf(mod.projectId), seed: mod.projectId ?? mod.key, size: 48),
              Expanded(
                child: MsStack(
                  gap: 4,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (mod.versionNumber != null) MsText(mod.versionNumber!, weight: 700),
                    MsMeta(line),
                  ],
                ),
              ),
            ],
          ),
          if (manual) MsText.small(s.manualText, tone: MsTextTone.secondary),
          MsFacts([
            MsFact(s.file, mod.file),
            MsFact('SHA-1', '${mod.sha1.substring(0, 4)}…${mod.sha1.substring(36)}'),
            MsFact(s.viewClient, switch (mod.side) {
              PackSide.both => s.inClientPack,
              PackSide.client => s.onlyClientPack,
              PackSide.server => s.notInClientPack,
            }),
            if (manual) MsFact(s.manualUpdate, s.manualUpdateValue),
          ]),
          MsField(
            label: s.whereLabel,
            help: s.whereHint,
            child: MsScrollX(
              child: MsSegmented<PackSide>(
                semanticLabel: s.whereLabel,
                value: mod.side,
                segments: sideSegments(s),
                onChanged: locked ? null : (v) => mp.setSide(mod.key, v),
              ),
            ),
          ),
          if (mod.side.onClient)
            MsSwitch(
              value: mod.optional,
              label: s.optionalForPlayers,
              onChanged: (v) => mp.setOptional(mod.key, v),
            ),
          if (modrinth)
            MsSwitch(
              value: mod.pinned,
              label: s.pinLabel,
              onChanged: (v) => mp.setPinned(mod.key, v),
            ),
          if (modrinth && mod.projectId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: MsButton(
                label: s.openModrinth,
                size: MsButtonSize.sm,
                variant: MsButtonVariant.ghost,
                icon: const MsIcon(MsIcons.globe),
                onPressed: () => mp.openUrl('https://modrinth.com/project/${mod.projectId}'),
              ),
            ),
          MsText.small(s.detailNote, tone: MsTextTone.secondary),
        ],
      ),
      // a sinistra, lontano da «Chiudi»: rimuovere è l'azione da non sbagliare
      leadingActions: [
        MsButton(
          label: s.remove,
          variant: MsButtonVariant.ghost,
          // il rosso solo sull'icona: il pulsante resta discreto
          icon: MsIcon(MsIcons.trash, color: locked ? null : MsTheme.colorsOf(context).err),
          onPressed: locked ? null : _remove,
        ),
      ],
      actions: [
        MsButton(
          label: s.close,
          variant: MsButtonVariant.primary,
          autofocus: true,
          onPressed: _close,
        ),
      ],
    );
  }
}

/// «Aggiungi un jar…»: percorso del file (come la cartella del server nelle
/// impostazioni), lato di default solo server.
Future<void> showAddJarDialog(BuildContext context, ModpackController mp) => showMsDialog<void>(
  context: context,
  builder: (_) => _AddJarDialog(mp: mp),
);

class _AddJarDialog extends StatefulWidget {
  const _AddJarDialog({required this.mp});
  final ModpackController mp;

  @override
  State<_AddJarDialog> createState() => _AddJarDialogState();
}

class _AddJarDialogState extends State<_AddJarDialog> {
  final _path = TextEditingController();
  var _side = PackSide.server;
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    try {
      await widget.mp.addJar(path, side: _side);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    return MsDialog(
      title: s.addJar.replaceAll('…', ''),
      icon: const MsIcon(MsIcons.plus),
      onDismiss: () => Navigator.of(context).pop(),
      body: MsStack(
        gap: 12,
        children: [
          MsField(
            label: s.cfPath,
            error: _error,
            child: MsTextInput(
              controller: _path,
              mono: true,
              autofocus: true,
              error: _error != null,
            ),
          ),
          MsField(
            label: s.whereLabel,
            help: s.whereHint,
            child: MsSegmented<PackSide>(
              semanticLabel: s.whereLabel,
              value: _side,
              segments: sideSegments(s),
              onChanged: (v) => setState(() => _side = v),
            ),
          ),
        ],
      ),
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(context).pop()),
        MsButton(label: s.addButton(1), variant: MsButtonVariant.primary, onPressed: _add),
      ],
    );
  }
}

// --- ricerca su Modrinth ---------------------------------------------------------------------

class SearchPanel extends StatefulWidget {
  const SearchPanel({super.key, required this.mp, required this.space});
  final ModpackController mp;
  final SpaceSummary space;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  late final _q = TextEditingController(text: widget.mp.query);
  Timer? _debounce;
  String? _busy;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => unawaited(widget.mp.search(v)));
  }

  Future<void> _install(SearchHitView h) async {
    final mp = widget.mp;
    final d = mp.draft!;
    setState(() => _busy = h.hit.projectId);
    try {
      final plan = await mp.planAddition(h.hit.projectId);
      if (!mounted) return;
      setState(() => _busy = null);
      if (plan.ok && plan.dependencies.isEmpty && plan.satisfied.isEmpty) {
        mp.add(plan);
        return;
      }
      final ok = await showAddDialog(
        context,
        plan,
        name: h.hit.title,
        loader: d.loader,
        mcVersion: d.mcVersion,
      );
      if (ok) mp.add(plan);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _busy = null);
      toast(context, context.s.modpack.searchDown, text: '$e', tone: MsToastTone.err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final mp = widget.mp;
    final d = mp.draft!;
    final ln = loaderLabel(context, d.loader);
    return MsPanel(
      title: s.searchTitle(ln, d.mcVersion),
      // l'unico punto da cui si aggiungono mod: Modrinth, o un file scaricato a parte
      actions: [
        MsButton(
          label: s.addJar,
          size: MsButtonSize.sm,
          variant: MsButtonVariant.ghost,
          icon: const MsIcon(MsIcons.plus),
          onPressed: () => showAddJarDialog(context, mp),
        ),
      ],
      child: MsStack(
        gap: 12,
        children: [
          MsTextInput(
            controller: _q,
            placeholder: s.searchPlaceholder,
            semanticLabel: s.searchLabel,
            onChanged: _changed,
            onSubmitted: (v) => unawaited(mp.search(v)),
          ),
          MsRow(
            gap: 8,
            children: [
              MsSelect<MrSearchIndex>(
                semanticLabel: s.sortLabel,
                value: mp.sort,
                options: [
                  MsSelectOption(value: MrSearchIndex.relevance, label: s.sortRelevance),
                  MsSelectOption(value: MrSearchIndex.downloads, label: s.sortDownloads),
                  MsSelectOption(value: MrSearchIndex.updated, label: s.sortUpdated),
                ],
                onChanged: (v) => mp.sort = v,
              ),
            ],
          ),
          MsSwitch(
            value: mp.onlyCompatible,
            label: s.onlyCompatible(widget.space.name),
            description: s.onlyCompatibleHint([ln, ?d.loaderVersion].join(' '), d.mcVersion),
            onChanged: (v) => mp.onlyCompatible = v,
          ),
          if (mp.modrinthDown && mp.results.isEmpty)
            MsEmptyState(
              title: s.searchDown,
              text: s.searchDownText,
              art: const MsArt(MsArts.crackedBlock),
              error: true,
              action: MsButton(label: s.retry, onPressed: mp.retryModrinth),
            )
          else if (mp.searching && mp.results.isEmpty)
            const MsRow(children: [MsSpinner()])
          else if (mp.query.isEmpty)
            MsText.small(s.searchEmpty, tone: MsTextTone.secondary)
          else if (mp.results.isEmpty)
            MsText.small(s.searchNone, tone: MsTextTone.secondary)
          else
            MsList(
              children: [
                for (final h in mp.results)
                  MsListRow(
                    title: h.hit.title,
                    meta: s.hitMeta(h.hit.author, s.downloads(h.hit.downloads), h.hit.description),
                    titleMaxLines: 1,
                    trail: h.installed
                        ? MsChip(s.chipInstalled)
                        : !h.fits
                        ? MsChip(
                            h.loaders.isNotEmpty &&
                                    !h.loaders.any(compatibleLoaders(d.loader).contains)
                                ? s.notFor(ln)
                                : s.notFor(d.mcVersion),
                          )
                        : MsButton(
                            label: _busy == h.hit.projectId ? s.installing : s.install,
                            size: MsButtonSize.sm,
                            loading: _busy == h.hit.projectId,
                            onPressed: _busy != null ? null : () => _install(h),
                          ),
                  ),
              ],
            ),
          if (!mp.onlyCompatible) MsText.small(s.searchHint, tone: MsTextTone.secondary),
        ],
      ),
    );
  }
}

// --- barra delle modifiche ---------------------------------------------------------------------

class PendingBar extends StatelessWidget {
  const PendingBar({super.key, required this.space, required this.mp});
  final SpaceSummary space;
  final ModpackController mp;

  Future<void> _apply(BuildContext context) async {
    final diff = mp.changes;
    if (diff == null) return;
    final head = space.headN;
    if (mp.locked) {
      final app = AppStateScope.read(context);
      final l = space.lock!;
      final queue = await showLockedApplyDialog(
        context,
        holder: l.name,
        server: space.name,
        changes: mp.changeCount,
        next: head + 1,
        since: context.s.fmt.duration(
          app.now().difference(DateTime.fromMillisecondsSinceEpoch(l.since)),
        ),
        online: l.info.players.length,
      );
      if (queue) mp.queueApply(true);
      return;
    }
    final ok = await showApplyConfirmDialog(
      context,
      diff: diff,
      server: space.name,
      next: head + 1,
      head: head,
      packIsNew: mp.firstSetup,
    );
    if (ok) await mp.apply();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final st = mp.applyState;
    final diff = mp.changes;
    final lines = diff == null
        ? const <String>[]
        : changeLines(context, diff, packIsNew: mp.firstSetup);
    final who = mp.holder;
    switch (st) {
      case Applying(:final step, :final done, :final total, :final current):
        return MsPanel(
          raised: true,
          semanticLabel: s.changesLabel,
          child: MsStack(
            gap: 8,
            children: [
              MsText(s.applyStep(step), weight: 700),
              MsProgress(value: total > 0 ? (done / total).clamp(0.0, 1.0) : null),
              if (current != null) MsText.small(s.downloading(current), tone: MsTextTone.secondary),
            ],
          ),
        );
      case ApplyDone(:final n):
        return MsAlert(
          title: n == null ? s.appliedNothing : s.applied(n),
          text: s.appliedText,
          tone: MsAlertTone.ok,
          actions: [MsButton(label: s.close, size: MsButtonSize.sm, onPressed: mp.clearApply)],
        );
      case ApplyFailed(:final reason, :final error, :final mods)
          when !mp.dirty || reason != 'locked':
        return MsAlert(
          title: s.applyFailed,
          text: [
            s.applyFailedText(reason, error),
            if (mods.isNotEmpty) mods.map(modName).join(', '),
          ].join(' '),
          tone: MsAlertTone.err,
          actions: [
            for (final m in mods)
              if (m.source == PackSource.curseforge && mp.root != null)
                MsButton(
                  label: s.cfTitle(modName(m)),
                  size: MsButtonSize.sm,
                  onPressed: () => showCurseForgeDialog(
                    context,
                    m,
                    root: mp.root!,
                    loader: mp.draft!.loader,
                    mcVersion: mp.draft!.mcVersion,
                  ),
                ),
            if (mp.dirty)
              MsButton(label: s.retry, size: MsButtonSize.sm, onPressed: () => _apply(context)),
            MsButton(label: s.close, size: MsButtonSize.sm, onPressed: mp.clearApply),
          ],
        );
      default:
        break;
    }
    if (!mp.dirty) return const SizedBox.shrink();
    final waiting = mp.modrinthDown && (diff?.added.isNotEmpty ?? false);
    final note = mp.queued && who != null
        ? s.queuedText(who)
        : who != null
        ? s.lockedBar(who, space.name)
        : waiting
        ? s.waitingModrinthText
        : s.appliesNext;
    // una riga sola: conteggio, aiuto nel tooltip della «i», poi le prime
    // modifiche
    final gap = PixelScope.of(context).d(8);
    final summary = Row(
      children: [
        MsText('${mp.changeCount} ${s.changes(mp.changeCount)}', weight: 700, maxLines: 1),
        SizedBox(width: gap),
        MsTooltip(
          message: note,
          child: Semantics(label: note, child: const MsIcon(MsIcons.info)),
        ),
        SizedBox(width: gap),
        // le modifiche che entrano, l'ultima accorciata: niente etichette
        // tagliate a metà sul bordo
        Flexible(
          child: MsMeta([
            if (waiting) s.waitingModrinth,
            ...lines.take(_barLines),
            if (lines.length > _barLines) s.andMore(lines.length - _barLines),
          ], maxLines: 1),
        ),
      ],
    );
    // come nei dialoghi e nel wizard: «Annulla» poi l'azione principale, a
    // destra anche quando vanno a capo
    final actions = MsRow(
      gap: 8,
      end: true,
      children: [
        MsButton(label: s.discard, size: MsButtonSize.sm, onPressed: mp.discard),
        if (who != null)
          mp.queued
              ? MsButton(
                  label: s.unqueue,
                  size: MsButtonSize.sm,
                  onPressed: () => mp.queueApply(false),
                )
              : MsButton(
                  label: s.applyWhen(who),
                  size: MsButtonSize.sm,
                  variant: MsButtonVariant.primary,
                  icon: const MsIcon(MsIcons.clock),
                  onPressed: () => mp.queueApply(true),
                ),
        MsButton(
          label: s.apply,
          size: MsButtonSize.sm,
          variant: who == null ? MsButtonVariant.primary : MsButtonVariant.secondary,
          icon: const MsIcon(MsIcons.upload),
          onPressed: waiting || mp.queued ? null : () => _apply(context),
        ),
      ],
    );
    final g = PixelScope.of(context);
    return MsPanel(
      raised: true,
      padding: MsPanelPadding.none,
      semanticLabel: s.changesLabel,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: g.d(12), horizontal: g.d(16)),
        child: LayoutBuilder(
          // stretta: i pulsanti vanno sotto, a destra; mai oltre il bordo
          builder: (context, box) => box.maxWidth < g.d(640)
              ? MsStack(
                  gap: 12,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    summary,
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: summary),
                    SizedBox(width: g.d(16)),
                    // i pulsanti prima, al massimo su 3/5 della riga (poi a
                    // capo tra loro); il resto alle modifiche
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * .6),
                      child: actions,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Modifiche mostrate come chip nella barra; le altre in «e altre N».
const _barLines = 3;

// --- cambia versione o loader -------------------------------------------------------------------

class RetargetPanel extends StatefulWidget {
  const RetargetPanel({super.key, required this.mp, required this.space, required this.onClose});
  final ModpackController mp;
  final SpaceSummary space;
  final VoidCallback onClose;

  /// Controllo già fatto da mostrare all'apertura (test e anteprime).
  @visibleForTesting
  static CompatReport? debugReport;

  @override
  State<RetargetPanel> createState() => _RetargetPanelState();
}

class _RetargetPanelState extends State<RetargetPanel> {
  late String _mc = widget.mp.draft!.mcVersion;
  late Loader _loader = widget.mp.draft!.loader;
  String? _loaderVersion;
  List<String>? _versions;
  List<(String, bool)>? _loaderVersions;
  var _releasesOnly = true;
  CompatReport? _report;
  var _checking = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loaderVersion = widget.mp.draft!.loaderVersion;
    final r = RetargetPanel.debugReport;
    if (r != null) {
      _report = r;
      _mc = r.target.mcVersion;
      _loader = r.target.loader;
      _loaderVersion = r.loaderVersion;
      _loaderVersions = [if (r.loaderVersion != null) (r.loaderVersion!, true)];
      _versions = [r.target.mcVersion, r.from.mcVersion];
      return;
    }
    unawaited(_loadVersions());
    unawaited(_loadLoaderVersions());
    unawaited(widget.mp.space.ensureJava());
  }

  Future<void> _loadVersions() async {
    try {
      final v = await widget.mp.minecraftVersions(releasesOnly: _releasesOnly);
      if (mounted) setState(() => _versions = v);
    } on Object {
      if (mounted) setState(() => _versions = const []);
    }
  }

  Future<void> _loadLoaderVersions() async {
    if (_loader == Loader.vanilla) {
      setState(() {
        _loaderVersions = const [];
        _loaderVersion = null;
      });
      return;
    }
    setState(() => _loaderVersions = null);
    try {
      final v = await widget.mp.loaderVersions(_loader, _mc);
      if (!mounted) return;
      setState(() {
        _loaderVersions = v;
        final stable = v.where((e) => e.$2).firstOrNull ?? v.firstOrNull;
        final d = widget.mp.draft!;
        _loaderVersion = d.loader == _loader && d.mcVersion == _mc ? d.loaderVersion : stable?.$1;
      });
    } on Object {
      if (mounted) setState(() => _loaderVersions = const []);
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
      _report = null;
    });
    try {
      final r = await widget.mp.checkRetarget(_mc, _loader, _loaderVersion);
      if (mounted) setState(() => _report = r);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _change({required bool removeBlocked}) async {
    final r = _report;
    if (r == null) return;
    if (r.target.loader != r.from.loader || removeBlocked && r.blocked.isNotEmpty) {
      final ok = await showLoaderChangeDialog(
        context,
        r,
        server: widget.space.name,
        head: widget.space.headN,
      );
      if (!ok) return;
    }
    widget.mp.retarget(r);
    widget.onClose();
  }

  String _name(String projectId) => widget.mp.draft?.byProject(projectId)?.name ?? projectId;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final mp = widget.mp;
    final d = mp.draft!;
    final ss = mp.space;
    final need = requiredJava(_mc);
    final java = pickJava(ss.javas ?? const [], need);
    final javaOk = java != null && (need == 0 || java.major >= need);
    final versions = {...?_versions, d.mcVersion}.toList();
    final latest = _versions?.firstOrNull;
    final lvs = _loaderVersions;
    final r = _report;
    final changed = _mc != d.mcVersion || _loader != d.loader || _loaderVersion != d.loaderVersion;
    return MsPanel(
      title: s.retargetTitle,
      actions: [
        MsButton.icon(
          icon: const MsIcon(MsIcons.x),
          semanticLabel: s.cancel,
          size: MsButtonSize.sm,
          variant: MsButtonVariant.ghost,
          onPressed: widget.onClose,
        ),
      ],
      child: MsStack(
        gap: 16,
        children: [
          MsText.small(s.retargetIntro, tone: MsTextTone.secondary),
          Columns(
            minWidth: 280,
            children: [
              (
                1,
                MsField(
                  label: s.minecraft,
                  help: s.nowOn(d.mcVersion),
                  child: MsStack(
                    gap: 8,
                    children: [
                      MsSelect<String>(
                        semanticLabel: s.minecraft,
                        value: _mc,
                        options: [
                          for (final v in versions)
                            MsSelectOption(
                              value: v,
                              label: v == d.mcVersion
                                  ? s.current(v)
                                  : v == latest
                                  ? s.latest(v)
                                  : v,
                            ),
                        ],
                        onChanged: (v) {
                          setState(() {
                            _mc = v;
                            _report = null;
                          });
                          unawaited(_loadLoaderVersions());
                        },
                      ),
                      MsSwitch(
                        value: _releasesOnly,
                        label: s.releasesOnly,
                        onChanged: (v) {
                          setState(() => _releasesOnly = v);
                          unawaited(_loadVersions());
                        },
                      ),
                    ],
                  ),
                ),
              ),
              (
                1,
                MsField(
                  label: s.loader,
                  help: lvs == null
                      ? s.checking
                      : _loader != Loader.vanilla && lvs.isEmpty
                      ? s.noLoaderVersions
                      : _loaderVersion != null
                      ? s.loaderVersionPicked(loaderLabel(context, _loader), _loaderVersion!, _mc) +
                            (_loader != d.loader ? ' ${s.loaderChangeWarn}' : '')
                      : null,
                  child: MsSegmented<Loader>(
                    semanticLabel: s.loader,
                    value: _loader,
                    segments: [
                      for (final l in [
                        Loader.vanilla,
                        Loader.fabric,
                        Loader.quilt,
                        Loader.neoforge,
                        Loader.forge,
                      ])
                        MsSegment(value: l, label: loaderLabel(context, l)),
                    ],
                    onChanged: (l) {
                      setState(() {
                        _loader = l;
                        _report = null;
                      });
                      unawaited(_loadLoaderVersions());
                    },
                  ),
                ),
              ),
            ],
          ),
          if (ss.javas != null && need > 0)
            javaOk
                ? MsAlert(
                    title: s.javaOk(need),
                    text: s.javaOkText(_mc, need, 'Java ${java.version}'),
                    tone: MsAlertTone.ok,
                  )
                : MsAlert(
                    title: s.javaMissing(need),
                    text: s.javaMissingText(_mc, need),
                    tone: MsAlertTone.warn,
                    actions: [
                      MsButton(
                        label: s.javaHow,
                        size: MsButtonSize.sm,
                        icon: const MsIcon(MsIcons.globe),
                        onPressed: () => mp.openUrl(temurinUrl(need)),
                      ),
                      MsButton(
                        label: s.javaRescan,
                        size: MsButtonSize.sm,
                        icon: const MsIcon(MsIcons.refresh),
                        onPressed: () => ss.ensureJava(force: true),
                      ),
                    ],
                  ),
          if (_error != null)
            MsAlert(title: s.modrinthDown, text: s.modrinthDownText, tone: MsAlertTone.warn),
          if (_checking) MsRow(children: [const MsSpinner(), MsText(s.checkingMods)]),
          if (r != null) ..._reportView(context, r),
          MsRow(
            gap: 8,
            children: [
              if (r == null)
                MsButton(
                  label: s.check,
                  variant: MsButtonVariant.primary,
                  icon: const MsIcon(MsIcons.search),
                  loading: _checking,
                  onPressed:
                      !changed || _checking || (_loader != Loader.vanilla && _loaderVersion == null)
                      ? null
                      : _check,
                )
              else if (r.blocked.isEmpty)
                MsButton(
                  label: s.changeTarget,
                  variant: MsButtonVariant.primary,
                  onPressed: () => _change(removeBlocked: false),
                )
              else ...[
                MsButton(
                  label: mp.watch != null ? s.watchSet : s.watch,
                  variant: MsButtonVariant.primary,
                  icon: const MsIcon(MsIcons.bell),
                  onPressed: mp.watch != null
                      ? null
                      : () async {
                          await mp.setWatch(_mc, _loader, _loaderVersion);
                          if (mounted) setState(() {});
                        },
                ),
                MsButton(
                  label: s.changeAndRemove(r.blocked.length),
                  variant: MsButtonVariant.danger,
                  onPressed: () => _change(removeBlocked: true),
                ),
              ],
              MsButton(label: s.cancel, variant: MsButtonVariant.ghost, onPressed: widget.onClose),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _reportView(BuildContext context, CompatReport r) {
    final s = context.s.modpack;
    return [
      MsText(s.checkDone(r.entries.length), weight: 700),
      MsRow(
        gap: 6,
        children: [
          MsPill(s.ready(r.ready.length, r.target.mcVersion), tone: MsStatusTone.ok),
          if (r.blocked.isNotEmpty) MsPill(s.blocking(r.blocked.length), tone: MsStatusTone.err),
          if (r.manual.isNotEmpty) MsPill(s.toCheck(r.manual.length), tone: MsStatusTone.warn),
        ],
      ),
      if (r.blocked.isNotEmpty || r.manual.isNotEmpty)
        MsList(
          children: [
            for (final e in r.blocked)
              MsListRow(
                title: modName(e.mod),
                meta: e.blockers.isEmpty ? '' : blockerText(s, e.blockers.first, _name),
                trail: MsChip(s.notReady),
              ),
            for (final e in r.manual)
              MsListRow(title: modName(e.mod), meta: s.manualReason, trail: MsChip(s.chipToCheck)),
          ],
        ),
      MsText.small(
        s.readyFoot(r.ready.length, r.target.mcVersion, widget.space.headN),
        tone: MsTextTone.secondary,
      ),
    ];
  }
}
