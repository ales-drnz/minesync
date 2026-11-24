// Storia di un server: elenco delle versioni con filtro e ricerca, dettaglio
// della versione scelta con le differenze rispetto a quella da cui parte e,
// per gli admin, il ripristino (che crea una nuova versione: non si perde
// niente).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import '../state/space_state.dart';
import 'common.dart';
import 'server.dart' show GenerationRow;

/// File mostrati per scheda nel dettaglio.
const _filesShown = 12;

enum _Filter { all, saves, restores }

enum _DiffTab { added, changed, removed }

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.space});

  /// Id dello spazio.
  final String space;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _query = TextEditingController();
  var _filter = _Filter.all;
  int? _selected;
  var _tab = _DiffTab.changed;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
    final ss = AppStateScope.read(context).spaceState(widget.space);
    if (ss.history.isEmpty) unawaited(ss.loadHistory());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<GenerationSummary> _visible(SpaceState ss) {
    final q = _query.text.trim().toLowerCase();
    return [
      for (final g in ss.history)
        if (switch (_filter) {
              _Filter.all => true,
              _Filter.saves => g.kind == GenerationKind.push,
              _Filter.restores => g.kind == GenerationKind.restore,
            } &&
            (q.isEmpty ||
                g.author.toLowerCase().contains(q) ||
                g.message.toLowerCase().contains(q)))
          g,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final sp = app.space(widget.space);
    if (sp == null) return const SizedBox.shrink();
    final ss = app.spaceState(sp.id);
    return ListenableBuilder(
      listenable: ss,
      builder: (context, _) {
        final list = _visible(ss);
        final sel = list.where((g) => g.n == _selected).firstOrNull ?? list.firstOrNull;
        final i = sel == null ? -1 : list.indexOf(sel);
        void pick(int j) => setState(() => _selected = list[j].n);
        final newer = i > 0 ? () => pick(i - 1) : null;
        final older = i >= 0 && i < list.length - 1 ? () => pick(i + 1) : null;
        return KeyShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowUp): newer,
            const SingleActivator(LogicalKeyboardKey.arrowDown): older,
          },
          child: LayoutBuilder(
            builder: (context, box) {
              final g = PixelScope.of(context);
              Widget detail({required bool scroll}) => sel == null
                  ? const SizedBox.shrink()
                  : _Detail(
                      key: ValueKey(sel.n),
                      space: sp,
                      state: ss,
                      gen: sel,
                      tab: _tab,
                      onTab: (t) => setState(() => _tab = t),
                      onNewer: newer,
                      onOlder: older,
                      scroll: scroll,
                    );
              // finestra stretta: una colonna sola che scorre tutta
              if (box.maxWidth < g.d(820)) {
                return ScreenBody(
                  children: [
                    ServerTabs(space: sp.id, current: ServerTab.history),
                    _Title(space: sp),
                    _versions(context, ss, sp, list, sel, scroll: false),
                    detail(scroll: false),
                  ],
                );
              }
              // le due colonne occupano tutta l'altezza della finestra e
              // scorrono al loro interno: si aprono già della loro misura
              return Padding(
                padding: EdgeInsets.fromLTRB(g.d(24), g.d(20), g.d(24), g.d(24)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ServerTabs(space: sp.id, current: ServerTab.history),
                    SizedBox(height: g.d(16)),
                    _Title(space: sp),
                    SizedBox(height: g.d(16)),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _versions(context, ss, sp, list, sel, scroll: true)),
                          SizedBox(width: g.d(16)),
                          Expanded(child: detail(scroll: true)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _versions(
    BuildContext context,
    SpaceState ss,
    SpaceSummary sp,
    List<GenerationSummary> list,
    GenerationSummary? sel, {
    required bool scroll,
  }) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.history;
    final now = app.now();
    return MsPanel(
      scrollBody: scroll,
      title: s.versions,
      actions: [MsText.small(s.count(sp.headN), tone: MsTextTone.secondary)],
      padding: MsPanelPadding.tight,
      child: MsStack(
        gap: 10,
        children: [
          // ricerca e filtro alti uguali; in una colonna stretta la ricerca
          // va sotto invece di ridursi a poche lettere
          LayoutBuilder(
            builder: (context, box) {
              final g = PixelScope.of(context);
              final filter = MsSegmented<_Filter>(
                semanticLabel: s.filterLabel,
                value: _filter,
                segments: [
                  MsSegment(value: _Filter.all, label: s.all),
                  MsSegment(value: _Filter.saves, label: s.sessions),
                  MsSegment(value: _Filter.restores, label: s.restores),
                ],
                onChanged: (f) => setState(() => _filter = f),
              );
              final search = MsTextInput(
                controller: _query,
                dense: true,
                placeholder: s.searchPlaceholder,
                semanticLabel: s.searchLabel,
              );
              if (box.maxWidth < g.d(560)) {
                return MsStack(
                  gap: 8,
                  children: [
                    search,
                    Align(alignment: Alignment.centerLeft, child: filter),
                  ],
                );
              }
              return Row(
                spacing: g.d(8),
                children: [
                  filter,
                  Expanded(child: search),
                ],
              );
            },
          ),
          if (ss.historyError != null && ss.history.isEmpty)
            MsAlert(
              tone: MsAlertTone.err,
              title: s.loadError,
              actions: [MsButton(label: s.retry, size: MsButtonSize.sm, onPressed: ss.loadHistory)],
            )
          else if (list.isEmpty)
            Padding(
              padding: EdgeInsets.all(PixelScope.of(context).d(12)),
              child: ss.historyLoading
                  ? MsText.small(s.loading, tone: MsTextTone.secondary)
                  : MsText.small(
                      ss.history.isEmpty ? s.empty : s.noMatch,
                      tone: MsTextTone.secondary,
                    ),
            )
          else
            MsList(
              semanticLabel: s.listLabel(sp.name),
              children: [
                for (final g in list)
                  GenerationRow(
                    gen: g,
                    isHead: g.n == sp.headN,
                    selected: identical(g, sel),
                    meta: listMeta([
                      g.author,
                      strings.fmt.when(app.localTime(g.ts), now),
                      strings.fmt.size(g.stats.size),
                    ]),
                    onTap: () => setState(() => _selected = g.n),
                  ),
              ],
            ),
          if (!ss.historyEnd && ss.history.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: MsButton(
                label: s.showOlder,
                variant: MsButtonVariant.ghost,
                size: MsButtonSize.sm,
                loading: ss.historyLoading,
                onPressed: () => ss.loadHistory(more: true),
              ),
            ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.space});
  final SpaceSummary space;

  @override
  Widget build(BuildContext context) {
    final s = context.s.history;
    // titolo e spiegazione sulla stessa riga, la spiegazione va sotto solo
    // se non c'è spazio
    return MsRow(
      gap: 16,
      children: [
        MsText.h2(s.title(space.name)),
        MsText(s.intro, tone: MsTextTone.secondary),
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    super.key,
    required this.space,
    required this.state,
    required this.gen,
    required this.tab,
    required this.onTab,
    required this.onNewer,
    required this.onOlder,
    this.scroll = false,
  });

  /// Alto quanto la colonna, con il contenuto che scorre dentro.
  final bool scroll;

  final SpaceSummary space;
  final SpaceState state;
  final GenerationSummary gen;
  final _DiffTab tab;
  final ValueChanged<_DiffTab> onTab;
  final VoidCallback? onNewer;
  final VoidCallback? onOlder;

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final strings = context.s;
    final s = strings.history;
    final sv = strings.server;
    final f = strings.fmt;
    final admin = app.me?.admin ?? false;
    final isHead = gen.n == space.headN;
    final free = space.lock == null || space.lock!.stale;
    // il ripristino si offre solo agli admin e mai per la versione attuale
    final canOffer = admin && !isHead;
    final title = sv.genTitle(
      kind: gen.kind.name,
      author: gen.author,
      message: gen.message,
      restoredFrom: gen.restoredFrom,
    );
    return MsPanel(
      scrollBody: scroll,
      raised: true,
      head: MsPanelHead(
        title: s.detailTitle,
        plain: true,
        leading: MsLevel('#${gen.n}'),
        actions: [
          MsTooltip(
            message: s.nextTip,
            child: MsButton.icon(
              icon: const RotatedBox(quarterTurns: 2, child: MsIcon(MsIcons.chevDown)),
              semanticLabel: s.next,
              variant: MsButtonVariant.ghost,
              size: MsButtonSize.sm,
              onPressed: onNewer,
            ),
          ),
          MsTooltip(
            message: s.prevTip,
            child: MsButton.icon(
              icon: const MsIcon(MsIcons.chevDown),
              semanticLabel: s.prev,
              variant: MsButtonVariant.ghost,
              size: MsButtonSize.sm,
              onPressed: onOlder,
            ),
          ),
        ],
      ),
      foot: [
        if (canOffer) ...[
          MsText.small(s.restoreQuestion(space.name), tone: MsTextTone.secondary),
          MsButton(
            label: s.restoreButton(gen.n),
            variant: MsButtonVariant.primary,
            icon: const MsIcon(MsIcons.history),
            onPressed: free && app.connection == Connection.online
                ? () => _restore(context, app)
                : null,
          ),
        ],
      ],
      child: MsStack(
        gap: 16,
        children: [
          // il messaggio della versione così com'è, non in maiuscolo come
          // l'etichetta della testata
          MsText.h3(title),
          // chi, quando, quanto e da dove in una riga sola
          MsRow(
            gap: 8,
            children: [
              MsAvatar(gen.author),
              MsText(gen.author, weight: 600),
              MsMeta([
                f.whenLong(app.localTime(gen.ts), app.now()),
                f.size(gen.stats.size),
                s.filesN(gen.stats.files),
                gen.parent > 0 ? s.fromN(gen.parent) : s.firstVersion,
              ]),
            ],
          ),
          FutureBuilder<GenerationDiff>(
            future: state.diff(gen.n),
            builder: (context, snap) => _diff(context, snap),
          ),
        ],
      ),
    );
  }

  Widget _diff(BuildContext context, AsyncSnapshot<GenerationDiff> snap) {
    final strings = context.s;
    final s = strings.history;
    if (snap.hasError) return MsText.small(s.diffError, tone: MsTextTone.err);
    final d = snap.data;
    if (d == null) return const MsSkeleton.text();
    final files = switch (tab) {
      _DiffTab.added => d.added,
      _DiffTab.changed => d.changed,
      _DiffTab.removed => d.removed,
    };
    final g = PixelScope.of(context);
    // filtro dentro un pannello: un selettore a segmenti come gli altri, le
    // schede grandi restano per la navigazione della pagina
    return MsStack(
      gap: 8,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: MsSegmented<_DiffTab>(
            semanticLabel: s.diffLabel(d.parent),
            value: tab,
            onChanged: onTab,
            segments: [
              MsSegment(value: _DiffTab.added, label: '${s.added} ${d.added.length}'),
              MsSegment(value: _DiffTab.changed, label: '${s.changed} ${d.changed.length}'),
              MsSegment(value: _DiffTab.removed, label: '${s.removed} ${d.removed.length}'),
            ],
          ),
        ),
        MsSlot(
          padding: EdgeInsets.fromLTRB(g.d(12), g.d(8), g.d(12), g.d(8)),
          child: MsStack(
            gap: 6,
            children: [
              if (files.isEmpty) MsText.small(s.noFiles, tone: MsTextTone.secondary),
              for (final (path, size) in files.take(_filesShown))
                Row(
                  spacing: g.d(12),
                  children: [
                    Expanded(child: MsText.mono(path, maxLines: 1)),
                    MsText.mono(strings.fmt.size(size), tone: MsTextTone.secondary),
                  ],
                ),
              if (files.length > _filesShown)
                MsText.small(s.andMore(files.length - _filesShown), tone: MsTextTone.secondary),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _restore(BuildContext context, AppState app) async {
    final strings = context.s;
    final s = strings.history;
    final next = space.headN + 1;
    final l = space.lock;
    final ok = await showMsDialog<bool>(
      context: context,
      builder: (ctx) => MsDialog(
        title: s.restoreTitle(gen.n),
        icon: const MsIcon(MsIcons.history),
        onDismiss: () => Navigator.of(ctx).pop(false),
        body: MsStack(
          children: [
            RichLine(s.restoreBody(n: gen.n, next: next, head: space.headN, who: gen.author)),
            MsFacts([MsFact(s.nextPlayer, s.nextPlayerValue)]),
            MsText.small(
              l == null ? s.lockFree(space.name) : s.lockBusy(space.name, l.name),
              tone: MsTextTone.secondary,
            ),
          ],
        ),
        actions: [
          MsButton(
            label: strings.server.cancel,
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          MsButton(
            label: s.restoreConfirm(next),
            variant: MsButtonVariant.primary,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final g = await app.restore(space.id, gen.n);
      if (context.mounted) toast(context, s.restored(gen.n, g.n));
      unawaited(state.loadHistory());
    } on Object catch (e) {
      if (context.mounted) {
        toast(context, s.restoreFailed, text: errorText(strings, e), tone: MsToastTone.err);
      }
    }
  }
}
