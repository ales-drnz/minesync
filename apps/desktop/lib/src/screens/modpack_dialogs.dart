// Dialoghi del modpack: dipendenze di una mod da installare, aggiornamento
// o mod non installabile (con il perché), cambio di loader, mod CurseForge
// da scaricare a mano, applica mentre qualcuno gioca, conferma di
// «Applica e carica» e rimozione con le dipendenti. Stesse regole degli
// altri dialoghi: cosa succede, cosa è al sicuro, cosa fare.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';

/// Nome da mostrare di una mod.
String modName(PackMod m) => m.name ?? m.file;

/// Versione da mostrare di una mod.
String modVersion(PackMod m) => m.versionNumber ?? m.file;

/// Segnale del lato di una mod nelle righe. «Server e giocatori» è il caso
/// normale e non ha segnale; solo le eccezioni hanno un'icona neutra con il
/// significato nel tooltip. Sempre larga 24 px, così i controlli a destra
/// restano in colonna.
Widget sideMarker(BuildContext context, PackSide side) {
  final s = context.s.modpack;
  final g = PixelScope.of(context);
  return SizedBox(
    width: g.d(24),
    child: switch (side) {
      PackSide.both => null,
      PackSide.server => MsIconTag(const MsIcon(MsIcons.server), tooltip: s.sideServerTip),
      PackSide.client => MsIconTag(const MsIcon(MsIcons.user), tooltip: s.sideClientTip),
    },
  );
}

/// Segmenti del selettore «Dove serve», con le icone dei lati, nell'ordine
/// server · server e giocatori · giocatori.
List<MsSegment<PackSide>> sideSegments(ModpackStrings s) => [
  MsSegment(value: PackSide.server, label: s.sideServer, icon: const MsIcon(MsIcons.server)),
  MsSegment(value: PackSide.both, label: s.sideBoth, icon: const MsIcon(MsIcons.sideBoth)),
  MsSegment(value: PackSide.client, label: s.sideClient, icon: const MsIcon(MsIcons.user)),
];

/// Nome di un loader.
String loaderLabel(BuildContext context, Loader l) => context.s.server.loaderName(l.name);

/// Motivo di un blocco in parole.
String blockerText(ModpackStrings s, Blocker b, String Function(String id) name) => s.blockReason(
  b.reason.name,
  other: b.otherProjectId == null ? null : name(b.otherProjectId!),
  versions: b.gameVersions,
);

Widget _p(String text, {MsTextTone tone = MsTextTone.primary, bool small = false}) =>
    small ? MsText.small(text, tone: tone) : MsText(text, tone: tone);

/// Riga di un elenco nei dialoghi: nome, nota, chip a destra.
class _ModLine extends StatelessWidget {
  const _ModLine({required this.title, required this.meta, this.trail});
  final String title;
  final String meta;
  final Widget? trail;

  @override
  Widget build(BuildContext context) => MsListRow(title: title, meta: meta, trail: trail);
}

// --- 1 · dipendenze -------------------------------------------------------------

/// «Installare X?»: la mod scelta, le dipendenze da aggiungere e quelle che
/// ci sono già. Vero se l'utente conferma.
Future<bool> showAddDialog(
  BuildContext context,
  AddPlan plan, {
  required String name,
  required Loader loader,
  required String mcVersion,
}) async =>
    await showMsDialog<bool>(
      context: context,
      builder: (_) => AddDialog(plan: plan, name: name, loader: loader, mcVersion: mcVersion),
    ) ??
    false;

class AddDialog extends StatelessWidget {
  const AddDialog({
    super.key,
    required this.plan,
    required this.name,
    required this.loader,
    required this.mcVersion,
  });

  final AddPlan plan;
  final String name;
  final Loader loader;
  final String mcVersion;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final mod = plan.mod;
    if (!plan.ok || mod == null) {
      return MsDialog(
        title: s.addBlockedTitle(name),
        icon: const MsIcon(MsIcons.warn),
        tone: MsDialogTone.warn,
        onDismiss: () => Navigator.of(context).pop(false),
        body: MsStack(
          gap: 12,
          children: [
            _p(s.addBlockedText),
            MsList(
              children: [
                for (final b in plan.blockers)
                  _ModLine(title: name, meta: blockerText(s, b, (id) => id)),
              ],
            ),
          ],
        ),
        actions: [
          MsButton(
            label: s.close,
            variant: MsButtonVariant.primary,
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      );
    }
    final ln = loaderLabel(context, loader);
    final n = 1 + plan.dependencies.length;
    return MsDialog(
      title: s.addTitle(name),
      icon: const MsIcon(MsIcons.mods),
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(s.addText(name, plan.dependencies.length, ln, mcVersion)),
          MsList(
            children: [
              _ModLine(
                title: '${modName(mod)} ${modVersion(mod)}',
                meta: s.chosen,
                trail: sideMarker(context, mod.side),
              ),
              for (final d in plan.dependencies)
                _ModLine(
                  title: '${modName(d)} ${modVersion(d)}',
                  meta: s.requiredFor(name),
                  trail: MsChip(s.willAdd, tone: MsChipTone.accent),
                ),
              for (final d in plan.satisfied)
                _ModLine(title: modName(d), meta: s.alreadyThere(modVersion(d))),
            ],
          ),
          _p(s.addFoot, tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: s.addButton(n),
          variant: MsButtonVariant.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

// --- 2 · aggiornamento incompatibile ------------------------------------------------

/// Esito del dialogo dell'aggiornamento bloccato.
enum BlockedUpdateChoice { stay, hide }

Future<BlockedUpdateChoice> showBlockedUpdateDialog(
  BuildContext context,
  UpdateCheck u, {
  String Function(String id)? name,
}) async =>
    await showMsDialog<BlockedUpdateChoice>(
      context: context,
      builder: (_) => BlockedUpdateDialog(check: u, name: name ?? (id) => id),
    ) ??
    BlockedUpdateChoice.stay;

class BlockedUpdateDialog extends StatelessWidget {
  const BlockedUpdateDialog({super.key, required this.check, required this.name});

  final UpdateCheck check;
  final String Function(String id) name;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final m = check.mod;
    final v = check.latest?.versionNumber ?? '?';
    final versions = {for (final b in check.blockers) ...b.gameVersions}.toList();
    return MsDialog(
      title: s.updateBlockedTitle(modName(m), v),
      icon: const MsIcon(MsIcons.warn),
      tone: MsDialogTone.warn,
      onDismiss: () => Navigator.of(context).pop(BlockedUpdateChoice.stay),
      body: MsStack(
        gap: 12,
        children: [
          MsFacts([
            MsFact(s.haveNow, '${modName(m)} ${modVersion(m)}'),
            for (final b in check.blockers) MsFact(s.needs, blockerText(s, b, name)),
            if (versions.isNotEmpty) MsFact(s.toGetIt, 'Minecraft ${versions.join(', ')}'),
          ]),
          _p(s.updateBlockedFoot, tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(
          label: s.hideUpdate,
          variant: MsButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(BlockedUpdateChoice.hide),
        ),
        MsButton(
          label: s.stayOn(modVersion(m)),
          variant: MsButtonVariant.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(BlockedUpdateChoice.stay),
        ),
      ],
    );
  }
}

// --- 3 · cambio di loader ---------------------------------------------------------

/// «Passare X a NeoForge?»: quante restano, quante se ne vanno, come si
/// torna indietro. Vero se l'utente conferma.
Future<bool> showLoaderChangeDialog(
  BuildContext context,
  CompatReport report, {
  required String server,
  required int head,
}) async =>
    await showMsDialog<bool>(
      context: context,
      builder: (_) => LoaderChangeDialog(report: report, server: server, head: head),
    ) ??
    false;

class LoaderChangeDialog extends StatelessWidget {
  const LoaderChangeDialog({
    super.key,
    required this.report,
    required this.server,
    required this.head,
  });

  final CompatReport report;
  final String server;
  final int head;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final to = loaderLabel(context, report.target.loader);
    final from = loaderLabel(context, report.from.loader);
    final gone = report.blocked.map((e) => modName(e.mod)).toList();
    final names = gone.take(3).join(', ');
    return MsDialog(
      title: s.loaderTitle(server, to),
      icon: const MsIcon(MsIcons.warn),
      tone: MsDialogTone.danger,
      step: s.loaderEyebrow,
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(s.loaderText(to, report.target.mcVersion)),
          MsFacts([
            MsFact(
              s.ready(report.ready.length, report.target.mcVersion),
              s.keep(report.ready.length, to),
            ),
            if (gone.isNotEmpty) MsFact(s.blocking(gone.length), s.removed(gone.length, names)),
            if (gone.isNotEmpty) MsFact(s.notReady, s.worldLoss),
            MsFact(s.backTerm, s.backValue(head, from)),
          ]),
          _p(s.loaderFoot, tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(
          label: s.stayOnLoader(from),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        MsButton(
          label: s.switchTo(to),
          variant: MsButtonVariant.danger,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

// --- 4 · CurseForge -----------------------------------------------------------------

/// «X va scaricata a mano»: link alla pagina e percorso del file scaricato,
/// verificato con l'impronta del pack e messo al suo posto in [root].
/// Vero se il file è stato messo.
Future<bool> showCurseForgeDialog(
  BuildContext context,
  PackMod mod, {
  required String root,
  required Loader loader,
  required String mcVersion,
}) async =>
    await showMsDialog<bool>(
      context: context,
      builder: (_) => CurseForgeDialog(mod: mod, root: root, loader: loader, mcVersion: mcVersion),
    ) ??
    false;

class CurseForgeDialog extends StatefulWidget {
  const CurseForgeDialog({
    super.key,
    required this.mod,
    required this.root,
    required this.loader,
    required this.mcVersion,
  });

  final PackMod mod;
  final String root;
  final Loader loader;
  final String mcVersion;

  @override
  State<CurseForgeDialog> createState() => _CurseForgeDialogState();
}

class _CurseForgeDialogState extends State<CurseForgeDialog> {
  final _path = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _use() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    setState(() => _busy = true);
    try {
      final f = await hashFile(path, relPath: widget.mod.location);
      if (f.sha1 != widget.mod.sha1) throw const FormatException();
      final dest = insideRoot(widget.root, widget.mod.diskLocation);
      await Directory(File(dest).parent.path).create(recursive: true);
      await File(path).copy(dest);
      if (mounted) Navigator.of(context).pop(true);
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = context.s.modpack.cfWrong;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final app = AppStateScope.of(context);
    final page = widget.mod.curseforge?.pageUrl;
    return MsDialog(
      title: s.cfTitle(modName(widget.mod)),
      icon: const MsIcon(MsIcons.download),
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(s.cfText),
          _p('1. ${s.cfStep1(loaderLabel(context, widget.loader), widget.mcVersion)}'),
          _p('2. ${s.cfStep2}'),
          MsField(
            label: s.cfPath,
            error: _error,
            child: MsTextInput(controller: _path, mono: true, error: _error != null),
          ),
          _p(s.cfFoot, tone: MsTextTone.secondary, small: true),
        ],
      ),
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(label: s.cfHaveFile, loading: _busy, onPressed: _busy ? null : _use),
        if (page != null)
          MsButton(
            label: s.cfOpen,
            variant: MsButtonVariant.primary,
            icon: const MsIcon(MsIcons.globe),
            onPressed: () => unawaited(app.modpackEnv.tools.openUrl(page)),
          ),
      ],
    );
  }
}

// --- 5 · applica mentre qualcuno gioca -------------------------------------------------

/// Rifiuto con l'opzione di applicare quando il server si libera. Vero se
/// l'utente mette le modifiche in coda.
Future<bool> showLockedApplyDialog(
  BuildContext context, {
  required String holder,
  required String server,
  required int changes,
  required int next,
  required String since,
  required int online,
}) async =>
    await showMsDialog<bool>(
      context: context,
      builder: (_) => LockedApplyDialog(
        holder: holder,
        server: server,
        changes: changes,
        next: next,
        since: since,
        online: online,
      ),
    ) ??
    false;

class LockedApplyDialog extends StatefulWidget {
  const LockedApplyDialog({
    super.key,
    required this.holder,
    required this.server,
    required this.changes,
    required this.next,
    required this.since,
    required this.online,
  });

  final String holder;
  final String server;
  final int changes;
  final int next;
  final String since;
  final int online;

  @override
  State<LockedApplyDialog> createState() => _LockedApplyDialogState();
}

class _LockedApplyDialogState extends State<LockedApplyDialog> {
  var _queue = true;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    return MsDialog(
      title: s.lockedTitle2(widget.holder, widget.server),
      icon: const MsIcon(MsIcons.lock),
      tone: MsDialogTone.warn,
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(s.lockedText2),
          MsFacts([
            MsFact(s.yourChanges, s.yourChangesValue(widget.changes)),
            MsFact(s.inGame, s.inGameValue(widget.holder, widget.since, widget.online)),
            MsFact(s.whenFree, s.whenFreeValue(widget.next)),
          ]),
          MsSwitch(
            value: _queue,
            label: s.queueSwitch,
            description: s.queueSwitchHint,
            onChanged: (v) => setState(() => _queue = v),
          ),
        ],
      ),
      actions: [
        MsButton(label: s.close, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: s.wait,
          variant: MsButtonVariant.primary,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(_queue),
        ),
      ],
    );
  }
}

// --- 6 · applica e carica ---------------------------------------------------------------

/// Righe del riepilogo delle modifiche (anche nella barra in basso).
List<String> changeLines(BuildContext context, PackDiff d, {bool packIsNew = false}) {
  final s = context.s.modpack;
  // il file interno del pacchetto non si mostra: al suo posto la prima
  // configurazione delle mod, che conta come una modifica (come in
  // ModpackState.changeCount)
  return [
    if (packIsNew) s.lineFirstSetup,
    if (d.mcVersion != null || d.loader != null)
      s.lineTarget(loaderLabel(context, d.loader?.$2.$1 ?? Loader.vanilla), d.mcVersion?.$2 ?? ''),
    for (final m in d.added) s.lineAdded(modName(m), modVersion(m)),
    for (final (a, b) in d.updated) s.lineUpdated(modName(b), modVersion(a), modVersion(b)),
    for (final (_, b) in d.toggled)
      b.disabled ? s.lineDisabled(modName(b)) : s.lineEnabled(modName(b)),
    for (final m in d.removed) s.lineRemoved(modName(m)),
    for (final (_, b) in d.changed) s.lineChanged(modName(b)),
    if (d.sharedChanged) s.lineShared,
  ];
}

Future<bool> showApplyConfirmDialog(
  BuildContext context, {
  required PackDiff diff,
  required String server,
  required int next,
  required int head,
  bool packIsNew = false,
}) async =>
    await showMsDialog<bool>(
      context: context,
      builder: (_) => ApplyConfirmDialog(
        diff: diff,
        server: server,
        next: next,
        head: head,
        packIsNew: packIsNew,
      ),
    ) ??
    false;

class ApplyConfirmDialog extends StatelessWidget {
  const ApplyConfirmDialog({
    super.key,
    required this.diff,
    required this.server,
    required this.next,
    required this.head,
    this.packIsNew = false,
  });

  final PackDiff diff;
  final String server;
  final int next;
  final int head;
  final bool packIsNew;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final fmt = context.s.fmt;
    final downloads = [...diff.added, for (final (_, b) in diff.updated) b];
    final bytes = downloads.fold(0, (a, m) => a + m.size);
    final lines = changeLines(context, diff, packIsNew: packIsNew);
    return MsDialog(
      title: s.confirmTitle,
      icon: const MsIcon(MsIcons.upload),
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(s.confirmText(next, server)),
          MsList(
            children: [
              for (final l in lines.take(8)) MsListRow(title: l),
              if (lines.length > 8) MsListRow(title: s.andMore(lines.length - 8)),
            ],
          ),
          MsFacts([
            MsFact(
              s.size,
              downloads.isEmpty
                  ? s.noDownload
                  : s.confirmDownload(downloads.length, fmt.size(bytes)),
            ),
            MsFact(s.backTerm, s.historyBack(head)),
            MsFact(s.forPlayers, s.forPlayersValue),
          ]),
        ],
      ),
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: s.confirmApply,
          variant: MsButtonVariant.primary,
          icon: const MsIcon(MsIcons.upload),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

// --- 7 · rimozione ------------------------------------------------------------------------

Future<bool> showRemoveDialog(BuildContext context, RemovePlan plan) async =>
    await showMsDialog<bool>(
      context: context,
      builder: (_) => RemoveDialog(plan: plan),
    ) ??
    false;

class RemoveDialog extends StatelessWidget {
  const RemoveDialog({super.key, required this.plan});
  final RemovePlan plan;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final name = modName(plan.target);
    final others = plan.dependents.length + plan.orphans.length;
    return MsDialog(
      title: s.removeTitle(name),
      icon: const MsIcon(MsIcons.trash),
      tone: MsDialogTone.danger,
      onDismiss: () => Navigator.of(context).pop(false),
      body: MsStack(
        gap: 12,
        children: [
          _p(s.removeText),
          if (plan.dependents.isNotEmpty || plan.orphans.isNotEmpty)
            MsFacts([
              if (plan.dependents.isNotEmpty)
                MsFact(s.dependentsTerm, s.usedBy(plan.dependents.length)),
              if (plan.orphans.isNotEmpty) MsFact(s.orphansTerm, s.orphans(plan.orphans.length)),
            ]),
          if (others > 0)
            MsList(
              children: [
                for (final m in [...plan.dependents, ...plan.orphans])
                  MsListRow(
                    title: modName(m),
                    meta: s.dependsOn(name),
                    trail: MsChip(s.alsoRemoved),
                  ),
              ],
            ),
        ],
      ),
      actions: [
        MsButton(
          label: s.cancel,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        MsButton(
          label: s.removeButton(name, others),
          variant: MsButtonVariant.danger,
          icon: const MsIcon(MsIcons.trash),
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}
