// Scheda Mod: riepilogo (quante, quanto pesano, loader, senza metadati),
// elenco con icona del jar (o l'icona predefinita), ricerca, ordinamento e
// filtri, dettaglio con versione, loader, autori, descrizione, sito (solo
// http/https, aperto in una scheda nuova), licenza; oppure "nessun metadato".
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../api/pack_file.dart';
import '../../l10n/l10n.dart';
import '../../state/hub_state.dart';
import '../../widgets/lock_view.dart';
import '../../widgets/page.dart';
import 'pack_card.dart';
import 'server_data.dart';

enum ModSort { name, size, recent }

enum ModFilter { all, meta, bare, changed }

/// Il sito di una mod se è un URL http/https valido (B-META-05: l'hub li
/// filtra già, qui si ricontrolla prima di aprirlo).
Uri? safeHomepage(String? raw) {
  if (raw == null) return null;
  final u = Uri.tryParse(raw.trim());
  if (u == null || !u.hasAuthority || u.host.isEmpty) return null;
  return u.scheme == 'http' || u.scheme == 'https' ? u : null;
}

String modTitle(ModInfo m) => m.name ?? m.file.replaceAll(RegExp(r'\.jar$'), '');

class ModsTab extends StatefulWidget {
  const ModsTab({super.key, required this.space});
  final SpaceSummary space;

  @override
  State<ModsTab> createState() => _ModsTabState();
}

class _ModsTabState extends State<ModsTab> {
  late Future<ModList> _list;
  late Future<(ClientPack, PackFile?)> _pack;
  final _query = TextEditingController();
  var _sort = ModSort.name;
  var _filter = ModFilter.all;
  String? _selected;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _load();
    _query.addListener(() => setState(() {}));
  }

  void _load() {
    final api = HubStateScope.read(context).api;
    _list = api.mods(widget.space.id);
    _pack = () async {
      final p = await api.pack(widget.space.id);
      // il file del pack serve solo per il lato di ogni mod
      final file = p.available
          ? await api.packFile(widget.space.id).catchError((Object _) => null)
          : null;
      return (p, file);
    }();
  }

  @override
  void didUpdateWidget(ModsTab old) {
    super.didUpdateWidget(old);
    if (old.space.headDigest != widget.space.headDigest) setState(_load);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<(ClientPack, PackFile?)>(
    future: _pack,
    builder: (context, pack) => FutureBuilder<ModList>(
      future: _list,
      builder: (context, snap) {
        if (!snap.hasData) return LoadState(error: snap.error, onRetry: () => setState(_load));
        return MsStack(
          gap: 24,
          children: [
            if (pack.data case (final p, _)) PackCard(space: widget.space, pack: p),
            if (pack.hasError) MsText.small(context.s.pack.loadError, tone: MsTextTone.secondary),
            _body(context, snap.data!, pack.data?.$2),
          ],
        );
      },
    ),
  );

  bool _matches(ModInfo m, String q) =>
      q.isEmpty ||
      m.file.toLowerCase().contains(q) ||
      (m.name?.toLowerCase().contains(q) ?? false) ||
      m.authors.any((a) => a.toLowerCase().contains(q));

  Widget _body(BuildContext context, ModList list, PackFile? packFile) {
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final mods = list.mods;
    if (mods.isEmpty) {
      return MsPanel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(24)),
          child: MsEmptyState(
            title: v.noModsTitle,
            text: v.noModsText,
            art: const MsIcon(MsIcons.mods, size: 32),
          ),
        ),
      );
    }
    final byFile = packFile?.byFile ?? const <String, PackEntry>{};
    final bare = mods.where((m) => m.bare).length;
    final changed = mods.where((m) => m.changed).length;
    final q = _query.text.trim().toLowerCase();
    final shown =
        mods
            .where((m) => _matches(m, q))
            .where(
              (m) => switch (_filter) {
                ModFilter.all => true,
                ModFilter.meta => !m.bare,
                ModFilter.bare => m.bare,
                ModFilter.changed => m.changed,
              },
            )
            .toList()
          ..sort(
            (a, b) => switch (_sort) {
              ModSort.name => modTitle(a).toLowerCase().compareTo(modTitle(b).toLowerCase()),
              ModSort.size => b.size.compareTo(a.size),
              ModSort.recent => (b.since ?? 0).compareTo(a.since ?? 0),
            },
          );
    final sel = _closed
        ? null
        : mods.where((m) => m.file == _selected).firstOrNull ?? shown.firstOrNull;
    final lo = list.chip.loader;
    final summary = MsPanel(
      child: AutoGrid(
        minWidth: 180,
        gap: 20,
        children: [
          MsStat(value: '${mods.length}', label: v.modsLabel, icon: const MsIcon(MsIcons.mods)),
          MsStat(value: f.size(list.bytes), label: v.modsTotal, icon: const MsIcon(MsIcons.disk)),
          MsStat(
            value: lo == null ? '—' : loaderName(lo),
            label: v.loaderLabel(list.chip.loaderVersion),
            icon: const MsIcon(MsIcons.gear),
          ),
          MsStat(
            value: '$bare',
            label: v.bareLabel,
            icon: const MsIcon(MsIcons.info),
            iconTone: bare > 0 ? MsTextTone.warn : MsTextTone.accent,
          ),
        ],
      ),
    );
    final listPart = MsStack(
      gap: 12,
      children: [
        MsRow(
          gap: 12,
          children: [
            SizedBox(
              width: PixelScope.of(context).d(280),
              child: MsTextInput(
                controller: _query,
                placeholder: v.searchMods,
                semanticLabel: v.searchModsLabel,
              ),
            ),
            SizedBox(
              width: PixelScope.of(context).d(200),
              child: MsSelect<ModSort>(
                semanticLabel: v.sortMods,
                value: _sort,
                options: [
                  for (final k in ModSort.values)
                    MsSelectOption(
                      value: k,
                      label: switch (k) {
                        ModSort.name => v.sortName,
                        ModSort.size => v.sortSize,
                        ModSort.recent => v.sortRecent,
                      },
                    ),
                ],
                onChanged: (k) => setState(() => _sort = k),
              ),
            ),
          ],
        ),
        MsRow(
          gap: 8,
          children: [
            for (final (k, n) in [
              (ModFilter.all, mods.length),
              (ModFilter.meta, mods.length - bare),
              (ModFilter.bare, bare),
              if (changed > 0) (ModFilter.changed, changed),
            ])
              MsChip(
                switch (k) {
                  ModFilter.all => v.filterAll(n),
                  ModFilter.meta => v.filterMeta(n),
                  ModFilter.bare => v.filterBare(n),
                  ModFilter.changed => v.filterChanged(s.fmt.gen(list.n), n),
                },
                tone: _filter == k ? MsChipTone.accent : MsChipTone.neutral,
                onTap: () => setState(() => _filter = k),
              ),
          ],
        ),
        if (shown.isEmpty)
          MsText(v.noMatch, tone: MsTextTone.secondary)
        else
          MsList(
            semanticLabel: v.modsListLabel,
            children: [
              for (final m in shown)
                MsListRow(
                  lead: ModIcon(space: widget.space.id, mod: m, size: 28),
                  title: modTitle(m),
                  meta: m.bare
                      ? listMeta([m.file, v.noMetaShort])
                      : listMeta([if (m.version != null) 'v${m.version}', m.file]),
                  trail: MsRow(
                    gap: 8,
                    wrap: false,
                    children: [
                      if (byFile[m.file.toLowerCase()] case final e?)
                        MsChip(
                          e.disabled
                              ? s.pack.disabled
                              : e.optional
                              ? '${s.pack.side(e.side)} (${s.pack.optional})'
                              : s.pack.side(e.side),
                        ),
                      MsText.mono(f.size(m.size), tone: MsTextTone.secondary),
                    ],
                  ),
                  selected: sel?.file == m.file,
                  semanticLabel: modTitle(m),
                  onTap: () => setState(() {
                    _selected = m.file;
                    _closed = false;
                  }),
                ),
            ],
          ),
        if (shown.length != mods.length)
          MsText.small(v.shownOf(shown.length, mods.length), tone: MsTextTone.secondary),
      ],
    );
    final detail = sel == null
        ? null
        : ModDetail(
            key: ValueKey(sel.file),
            space: widget.space.id,
            mod: sel,
            onClose: () => setState(() => _closed = true),
          );
    return MsStack(
      gap: 24,
      children: [
        summary,
        Columns(minWidth: 360, children: [(3, listPart), if (detail != null) (2, detail)]),
      ],
    );
  }
}

/// Icona del jar (dall'hub) o l'icona predefinita delle mod.
class ModIcon extends StatelessWidget {
  const ModIcon({super.key, required this.space, required this.mod, this.size = 32});

  final String space;
  final ModInfo mod;
  final double size;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final g = PixelScope.of(context);
    final fallback = MsIcon(MsIcons.mods, size: size - 8);
    final img = mod.icon ? app.platform.networkImage(app.api.modIconUrl(space, mod.file)) : null;
    return SizedBox(
      width: g.d(size),
      height: g.d(size),
      child: MsSlot.square(
        side: size,
        child: Center(
          child: img == null
              ? fallback
              : Image(
                  image: img,
                  width: g.d(size - 8),
                  height: g.d(size - 8),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.none,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}

class ModDetail extends StatelessWidget {
  const ModDetail({super.key, required this.space, required this.mod, required this.onClose});

  final String space;
  final ModInfo mod;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.server;
    final f = s.fmt;
    final m = mod;
    final site = safeHomepage(m.homepage);
    final present = m.since == null
        ? null
        : [
            f.gen(m.since!),
            if (m.updated != null && m.updated != m.since) v.updatedIn(f.gen(m.updated!)),
          ].join(', ');
    final hash = m.h.length > 8 ? '${m.h.substring(0, 4)}…${m.h.substring(m.h.length - 4)}' : m.h;
    final Widget body;
    if (m.bare) {
      body = MsStack(
        gap: 16,
        children: [
          Row(
            children: [
              ModIcon(space: space, mod: m, size: 48),
              const PixelGap(12, 0),
              Expanded(
                child: MsStack(
                  gap: 6,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h3(m.file),
                    MsRow(
                      gap: 6,
                      children: [
                        MsChip(f.size(m.size)),
                        if (m.since != null) MsChip(v.sinceGen(f.gen(m.since!))),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          MsEmptyState(title: v.noMetaTitle, text: v.noMetaText),
          MsFacts([
            MsFact(v.file, 'mods/${m.file}', child: MsText.mono('mods/${m.file}', weight: 600)),
            MsFact('SHA-256', hash, child: MsText.mono(hash, weight: 600)),
          ]),
        ],
      );
    } else {
      body = MsStack(
        gap: 16,
        children: [
          Row(
            children: [
              ModIcon(space: space, mod: m, size: 48),
              const PixelGap(12, 0),
              Expanded(
                child: MsStack(
                  gap: 6,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h3(modTitle(m)),
                    MsRow(
                      gap: 6,
                      children: [
                        if (m.version != null) MsChip('v${m.version}', tone: MsChipTone.accent),
                        if (m.loader != null) MsChip(loaderName(m.loader!)),
                        if (m.mcVersion != null) MsChip('MC ${m.mcVersion}'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (m.description != null) MsText(m.description!),
          MsFacts([
            if (m.authors.isNotEmpty) MsFact(v.authors, m.authors.join(', ')),
            if (site != null)
              MsFact(
                v.site,
                site.toString(),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: MsButton(
                    label: site.host,
                    size: MsButtonSize.sm,
                    variant: MsButtonVariant.ghost,
                    icon: const MsIcon(MsIcons.globe),
                    semanticLabel: v.openSite(site.host),
                    onPressed: () => app.platform.openExternal(site),
                  ),
                ),
              ),
            if (m.license != null) MsFact(v.license, m.license!),
            MsFact(v.file, m.file, child: MsText.mono(m.file, weight: 600)),
            MsFact(v.size, f.size(m.size)),
            if (present != null) MsFact(v.presentSince, present),
          ]),
          MsSlot(child: MsText.small(v.modNote, tone: MsTextTone.secondary)),
        ],
      );
    }
    return MsPanel(
      title: v.detailTitle,
      semanticLabel: v.detailOf(modTitle(m)),
      actions: [
        MsButton.icon(
          icon: const MsIcon(MsIcons.x),
          semanticLabel: v.closeDetail,
          size: MsButtonSize.sm,
          variant: MsButtonVariant.ghost,
          onPressed: onClose,
        ),
      ],
      child: body,
    );
  }
}
