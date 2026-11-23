// Procedura «Nuovo server» a passi (solo admin): prima l'origine, poi nome
// e versione e tipo di server, o modpack, o cartella; mod consigliate,
// EULA con un clic, creazione con l'esito di ogni passo, errori con
// «Riprova» dal passo fallito. Avanti spento dice sempre cosa manca. La
// strada «Da una cartella» carica la cartella del server così com'è.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'modpack_dialogs.dart' show loaderLabel;
import 'pack_browser.dart';

/// Testo dell'EULA di Mojang.
const eulaUrl = 'https://aka.ms/MinecraftEULA';

class NewServerScreen extends StatelessWidget {
  const NewServerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final s = context.s.newServer;
    if (!(app.me?.admin ?? false)) {
      return ScreenBody(
        children: [MsAlert(title: s.adminOnly, tone: MsAlertTone.warn)],
      );
    }
    final c = app.newServer;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => ScreenBody(
        children: [
          MsText.h1(s.title),
          _Steps(c: c),
          switch (c.step) {
            NsStep.origin => _Origin(c: c),
            NsStep.version => _Version(c: c),
            NsStep.modpack => _Modpack(c: c),
            NsStep.folder => _Folder(c: c),
            NsStep.mods => _Mods(c: c),
            NsStep.eula => _Eula(c: c),
            NsStep.create => _Create(c: c),
          },
        ],
      ),
    );
  }
}

/// Chiude la procedura e torna a [to] (Home se null).
Future<void> _leave(BuildContext context, NewServerController c, [AppRoute? to]) async {
  final app = AppStateScope.read(context);
  await c.abandon();
  app
    ..resetNewServer()
    ..go(to ?? const HomeRoute());
}

class _Steps extends StatelessWidget {
  const _Steps({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final steps = c.steps;
    // creazione: tutti i passi fatti
    final at = c.step == NsStep.create ? steps.length : steps.indexOf(c.step);
    return MsSteps(
      semanticLabel: s.stepsLabel,
      positionLabel: s.stepOf,
      current: at,
      steps: [for (final st in steps) MsStep(s.step(st.name), skipped: c.skipped(st))],
    );
  }
}

/// Piede dei passi: Annulla o Indietro, Avanti; con Avanti spento, accanto,
/// [why] dice cosa manca.
class _Nav extends StatelessWidget {
  const _Nav({required this.c, this.next, this.nextLabel, this.why, this.extra = const []});
  final NewServerController c;
  final VoidCallback? next;
  final String? nextLabel;
  final String? why;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    return MsRow(
      gap: 12,
      children: [
        if (c.step == NsStep.origin)
          MsButton(label: s.cancel, onPressed: () => _leave(context, c))
        else
          MsButton(label: s.back, onPressed: c.back),
        ...extra,
        if (next == null && why != null) MsText.small(why!, tone: MsTextTone.secondary),
        MsButton(label: nextLabel ?? s.next, variant: MsButtonVariant.primary, onPressed: next),
      ],
    );
  }
}

/// Il nome del server, nel passo dopo l'origine. Segue [NewServerController.name]
/// quando lo propone la procedura (titolo del modpack, nome della cartella).
class _NameField extends StatefulWidget {
  const _NameField({required this.c, this.onSubmitted, this.autofocus = false});
  final NewServerController c;
  final VoidCallback? onSubmitted;
  final bool autofocus;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _name = TextEditingController(text: widget.c.name);

  @override
  void didUpdateWidget(_NameField old) {
    super.didUpdateWidget(old);
    if (_name.text != widget.c.name) _name.text = widget.c.name;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MsField(
      label: context.s.newServer.name,
      child: MsTextInput(
        controller: _name,
        autofocus: widget.autofocus,
        maxLength: nsMaxName,
        onChanged: widget.c.setName,
        onSubmitted: (_) => widget.onSubmitted?.call(),
      ),
    );
  }
}

/// Perché Avanti è spento per Java: lo cerco ancora, o manca.
String? _javaWhy(BuildContext context, NewServerController c) {
  if (c.javaOk) return null;
  final s = context.s.newServer;
  return c.javas == null ? s.javaSearching : s.needJava(c.javaNeeded);
}

// --- 1 · origine -------------------------------------------------------------------

class _Origin extends StatelessWidget {
  const _Origin({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    Widget card(NsOrigin o, String title, String text, MsIconData icon) => MsCard(
      selected: c.origin == o,
      semanticLabel: title,
      onTap: () => c.setOrigin(o),
      child: MsStack(
        gap: 8,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsIcon(icon, size: 24),
          MsText(title, weight: 700),
          MsText.small(text, tone: MsTextTone.secondary),
        ],
      ),
    );
    return MsPanel(
      title: s.originTitle,
      foot: [_Nav(c: c, next: c.next)],
      child: MsStack(
        children: [
          MsText.small(s.originIntro, tone: MsTextTone.secondary),
          // tre scelte a tutta larghezza, alte uguali
          Columns(
            minWidth: 220,
            gap: 16,
            children: [
              (1, card(NsOrigin.scratch, s.scratch, s.scratchText, MsIcons.plus)),
              (1, card(NsOrigin.modpack, s.modpack, s.modpackText, MsIcons.mods)),
              (1, card(NsOrigin.folder, s.folder, s.folderText, MsIcons.folder)),
            ],
          ),
        ],
      ),
    );
  }
}

// --- 2 · versione e loader -------------------------------------------------------------

Widget _javaAlert(BuildContext context, NewServerController c) {
  final s = context.s.newServer;
  final mc = c.targetMc;
  final need = c.javaNeeded;
  if (mc == null || need == 0) return const SizedBox.shrink();
  if (c.javas == null) return MsRow(children: [const MsSpinner(), MsText.small(s.javaSearching)]);
  final j = c.java;
  if (c.javaOk) {
    return MsAlert(
      title: s.javaOk(need),
      text: s.javaOkText(mc, need, 'Java ${j?.version ?? need}'),
      icon: const MsIcon(MsIcons.java),
      tone: MsAlertTone.ok,
    );
  }
  final app = AppStateScope.of(context);
  return MsAlert(
    title: s.javaMissing(need),
    text: s.javaMissingText(mc, need, j == null ? '' : 'Java ${j.version}'),
    icon: const MsIcon(MsIcons.java),
    tone: MsAlertTone.warn,
    actions: [
      MsButton(
        label: s.javaHow,
        size: MsButtonSize.sm,
        icon: const MsIcon(MsIcons.globe),
        onPressed: () => unawaited(app.modpackEnv.tools.openUrl(temurinUrl(need))),
      ),
      MsButton(
        label: s.javaRescan,
        size: MsButtonSize.sm,
        icon: const MsIcon(MsIcons.refresh),
        loading: c.javaLoading,
        onPressed: c.javaLoading ? null : c.findJava,
      ),
    ],
  );
}

class _Version extends StatelessWidget {
  const _Version({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final versions = c.mcVersions;
    final lvs = c.loaderVersionList;
    final why = c.nameError != null
        ? s.needName
        : c.mc == null
        ? s.needVersion
        : c.loader != Loader.vanilla && c.loaderVersion == null
        ? (lvs == null ? s.wait : s.needLoader(loaderLabel(context, c.loader)))
        : _javaWhy(context, c);
    final next = why == null ? c.next : null;
    return MsPanel(
      title: s.versionTitle,
      foot: [_Nav(c: c, next: next, why: why)],
      child: MsStack(
        children: [
          _NameField(c: c, autofocus: true, onSubmitted: next),
          if (c.versionError != null) MsAlert(title: s.versionsError, tone: MsAlertTone.warn),
          Columns(
            minWidth: 300,
            children: [
              (
                1,
                MsStack(
                  children: [
                    MsField(
                      label: s.minecraft,
                      help: s.popular,
                      child: versions == null
                          ? const MsSkeleton(height: 40)
                          : MsSelect<String>(
                              semanticLabel: s.minecraft,
                              value: c.mc,
                              options: [
                                for (final (i, v) in versions.take(60).indexed)
                                  MsSelectOption(value: v, label: i == 0 ? s.latest(v) : v),
                              ],
                              onChanged: c.setMc,
                            ),
                    ),
                    MsSwitch(
                      value: c.releasesOnly,
                      label: s.releasesOnly,
                      onChanged: (v) {
                        c.releasesOnly = v;
                        unawaited(c.loadMcVersions());
                      },
                    ),
                    MsField(
                      label: '${s.memory} (${s.gb(c.memoryGb)})',
                      help: s.memoryHint,
                      child: MsSlider(
                        value: c.memoryGb.toDouble(),
                        min: 2,
                        max: 16,
                        step: 1,
                        semanticLabel: s.memory,
                        semanticFormatter: (v) => s.gb(v.round()),
                        onChanged: (v) {
                          c.memoryGb = v.round();
                          c.go(NsStep.version);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              (
                1,
                MsField(
                  label: s.loader,
                  child: MsRadioGroup<Loader>(
                    semanticLabel: s.loader,
                    value: c.loader,
                    options: [
                      for (final l in [
                        Loader.vanilla,
                        Loader.fabric,
                        Loader.quilt,
                        Loader.neoforge,
                        Loader.forge,
                      ])
                        MsRadioOption(
                          value: l,
                          title: l == Loader.vanilla ? s.vanillaTitle : loaderLabel(context, l),
                          description: [
                            s.loaderText(l.name),
                            if (l == c.loader && l != Loader.vanilla)
                              lvs == null
                                  ? '…'
                                  : c.loaderVersion == null
                                  ? s.noLoaderVersions
                                  : s.recommendedVersion(c.loaderVersion!),
                          ].join(' '),
                        ),
                    ],
                    onChanged: c.setLoader,
                  ),
                ),
              ),
            ],
          ),
          _javaAlert(context, c),
        ],
      ),
    );
  }
}

// --- 2b · modpack -------------------------------------------------------------------------

class _Modpack extends StatelessWidget {
  const _Modpack({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final pb = context.s.packBrowser;
    final imp = c.imported;
    final why = imp == null || c.importing
        ? (c.importing ? s.wait : s.needPack)
        : c.nameError != null
        ? s.needName
        : _javaWhy(context, c);
    final next = why == null ? c.next : null;
    return MsPanel(
      title: s.modpackTitle,
      foot: [_Nav(c: c, next: next, why: why)],
      child: MsStack(
        children: [
          if (imp == null) ...[
            MsSegmented<NsPackSource>(
              semanticLabel: pb.sourceLabel,
              value: c.packSource,
              segments: [
                MsSegment(
                  value: NsPackSource.browse,
                  label: pb.sourceBrowse,
                  icon: const MsIcon(MsIcons.globe),
                ),
                MsSegment(
                  value: NsPackSource.file,
                  label: pb.sourceFile,
                  icon: const MsIcon(MsIcons.folder),
                ),
              ],
              onChanged: c.setPackSource,
            ),
            if (c.packSource == NsPackSource.browse) PackBrowserView(c: c) else _MrpackFile(c: c),
          ] else ...[
            _NameField(c: c, onSubmitted: next),
            PackSummary(c: c),
            _javaAlert(context, c),
          ],
        ],
      ),
    );
  }
}

/// «Ho già un file .mrpack»: il percorso del file sul PC.
class _MrpackFile extends StatefulWidget {
  const _MrpackFile({required this.c});
  final NewServerController c;

  @override
  State<_MrpackFile> createState() => _MrpackFileState();
}

class _MrpackFileState extends State<_MrpackFile> {
  late final _path = TextEditingController(text: widget.c.mrpackPath);

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final c = widget.c;
    return MsStack(
      children: [
        MsText.small(context.s.packBrowser.fileIntro, tone: MsTextTone.secondary),
        MsField(
          label: s.mrpackPath,
          help: s.mrpackHint,
          error: c.importError == null ? null : '${s.importError}: ${c.importError}',
          child: Row(
            children: [
              Expanded(
                child: MsTextInput(
                  controller: _path,
                  mono: true,
                  autofocus: true,
                  onChanged: (v) => c.mrpackPath = v,
                  onSubmitted: (_) => c.openMrpack(),
                ),
              ),
              SizedBox(width: PixelScope.of(context).d(8)),
              MsButton(
                label: s.open,
                loading: c.importing,
                onPressed: c.importing ? null : c.openMrpack,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- 2c · cartella -----------------------------------------------------------------------

class _Folder extends StatefulWidget {
  const _Folder({required this.c});
  final NewServerController c;

  @override
  State<_Folder> createState() => _FolderState();
}

class _FolderState extends State<_Folder> {
  late final _path = TextEditingController(text: widget.c.folderPath);

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final h = context.s.home;
    final app = AppStateScope.of(context);
    final c = widget.c;
    final l = c.folderLayout;
    final why = l == null || c.folderError != null
        ? s.needFolder
        : c.nameError != null
        ? s.needName
        : null;
    final next = why == null ? c.next : null;
    return MsPanel(
      title: s.folderTitle,
      foot: [
        _Nav(
          c: c,
          next: next,
          why: why,
          // cartella generica: niente EULA, Avanti crea subito
          nextLabel: c.skipped(NsStep.eula) ? s.create : null,
        ),
      ],
      child: MsStack(
        children: [
          MsText.small(s.folderIntro, tone: MsTextTone.secondary),
          MsField(
            label: s.profile,
            help: c.profile == Profile.minecraft ? h.nsMinecraftHint : h.nsGenericHint,
            child: MsSegmented<Profile>(
              semanticLabel: s.profile,
              value: c.profile,
              segments: [
                MsSegment(value: Profile.minecraft, label: h.nsMinecraft),
                MsSegment(value: Profile.generic, label: h.nsGeneric),
              ],
              onChanged: c.setProfile,
            ),
          ),
          MsField(
            label: s.folderPath,
            error: c.folderError == null ? null : s.folderError,
            child: Row(
              children: [
                Expanded(
                  child: MsTextInput(
                    controller: _path,
                    mono: true,
                    autofocus: true,
                    onChanged: (v) => c.folderPath = v,
                    onSubmitted: (_) => c.checkFolder(),
                  ),
                ),
                SizedBox(width: PixelScope.of(context).d(8)),
                MsButton(label: s.check, onPressed: c.checkFolder),
              ],
            ),
          ),
          if (l != null && c.profile == Profile.minecraft)
            MsFacts([
              _baseFact(s.base, [
                [
                  if (l.loader != null) context.s.server.loaderName(l.loader!),
                  ?l.loaderVersion,
                ].join(' '),
                if (l.mcVersion != null) 'Minecraft ${l.mcVersion}',
              ]),
              MsFact(s.mods, s.folderMods(c.folderMods)),
              MsFact(s.start, l.label),
            ]),
          _NameField(c: c, onSubmitted: next),
          if (l != null)
            MsText.small(s.folderCopy(app.displayPath(app.worldsDir)), tone: MsTextTone.secondary),
        ],
      ),
    );
  }
}

// --- 3 · mod consigliate ----------------------------------------------------------------------

class _Mods extends StatelessWidget {
  const _Mods({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final mp = context.s.modpack;
    final ln = loaderLabel(context, c.loader);
    return MsPanel(
      title: s.modsTitle,
      foot: [
        _Nav(
          c: c,
          next: c.next,
          nextLabel: s.nextMods(c.chosenMods.length),
          extra: [
            if (c.chosenMods.isNotEmpty)
              MsButton(
                label: s.skip,
                variant: MsButtonVariant.ghost,
                onPressed: () {
                  c.chosenMods.clear();
                  c.next();
                },
              ),
          ],
        ),
      ],
      child: MsStack(
        children: [
          MsText.small(s.modsIntro(ln), tone: MsTextTone.secondary),
          MsList(
            children: [
              for (final m in c.recommended)
                MsListRow(
                  title: m.name,
                  meta: s.modHint(m.slug),
                  trail: MsRow(
                    gap: 8,
                    wrap: false,
                    children: [
                      MsChip(switch (m.side) {
                        PackSide.client => mp.sideClient,
                        PackSide.server => mp.sideServer,
                        PackSide.both => mp.sideBoth,
                      }),
                      MsCheckbox(
                        value: c.chosenMods.contains(m.slug),
                        semanticLabel: m.name,
                        onChanged: (v) => c.toggleMod(m.slug, v),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (c.loader == Loader.fabric)
            MsAlert(title: s.fabricApi, text: s.fabricApiText, tone: MsAlertTone.info),
        ],
      ),
    );
  }
}

// --- 4 · EULA -----------------------------------------------------------------------------------

class _Eula extends StatelessWidget {
  const _Eula({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final app = AppStateScope.of(context);
    final name = c.name.trim();
    final (mc, loader, lv) = switch (c.origin) {
      NsOrigin.scratch => (c.mc, c.loader, c.loaderVersion),
      NsOrigin.modpack => (
        c.imported?.pack.mcVersion,
        c.imported?.pack.loader,
        c.imported?.pack.loaderVersion,
      ),
      NsOrigin.folder => (c.folderLayout?.mcVersion, null, c.folderLayout?.loaderVersion),
    };
    final mods = switch (c.origin) {
      NsOrigin.scratch => [
        if (c.loader == Loader.fabric) 'Fabric API',
        for (final m in c.recommended)
          if (c.chosenMods.contains(m.slug)) m.name,
      ].join(', '),
      NsOrigin.modpack => () {
        final sp = c.split;
        if (sp == null) return '${c.imported?.pack.mods.length ?? 0}';
        final ex = c.excludedUnknown;
        return s.modsValue(sp.serverCount(ex), sp.clientCount(ex));
      }(),
      NsOrigin.folder => '${c.folderMods}',
    };
    return MsPanel(
      title: s.eulaTitle,
      foot: [_Nav(c: c, next: c.acceptAndCreate, nextLabel: s.accept)],
      child: MsStack(
        children: [
          MsText(s.eulaIntro(name), weight: 700),
          MsText(s.eulaText),
          MsRow(
            children: [
              MsButton(
                label: s.eulaRead,
                variant: MsButtonVariant.ghost,
                icon: const MsIcon(MsIcons.globe),
                onPressed: () => unawaited(app.modpackEnv.tools.openUrl(eulaUrl)),
              ),
            ],
          ),
          MsText(s.summary, weight: 700),
          MsFacts([
            MsFact(s.name, name),
            _baseFact(s.base, [
              [if (loader != null) loaderLabel(context, loader), ?lv].join(' '),
              if (mc != null) 'Minecraft $mc',
            ]),
            MsFact(s.mods, mods.isEmpty ? s.none : mods),
            if (c.origin == NsOrigin.scratch) MsFact(s.memory, s.gb(c.memoryGb)),
          ]),
        ],
      ),
    );
  }
}

// --- 5 · creazione, errore, pronto ----------------------------------------------------------------

class _Create extends StatelessWidget {
  const _Create({required this.c});
  final NewServerController c;

  @override
  Widget build(BuildContext context) {
    final s = context.s.newServer;
    final app = AppStateScope.of(context);
    final name = c.name.trim();
    if (c.done) {
      final id = c.created!.id;
      return MsPanel(
        title: s.readyTitle(name),
        foot: [
          MsButton(
            label: s.addMods,
            icon: const MsIcon(MsIcons.mods),
            onPressed: () => _leave(context, c, ModpackRoute(id)),
          ),
          MsButton(
            label: s.goToServer,
            variant: MsButtonVariant.primary,
            icon: const MsIcon(MsIcons.server),
            onPressed: () => _leave(context, c, ServerRoute(id)),
          ),
        ],
        child: MsStack(
          gap: 12,
          children: [
            MsText(s.readyText),
            MsFacts([if (c.folder != null) MsFact(s.onPc, app.displayPath(c.folder!))]),
          ],
        ),
      );
    }
    final failed = c.failed;
    final hubTouched = c.created != null;
    return MsPanel(
      title: failed == null ? s.creating(name) : s.failedTitle,
      foot: [
        if (failed != null) ...[
          MsButton(
            label: s.copyDetails,
            variant: MsButtonVariant.ghost,
            icon: const MsIcon(MsIcons.copy),
            onPressed: () => copyText(context, '${failed.name}: ${c.error}', s.copied),
          ),
          MsButton(label: s.cancel, onPressed: () => _leave(context, c)),
          MsButton(
            label: s.retry,
            variant: MsButtonVariant.primary,
            icon: const MsIcon(MsIcons.refresh),
            onPressed: c.create,
          ),
        ],
      ],
      child: MsStack(
        gap: 12,
        children: [
          MsText.small(failed == null ? s.creatingText : s.failedText, tone: MsTextTone.secondary),
          if (c.progress != null || c.progressLabel != null)
            MsStack(
              gap: 4,
              children: [
                MsProgress(value: c.progress),
                if (c.progressLabel != null)
                  MsText.small(c.progressLabel!, tone: MsTextTone.secondary),
              ],
            ),
          MsList(
            children: [
              for (final t in c.taskList)
                MsListRow(
                  title: s.task(t.name),
                  meta: c.tasks[t] == NsTaskState.failed ? '${c.error}' : null,
                  lead: switch (c.tasks[t] ?? NsTaskState.pending) {
                    NsTaskState.pending => const MsIcon(MsIcons.clock),
                    NsTaskState.running => const MsSpinner(),
                    NsTaskState.done => const MsIcon(MsIcons.check),
                    NsTaskState.failed => const MsIcon(MsIcons.x),
                  },
                ),
            ],
          ),
          if (failed != null && !hubTouched)
            MsAlert(title: s.nothingOnHub, text: s.nothingOnHubText(name), tone: MsAlertTone.info),
        ],
      ),
    );
  }
}

/// La base del server (loader con versione, Minecraft) come etichette.
MsFact _baseFact(String term, List<String> items) {
  final parts = [
    for (final p in items)
      if (p.isNotEmpty) p,
  ];
  return MsFact(term, parts.join(', '), child: MsMeta(parts));
}
