// Catalogo dei modpack nel passo «Da un modpack» della procedura Nuovo
// server, con le idee della scheda Modrinth di Prism Launcher (elenco subito,
// ricerca mentre si scrive, filtri, dettagli accanto) ma con i componenti
// pixel di MineSync: righe con icona, autore, descrizione, download, loader
// e versione; dettagli con descrizione in testo semplice, link aperti nel
// browser del sistema, scelta della versione e «Usa questo modpack»; poi il
// riepilogo con la divisione fra server e giocatori.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'common.dart' show Columns, textureFor;
import 'modpack_dialogs.dart' show loaderLabel;

/// Sopra questa larghezza (px logici) elenco e dettagli stanno affiancati.
const double packSplitWidth = 820;

/// Altezza dell'area del catalogo: quasi tutta la finestra, mai troppo bassa.
double _browserHeight(BuildContext context) =>
    (MediaQuery.sizeOf(context).height - 400).clamp(440.0, 1100.0);

// --- icona -----------------------------------------------------------------------------

/// Icona di un progetto Modrinth in uno slot incassato; senza icona (o se
/// non si legge) una texture pixel scelta dallo slug.
class PackIcon extends StatefulWidget {
  const PackIcon({super.key, required this.url, required this.seed, this.size = 48});

  final String? url;
  final String seed;

  /// Lato esterno in px di design.
  final double size;

  @override
  State<PackIcon> createState() => _PackIconState();
}

class _PackIconState extends State<PackIcon> {
  Uint8List? _bytes;
  String? _for;

  void _load(IconCache icons, String url) {
    if (_for == url) return;
    _for = url;
    _bytes = icons.peek(url);
    if (_bytes != null || icons.failed(url)) return;
    unawaited(
      icons.load(url).then((b) {
        if (mounted && _for == url && b != null) setState(() => _bytes = b);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final icons = AppStateScope.of(context).modpackEnv.icons;
    final url = widget.url;
    if (url == null) {
      _for = null;
      _bytes = null;
    } else {
      _load(icons, url);
    }
    final inner = g.d(widget.size - 8);
    final fallback = MsTexture(textureFor(widget.seed), width: inner, height: inner);
    final b = _bytes;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: g.d(widget.size),
        child: MsSlot(
          padding: const EdgeInsets.all(4),
          child: SizedBox.square(
            dimension: inner,
            child: b == null
                ? fallback
                : Image.memory(
                    b,
                    width: inner,
                    height: inner,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) {
                      if (url != null) icons.markFailed(url);
                      return fallback;
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

// --- catalogo ----------------------------------------------------------------------------

/// Ricerca, filtri, elenco e dettagli.
class PackBrowserView extends StatefulWidget {
  const PackBrowserView({super.key, required this.c});
  final NewServerController c;

  @override
  State<PackBrowserView> createState() => _PackBrowserViewState();
}

class _PackBrowserViewState extends State<PackBrowserView> {
  late final _q = TextEditingController(text: widget.c.browser.query);
  final _scroll = ScrollController();

  PackBrowser get b => widget.c.browser;

  @override
  void initState() {
    super.initState();
    b.open();
    _scroll.addListener(_maybeMore);
  }

  /// Scorrimento vicino al fondo: la pagina dopo.
  void _maybeMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 400 && b.hasMore && !b.loadingMore && b.moreError == null) {
      unawaited(b.loadMore());
    }
  }

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clearFilters() {
    _q.clear();
    b
      ..loader = null
      ..mcVersion = null
      ..query = '';
    unawaited(b.reload());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= packSplitWidth;
          final h = _browserHeight(context);
          final list = _list(context);
          // errore o elenco vuoto: tutta la larghezza, i dettagli non servono
          final full = b.error != null || (!b.loading && b.hits.isEmpty);
          final Widget area;
          if (full) {
            area = list;
          } else if (wide) {
            area = Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 1, child: list),
                const PixelGap(16, 0),
                Expanded(flex: 1, child: _Details(c: widget.c, narrow: false)),
              ],
            );
          } else {
            area = b.selected == null ? list : _Details(c: widget.c, narrow: true);
          }
          return MsStack(
            gap: 12,
            children: [
              _toolbar(context, box.maxWidth),
              SizedBox(height: h, child: area),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar(BuildContext context, double width) {
    final s = context.s.packBrowser;
    final search = MsField(
      label: s.search,
      child: MsTextInput(
        controller: _q,
        autofocus: true,
        placeholder: s.searchPlaceholder,
        semanticLabel: s.search,
        onChanged: b.setQuery,
        onSubmitted: b.searchNow,
      ),
    );
    final sort = MsField(
      label: s.sort,
      child: MsSelect<PackSort>(
        semanticLabel: s.sort,
        value: b.sort,
        options: [
          for (final o in PackSort.values) MsSelectOption(value: o, label: s.sortName(o.name)),
        ],
        onChanged: b.setSort,
      ),
    );
    final loader = MsField(
      label: s.loader,
      child: MsSelect<Loader?>(
        semanticLabel: s.loader,
        value: b.loader,
        options: [
          MsSelectOption<Loader?>(value: null, label: s.anyLoader),
          for (final l in packLoaders)
            MsSelectOption<Loader?>(value: l, label: loaderLabel(context, l)),
        ],
        onChanged: b.setLoader,
      ),
    );
    final mc = MsField(
      label: s.minecraft,
      child: MsSelect<String?>(
        semanticLabel: s.minecraft,
        value: b.mcVersion,
        options: [
          MsSelectOption<String?>(value: null, label: s.anyMc),
          for (final v in (b.mcVersions ?? const <String>[]).take(80))
            MsSelectOption<String?>(value: v, label: v),
        ],
        onChanged: b.setMcVersion,
      ),
    );
    final g = PixelScope.of(context);
    if (width >= packSplitWidth) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: g.d(12),
        children: [
          Expanded(child: search),
          SizedBox(width: g.d(220), child: sort),
          SizedBox(width: g.d(150), child: loader),
          SizedBox(width: g.d(130), child: mc),
        ],
      );
    }
    return MsStack(
      gap: 12,
      children: [
        search,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: g.d(12),
          children: [
            Expanded(flex: 3, child: sort),
            Expanded(flex: 2, child: loader),
            Expanded(flex: 2, child: mc),
          ],
        ),
      ],
    );
  }

  Widget _list(BuildContext context) {
    final s = context.s.packBrowser;
    if (b.error != null) {
      return Center(
        child: MsEmptyState(
          error: true,
          art: const MsArt(MsArts.crackedBlock),
          title: s.errorTitle,
          text: s.errorText,
          action: MsRow(
            gap: 8,
            children: [
              MsButton(
                label: s.retry,
                variant: MsButtonVariant.primary,
                icon: const MsIcon(MsIcons.refresh),
                onPressed: b.reload,
              ),
              MsButton(
                label: s.useFile,
                onPressed: () => widget.c.setPackSource(NsPackSource.file),
              ),
            ],
          ),
        ),
      );
    }
    if (!b.loading && b.hits.isEmpty) {
      final filtered = b.query.isNotEmpty || b.loader != null || b.mcVersion != null;
      return Center(
        child: MsEmptyState(
          art: const MsArt(MsArts.emptyIsland),
          title: s.emptyTitle,
          text: s.emptyText,
          action: filtered ? MsButton(label: s.clearFilters, onPressed: _clearFilters) : null,
        ),
      );
    }
    final g = PixelScope.of(context);
    final n = b.loading ? 6 : b.hits.length + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(bottom: g.d(8)),
          child: MsText.small(
            b.loading ? ' ' : s.results(b.total),
            tone: MsTextTone.secondary,
            tabular: true,
          ),
        ),
        Expanded(
          child: Semantics(
            label: s.listLabel,
            container: true,
            child: ListView.builder(
              controller: _scroll,
              // spazio per il lato estruso e il contorno di fuoco delle card
              padding: EdgeInsets.fromLTRB(g.d(4), g.d(4), g.d(8), g.d(8)),
              itemCount: n,
              itemBuilder: (context, i) {
                if (b.loading) return const _RowSkeleton();
                if (i == b.hits.length) return _footer(context);
                final h = b.hits[i];
                return Padding(
                  padding: EdgeInsets.only(bottom: g.d(12)),
                  child: PackRow(
                    hit: h,
                    selected: b.selected?.projectId == h.projectId,
                    onTap: () => unawaited(b.select(h)),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final s = context.s.packBrowser;
    if (b.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: MsSpinner()),
      );
    }
    if (b.moreError != null) {
      return MsRow(
        children: [
          MsText.small(s.moreError, tone: MsTextTone.err),
          MsButton(label: s.retry, size: MsButtonSize.sm, onPressed: b.loadMore),
        ],
      );
    }
    if (!b.hasMore) return const SizedBox.shrink();
    return Center(
      child: MsButton(label: s.loadMore, onPressed: b.loadMore),
    );
  }
}

/// Una riga del catalogo: icona, titolo, autore, descrizione breve,
/// download, loader e ultima versione di Minecraft.
class PackRow extends StatelessWidget {
  const PackRow({super.key, required this.hit, this.selected = false, this.onTap});

  final MrSearchHit hit;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.s.packBrowser;
    return MsCard(
      selected: selected,
      onTap: onTap,
      semanticLabel: hit.title,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PackIcon(url: hit.iconUrl, seed: hit.slug, size: 56),
          const PixelGap(12, 0),
          Expanded(
            child: MsStack(
              gap: 4,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: MsText.rich([
                        MsSpan(hit.title, strong: true),
                        if (hit.author.isNotEmpty) MsSpan('  ${s.by(hit.author)}'),
                      ], maxLines: 1),
                    ),
                    if (hit.serverSide == MrEnv.unsupported) ...[
                      const PixelGap(8, 0),
                      MsChip(s.clientOnlyChip, tone: MsChipTone.accent),
                    ],
                  ],
                ),
                if (hit.description.isNotEmpty)
                  MsText.small(
                    decodeHtmlEntities(hit.description),
                    tone: MsTextTone.secondary,
                    maxLines: 2,
                  ),
                packMeta(context, hit),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Riga dei dati di un modpack: download, loader, ultima versione di
/// Minecraft e «solo giocatori».
Widget packMeta(BuildContext context, MrSearchHit hit) {
  final s = context.s.packBrowser;
  final mc = latestMc(hit.gameVersions);
  final parts = [
    s.downloads(hit.downloads),
    for (final l in hitLoaders(hit)) loaderLabel(context, l),
    if (mc != null) 'Minecraft $mc',
  ];
  return MsMeta(parts);
}

class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: g.d(12)),
      child: MsCard(
        kind: MsCardKind.static,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox.square(dimension: g.d(56), child: const MsSkeleton(height: 56)),
            const PixelGap(12, 0),
            const Expanded(
              child: MsStack(
                gap: 8,
                children: [
                  MsSkeleton(widthFactor: .5, height: 16),
                  MsSkeleton(height: 12),
                  MsSkeleton(widthFactor: .7, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- dettagli ------------------------------------------------------------------------------

class _Details extends StatelessWidget {
  const _Details({required this.c, required this.narrow});
  final NewServerController c;
  final bool narrow;

  PackBrowser get b => c.browser;

  @override
  Widget build(BuildContext context) {
    final s = context.s.packBrowser;
    final h = b.selected;
    final g = PixelScope.of(context);
    final Widget body;
    if (h == null) {
      // vuoto compatto in alto, non un'illustrazione a metà altezza
      body = Align(
        alignment: Alignment.topLeft,
        child: Row(
          children: [
            const MsIcon(MsIcons.mods),
            const PixelGap(12, 0),
            Expanded(child: MsText(s.pickHint, tone: MsTextTone.secondary)),
          ],
        ),
      );
    } else {
      body = SingleChildScrollView(
        padding: EdgeInsets.all(g.d(4)),
        child: _detailsBody(context, h),
      );
    }
    return MsSlot(
      padding: const EdgeInsets.all(16),
      child: SizedBox.expand(child: body),
    );
  }

  Widget _detailsBody(BuildContext context, MrSearchHit h) {
    final s = context.s.packBrowser;
    final app = AppStateScope.of(context);
    final p = b.project;
    final open = app.modpackEnv.tools.openUrl;
    final text = p == null ? null : _plain(p.body);
    final links = <(String, String)>[
      (s.openPage, p?.pageUrl ?? h.pageUrl),
      if (p?.sourceUrl case final u?) (s.source, u),
      if (p?.issuesUrl case final u?) (s.issues, u),
      if (p?.wikiUrl case final u?) (s.wiki, u),
      if (p?.discordUrl case final u?) (s.discord, u),
      for (final l in (text?.links ?? const <MdLink>[]).take(8))
        (l.text.length > 40 ? '${l.text.substring(0, 39)}…' : l.text, l.url),
    ];
    return MsStack(
      gap: 16,
      children: [
        if (narrow)
          Align(
            alignment: Alignment.centerLeft,
            child: MsButton(
              label: s.backToList,
              variant: MsButtonVariant.ghost,
              size: MsButtonSize.sm,
              onPressed: b.clearSelection,
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PackIcon(url: h.iconUrl, seed: h.slug, size: 72),
            const PixelGap(16, 0),
            Expanded(
              child: MsStack(
                gap: 6,
                children: [
                  MsText.h3(h.title, maxLines: 2),
                  if (h.author.isNotEmpty) MsText.small(s.by(h.author), tone: MsTextTone.secondary),
                  packMeta(context, h),
                ],
              ),
            ),
          ],
        ),
        if (b.projectError != null && b.versionsError != null)
          MsAlert(
            title: s.detailsError,
            tone: MsAlertTone.err,
            actions: [MsButton(label: s.retry, size: MsButtonSize.sm, onPressed: b.retryDetails)],
          )
        else
          _versionPicker(context),
        if (c.importError != null)
          MsAlert(
            title: context.s.newServer.importError,
            text: '${c.importError}',
            tone: MsAlertTone.err,
          ),
        if (c.importing)
          ValueListenableBuilder(
            valueListenable: c.packProgress,
            builder: (context, v, _) {
              final (got, total) = v ?? (0, 0);
              final fmt = context.s.fmt;
              return MsStack(
                gap: 4,
                children: [
                  MsProgress(value: total > 0 ? (got / total).clamp(0.0, 1.0) : null),
                  MsText.small(
                    total > 0
                        ? s.downloading(fmt.size(got), fmt.size(total))
                        : s.downloading(null, null),
                    tone: MsTextTone.secondary,
                    tabular: true,
                  ),
                ],
              );
            },
          ),
        if (h.serverSide == MrEnv.unsupported)
          MsAlert(
            title: s.clientOnlyChip,
            text: s.clientOnlyNote,
            icon: const MsIcon(MsIcons.players),
          ),
        if (h.description.isNotEmpty) MsText(decodeHtmlEntities(h.description)),
        if (b.detailsLoading && b.projectError == null)
          const MsStack(
            gap: 8,
            children: [
              MsSkeleton(height: 14),
              MsSkeleton(height: 14),
              MsSkeleton(widthFactor: .6, height: 14),
            ],
          )
        else if (text != null)
          _Description(text: text),
        MsRow(
          gap: 8,
          children: [
            for (final (label, url) in links)
              MsButton(
                label: label,
                size: MsButtonSize.sm,
                variant: MsButtonVariant.ghost,
                icon: const MsIcon(MsIcons.globe),
                onPressed: () => unawaited(open(url)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _versionPicker(BuildContext context) {
    final s = context.s.packBrowser;
    final vs = b.versions;
    if (vs == null) return const MsSkeleton(height: 40);
    if (b.versionsError != null && b.projectError == null) {
      return MsAlert(
        title: s.versionsError,
        tone: MsAlertTone.err,
        actions: [MsButton(label: s.retry, size: MsButtonSize.sm, onPressed: b.retryDetails)],
      );
    }
    if (vs.isEmpty) return MsAlert(title: s.noVersions, tone: MsAlertTone.warn);
    final visible = b.visibleVersions;
    return MsStack(
      gap: 12,
      children: [
        MsField(
          label: s.version,
          child: MsSelect<String>(
            semanticLabel: s.version,
            value: b.version?.id,
            options: [
              for (final v in visible)
                MsSelectOption(value: v.id, label: _versionLabel(context, v)),
            ],
            onChanged: c.importing
                ? null
                : (id) => b.chooseVersion(visible.firstWhere((v) => v.id == id)),
          ),
        ),
        MsSwitch(value: b.showBeta, label: s.showBeta, onChanged: b.setShowBeta),
        MsButton(
          label: s.use,
          variant: MsButtonVariant.primary,
          block: true,
          icon: const MsIcon(MsIcons.check),
          loading: c.importing,
          onPressed: b.version == null || c.importing ? null : c.usePack,
        ),
      ],
    );
  }

  String _versionLabel(BuildContext context, MrVersion v) {
    final s = context.s.packBrowser;
    final loaders = [
      for (final l in packLoaders)
        if (v.loaders.contains(mrLoader(l))) loaderLabel(context, l),
    ].join(', ');
    return s.versionOption(
      v.versionNumber.isEmpty ? v.name : v.versionNumber,
      latestMc(v.gameVersions) ?? '?',
      loaders,
      v.versionType == MrVersionType.release ? null : v.versionType.name,
    );
  }
}

/// La descrizione lunga in testo semplice.
class _Description extends StatelessWidget {
  const _Description({required this.text});
  final PlainText text;

  @override
  Widget build(BuildContext context) {
    final s = context.s.packBrowser;
    if (text.isEmpty) return MsText.small(s.noDescription, tone: MsTextTone.secondary);
    return MsStack(
      gap: 8,
      children: [
        for (final b in text.blocks)
          switch (b.kind) {
            MdBlockKind.heading => Padding(
              padding: EdgeInsets.only(top: PixelScope.of(context).d(8)),
              child: MsText(b.text, weight: 700),
            ),
            MdBlockKind.bullet => MsText('•  ${b.text}', tone: MsTextTone.secondary),
            MdBlockKind.paragraph => MsText(b.text, tone: MsTextTone.secondary),
          },
      ],
    );
  }
}

// --- riepilogo -------------------------------------------------------------------------------

/// Il modpack scelto, le sue basi e la divisione fra server e giocatori.
class PackSummary extends StatefulWidget {
  const PackSummary({super.key, required this.c, this.initiallyOpen = false});
  final NewServerController c;

  /// Elenco delle mod già aperto (per le anteprime).
  final bool initiallyOpen;

  @override
  State<PackSummary> createState() => _PackSummaryState();
}

class _PackSummaryState extends State<PackSummary> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final s = context.s.packBrowser;
    final ns = context.s.newServer;
    final c = widget.c;
    final imp = c.imported!;
    final sp = c.split;
    final h = c.packChosen;
    final v = c.packVersion;
    final ex = c.excludedUnknown;
    final base = [
      v?.versionNumber ?? imp.index.versionId,
      [loaderLabel(context, imp.pack.loader), ?imp.pack.loaderVersion].join(' '),
      'Minecraft ${imp.pack.mcVersion}',
    ];
    return MsStack(
      gap: 16,
      children: [
        MsCard(
          kind: MsCardKind.static,
          child: Row(
            children: [
              PackIcon(url: h?.iconUrl, seed: h?.slug ?? imp.index.name, size: 64),
              const PixelGap(16, 0),
              Expanded(
                child: MsStack(
                  gap: 4,
                  children: [
                    MsText.label(s.chosenTitle, tone: MsTextTone.secondary),
                    MsText.h3(h?.title ?? imp.index.name, maxLines: 1),
                    MsMeta(base),
                  ],
                ),
              ),
              const PixelGap(16, 0),
              MsButton(
                label: s.change,
                icon: const MsIcon(MsIcons.refresh),
                onPressed: c.changePack,
              ),
            ],
          ),
        ),
        if (sp == null)
          MsFacts([MsFact(ns.mods, '${imp.pack.mods.length}')])
        else ...[
          MsAlert(
            title: s.splitTitle(sp.serverCount(ex), sp.clientCount(ex)),
            text: c.packClientOnly ? s.splitWhyClientOnly : s.splitWhy,
            icon: const MsIcon(MsIcons.mods),
            tone: MsAlertTone.info,
            actions: [
              MsButton(
                label: _open ? s.hideList : s.showList,
                size: MsButtonSize.sm,
                icon: MsIcon(_open ? MsIcons.chevDown : MsIcons.chev),
                onPressed: () => setState(() => _open = !_open),
              ),
            ],
          ),
          if (_open)
            Columns(
              minWidth: 300,
              children: [
                (1, _side(context, s.onServer, sp.onServer)),
                (1, _side(context, s.clientOnly, sp.clientOnly)),
              ],
            ),
          if (sp.unknown.isNotEmpty) ...[
            MsAlert(
              title: s.unknownTitle(sp.unknown.length),
              text: s.unknownText,
              tone: MsAlertTone.warn,
            ),
            MsList(
              children: [
                for (final e in sp.unknown)
                  MsListRow(
                    title: e.name,
                    meta: e.name == e.mod.file ? null : e.mod.file,
                    trail: MsCheckbox(
                      value: !ex.contains(e.key),
                      label: s.keepOnServer,
                      semanticLabel: '${s.keepOnServer}: ${e.name}',
                      onChanged: (on) => c.keepUnknownOnServer(e.key, on),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  Widget _side(BuildContext context, String title, List<SplitEntry> list) {
    final s = context.s.packBrowser;
    return MsStack(
      gap: 8,
      children: [
        MsText('$title (${list.length})', weight: 700),
        MsList(
          children: [for (final e in list) MsListRow(title: e.name, meta: s.reason(e.reason.name))],
        ),
      ],
    );
  }
}

// la descrizione di un modpack può essere lunga: si legge una volta sola,
// non a ogni ricostruzione del wizard
String? _plainKey;
PlainText? _plainValue;

PlainText _plain(String body) {
  if (body != _plainKey || _plainValue == null) {
    _plainKey = body;
    _plainValue = plainMarkdown(body);
  }
  return _plainValue!;
}
