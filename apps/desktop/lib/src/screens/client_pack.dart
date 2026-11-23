// Pacchetto per i giocatori nella scheda Mod: stato su questo PC (non
// pronto, vecchio rispetto alla testa del server, pronto), Prism Launcher
// (import con un clic, o il link per scaricarlo), profilo nel launcher
// ufficiale, cosa c'è dentro (obbligatorie, facoltative con la scelta per
// questo PC, solo sul server) e lo stato del server vanilla. MineSync non
// avvia Minecraft: prepara l'istanza, la avviano Prism o il launcher.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/app_state.dart';
import '../state/launcher_profile.dart';
import 'common.dart';
import 'modpack.dart' show NoFolderAlert;
import 'modpack_dialogs.dart';

/// Sito ufficiale di Prism Launcher.
const prismSite = 'https://prismlauncher.org/download/';

enum _CpFilter { all, required, optional, server }

class ClientPackView extends StatefulWidget {
  const ClientPackView({super.key, required this.space, required this.mp});
  final SpaceSummary space;
  final ModpackController mp;

  @override
  State<ClientPackView> createState() => _ClientPackViewState();
}

class _ClientPackViewState extends State<ClientPackView> {
  var _filter = _CpFilter.all;
  LauncherProfileResult? _profile;

  @override
  void initState() {
    super.initState();
    if (widget.mp.prismFound == null) unawaited(widget.mp.findPrism());
  }

  String _address(SpaceSummary sp) => joinAddress(sp) ?? sp.name;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final mp = widget.mp;
    final sp = widget.space;
    final pack = mp.base;
    if (mp.phase == PackPhase.noFolder) return NoFolderAlert(space: sp, mp: mp);
    if (mp.phase != PackPhase.ready || pack == null) {
      return MsPanel(child: MsRow(children: [const MsSpinner(), MsText(s.loading)]));
    }
    if (pack.loader == Loader.vanilla && pack.mods.isEmpty) {
      return MsPanel(
        child: MsEmptyState(
          title: s.cpVanilla,
          text: s.cpVanillaText(sp.name, pack.mcVersion, _address(sp)),
          art: const MsArt(MsArts.emptyIsland),
          action: MsButton(
            label: s.copyAddress,
            icon: const MsIcon(MsIcons.copy),
            onPressed: () => copyText(context, _address(sp), s.copied),
          ),
        ),
      );
    }
    if (mp.packIsNew) {
      return MsPanel(
        child: MsEmptyState(
          title: s.cpNoPack,
          text: s.cpNoPackText,
          art: const MsArt(MsArts.emptyIsland),
          action: MsButton(
            label: s.goServerMods,
            variant: MsButtonVariant.primary,
            icon: const MsIcon(MsIcons.server),
            onPressed: () => AppStateScope.read(context).go(ModpackRoute(sp.id)),
          ),
        ),
      );
    }
    final ss = mp.space;
    final head = sp.headN;
    final mine = ss.baseN ?? 0;
    final inst = mp.clientInstall;
    final where = inst?.target == 'launcher' ? s.official : s.prism;
    final active = pack.mods.where((m) => !m.disabled).toList();
    final required = [
      for (final m in active)
        if (m.side.onClient && !m.optional) m,
    ];
    final optional = [
      for (final m in active)
        if (m.side.onClient && m.optional) m,
    ];
    final serverOnly = [
      for (final m in active)
        if (m.side == PackSide.server) m,
    ];
    final missing = [
      for (final m in [...required, ...optional])
        if (m.source == PackSource.curseforge && !(m.curseforge?.allowDistribution ?? false)) m,
    ];
    final chosen = mp.chosenOptional;
    return MsStack(
      gap: 24,
      children: [
        // stato su questo PC
        if (!mp.clientReady && mine < head)
          MsAlert(
            title: s.localBehind,
            text: s.localBehindText(mine, head),
            tone: MsAlertTone.warn,
            actions: [
              MsButton(
                label: s.localDownload,
                size: MsButtonSize.sm,
                icon: const MsIcon(MsIcons.download),
                onPressed: ss.busy
                    ? null
                    : () async {
                        await ss.pull();
                        await mp.load(force: true);
                      },
              ),
            ],
          )
        else if (inst == null)
          MsAlert(title: s.cpNotReady, text: s.cpNotReadyText, tone: MsAlertTone.info)
        else if (inst.n < head)
          _Outdated(mp: mp, where: where, mine: inst.n, head: head)
        else
          MsAlert(
            title: s.cpReady,
            text: s.cpReadyText(where, inst.n, _address(sp)),
            tone: MsAlertTone.ok,
          ),
        if (mp.exported != null)
          MsAlert(title: s.exportedTitle, text: s.exportedText(mp.exported!), tone: MsAlertTone.ok),
        if (_profile != null)
          MsAlert(
            title: s.profileDone(_profile!.gameDir),
            text: s.profileBackup(_profile!.backup),
            tone: MsAlertTone.ok,
          ),
        if (mp.clientError != null)
          MsAlert(title: s.cpError, text: '${mp.clientError}', tone: MsAlertTone.err),
        if (missing.isNotEmpty)
          MsAlert(
            title: s.missingTitle,
            text: s.missingText(missing.map(modName).join(', ')),
            tone: MsAlertTone.warn,
            actions: [
              for (final m in missing)
                if (m.curseforge?.pageUrl case final url?)
                  MsButton(
                    label: '${s.openPage}: ${modName(m)}',
                    size: MsButtonSize.sm,
                    icon: const MsIcon(MsIcons.globe),
                    onPressed: () => mp.openUrl(url),
                  ),
            ],
          ),
        MsAlert(title: s.cpNoLaunch, text: s.cpNoLaunchText, tone: MsAlertTone.info),
        Columns(
          children: [
            (1, _PrismPanel(mp: mp, address: _address(sp))),
            (1, _LauncherPanel(mp: mp, space: sp, onDone: (r) => setState(() => _profile = r))),
          ],
        ),
        MsPanel(
          title: s.contents,
          actions: [MsText.small(s.contentsFrom(mine), tone: MsTextTone.secondary)],
          child: MsStack(
            gap: 16,
            children: [
              MsSegmented<_CpFilter>(
                semanticLabel: s.contents,
                value: _filter,
                segments: [
                  MsSegment(value: _CpFilter.all, label: '${s.cpAll} ${active.length}'),
                  MsSegment(value: _CpFilter.required, label: '${s.cpRequired} ${required.length}'),
                  MsSegment(value: _CpFilter.optional, label: '${s.cpOptional} ${optional.length}'),
                  MsSegment(
                    value: _CpFilter.server,
                    label: '${s.cpServerOnly} ${serverOnly.length}',
                  ),
                ],
                onChanged: (f) => setState(() => _filter = f),
              ),
              if (_filter == _CpFilter.all || _filter == _CpFilter.required)
                _Group(
                  title: '${s.cpRequired} (${required.length})',
                  foot: s.requiredFoot(required.length),
                  children: [
                    for (final m in required)
                      MsListRow(
                        title: modName(m),
                        meta: modVersion(m),
                        trail: sideMarker(context, m.side),
                      ),
                  ],
                ),
              if ((_filter == _CpFilter.all || _filter == _CpFilter.optional) &&
                  optional.isNotEmpty)
                _Group(
                  title: '${s.cpOptional} (${optional.length})',
                  foot: s.optionalFoot,
                  children: [
                    for (final m in optional)
                      MsListRow(
                        title: modName(m),
                        meta: modVersion(m),
                        trail: MsRow(
                          gap: 8,
                          wrap: false,
                          children: [
                            sideMarker(context, m.side),
                            MsCheckbox(
                              value: chosen.contains(m.key),
                              label: s.iWantIt,
                              onChanged: (v) => mp.chooseOptional(m.key, v),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              if ((_filter == _CpFilter.all || _filter == _CpFilter.server) &&
                  serverOnly.isNotEmpty)
                _Group(
                  title: '${s.cpServerOnly} (${serverOnly.length})',
                  foot: s.serverOnlyFoot(serverOnly.length),
                  children: [
                    for (final m in serverOnly)
                      MsListRow(
                        title: modName(m),
                        meta: m.source == PackSource.manual ? s.chipManual : modVersion(m),
                        trail: sideMarker(context, m.side),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.foot, required this.children});
  final String title;
  final String foot;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => MsStack(
    gap: 8,
    children: [
      MsText(title, weight: 700),
      MsList(children: children),
      MsText.small(foot, tone: MsTextTone.secondary),
    ],
  );
}

/// Il pacchetto preparato è più vecchio della testa: cosa cambia.
class _Outdated extends StatelessWidget {
  const _Outdated({required this.mp, required this.where, required this.mine, required this.head});
  final ModpackController mp;
  final String where;
  final int mine;
  final int head;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final old = mp.clientSnapshot;
    final now = mp.base;
    final lines = old == null || now == null
        ? const <String>[]
        : changeLines(context, PackDiff(_clientOnly(old), _clientOnly(now)));
    return MsAlert(
      title: s.cpOutdated(where, mine, head),
      text: [s.cpOutdatedText, if (lines.isNotEmpty) lines.join(', ')].join(' '),
      tone: MsAlertTone.warn,
      actions: [
        MsButton(
          label: s.cpUpdateIn(where),
          size: MsButtonSize.sm,
          variant: MsButtonVariant.primary,
          loading: mp.clientBusy != null,
          onPressed: mp.clientBusy != null || !mp.clientReady
              ? null
              : () => mp.clientInstall?.target == 'launcher'
                    ? mp.createProfile()
                    : mp.exportMrpack(target: mp.prismFound == true ? 'prism' : 'file'),
        ),
      ],
    );
  }

  /// Solo le mod che vanno sul PC dei giocatori.
  static Pack _clientOnly(Pack p) => p.copyWith(mods: p.mods.where((m) => m.side.onClient));
}

class _PrismPanel extends StatelessWidget {
  const _PrismPanel({required this.mp, required this.address});
  final ModpackController mp;
  final String address;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final found = mp.prismFound;
    final busy = mp.clientBusy;
    final can = mp.clientReady && busy == null;
    final export = MsButton(
      label: '${s.exportMrpack}…',
      icon: const MsIcon(MsIcons.download),
      loading: busy == 'export',
      onPressed: can ? () => mp.exportMrpack() : null,
    );
    if (found == false) {
      return MsPanel(
        title: s.prismMissing,
        child: MsStack(
          gap: 12,
          children: [
            MsText(s.prismMissingText),
            MsRow(
              gap: 8,
              children: [
                MsButton(
                  label: s.prismDownload,
                  variant: MsButtonVariant.primary,
                  icon: const MsIcon(MsIcons.globe),
                  onPressed: () => mp.openUrl(prismSite),
                ),
                MsButton(
                  label: s.javaRescan,
                  variant: MsButtonVariant.ghost,
                  icon: const MsIcon(MsIcons.refresh),
                  onPressed: mp.findPrism,
                ),
              ],
            ),
            MsText.small(s.prismMissingFoot, tone: MsTextTone.secondary),
            MsRow(children: [export]),
          ],
        ),
      );
    }
    return MsPanel(
      title: s.prism,
      actions: [if (found == true) MsPill(s.prismFound, tone: MsStatusTone.ok)],
      child: MsStack(
        gap: 12,
        children: [
          MsText('${s.prismText} (${s.prismRecommended})'),
          MsText.small('1. ${s.prismStep1}'),
          MsText.small('2. ${s.prismStep2}'),
          MsText.small('3. ${s.prismStep3(address)}'),
          MsRow(
            gap: 8,
            children: [
              MsButton(
                label: s.openInPrism,
                variant: MsButtonVariant.primary,
                icon: const MsIcon(MsIcons.play),
                loading: busy == 'prism',
                onPressed: can && found == true ? () => mp.exportMrpack(target: 'prism') : null,
              ),
              export,
            ],
          ),
        ],
      ),
    );
  }
}

class _LauncherPanel extends StatelessWidget {
  const _LauncherPanel({required this.mp, required this.space, required this.onDone});
  final ModpackController mp;
  final SpaceSummary space;
  final void Function(LauncherProfileResult r) onDone;

  @override
  Widget build(BuildContext context) {
    final s = context.s.modpack;
    final app = AppStateScope.of(context);
    final p = mp.base!;
    final dir = mp.launcherDir;
    final supported =
        p.loader == Loader.vanilla || p.loader == Loader.fabric || p.loader == Loader.quilt;
    final loader = [loaderLabel(context, p.loader), ?p.loaderVersion].join(' ');
    return MsPanel(
      title: s.official,
      child: MsStack(
        gap: 12,
        children: [
          if (dir == null)
            MsText(s.officialMissing, tone: MsTextTone.secondary)
          else if (!supported)
            MsText(s.officialUnsupported, tone: MsTextTone.secondary)
          else ...[
            MsText(s.officialText(loader, p.mcVersion)),
            MsFacts([
              MsFact(s.profileTerm, s.profileValue(space.name)),
              MsFact(s.folderTerm, app.displayPath('$dir/minesync/${space.id}')),
              MsFact(s.updatesTerm, s.updatesValue),
            ]),
            MsRow(
              gap: 12,
              children: [
                MsButton(
                  label: s.createProfile,
                  icon: const MsIcon(MsIcons.user),
                  loading: mp.clientBusy == 'launcher',
                  onPressed: mp.clientReady && mp.clientBusy == null
                      ? () async {
                          final r = await mp.createProfile();
                          if (r != null) onDone(r);
                        }
                      : null,
                ),
                MsText.small(s.closeLauncherFirst, tone: MsTextTone.secondary),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
