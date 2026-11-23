// Card «Pacchetto per i giocatori» della scheda Mod: il .mrpack e lo ZIP
// delle sole mod dagli endpoint dell'hub, la generazione da cui sono fatti,
// come usarli (app MineSync, Prism, launcher ufficiale), le mod che vanno
// scaricate a mano (CurseForge), il server vanilla. Uguale per membri e
// admin: scaricare non richiede permessi; l'admin legge in più dove si
// cambiano le mod.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../state/hub_state.dart';
import '../../widgets/lock_view.dart';
import '../../widgets/page.dart';
import 'mods_tab.dart' show safeHomepage;
import 'server_data.dart';

class PackCard extends StatelessWidget {
  const PackCard({super.key, required this.space, required this.pack});

  final SpaceSummary space;
  final ClientPack pack;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s;
    final v = s.pack;
    final f = s.fmt;
    final address = space.dnsName ?? space.name;
    if (!pack.available) {
      final w = space.world;
      final vanilla = w == null || w.loader == null || w.loader == Loader.vanilla;
      return MsPanel(
        title: v.noPackTitle,
        child: MsStack(
          gap: 12,
          children: [
            MsText(
              vanilla ? v.vanillaText(space.name, w?.mcVersion ?? '?', address) : v.notManagedText,
            ),
            if (vanilla && space.dnsName != null)
              CopyValue(value: space.dnsName!, copyLabel: v.copyAddress, strong: true),
          ],
        ),
      );
    }
    final loader = [loaderName(pack.loader ?? Loader.vanilla), ?pack.loaderVersion].join(' ');
    final mc = pack.mcVersion ?? '?';
    final players = pack.required + pack.optional;
    final missing = pack.missing;
    Widget step(int n, String text) => MsText.small('$n. $text');
    return MsPanel(
      title: v.title,
      raised: true,
      child: MsStack(
        gap: 16,
        children: [
          MsText(v.intro(space.name, loader, mc, players)),
          MsText.small(v.updated(pack.n), tone: MsTextTone.secondary),
          MsRow(
            gap: 12,
            children: [
              if (pack.fileName != null)
                MsButton(
                  label: v.download(pack.fileName!),
                  variant: MsButtonVariant.primary,
                  icon: const MsIcon(MsIcons.download),
                  onPressed: () =>
                      app.platform.download(app.api.packUrl(space.id), filename: pack.fileName),
                ),
              if (pack.size != null)
                MsText.small(v.mrpackHint(f.size(pack.size!)), tone: MsTextTone.secondary),
              if (pack.modsZipName != null)
                MsButton(
                  label: v.modsZip(f.size(pack.modsZipSize ?? 0)),
                  icon: const MsIcon(MsIcons.download),
                  onPressed: () => app.platform.download(
                    app.api.packModsUrl(space.id),
                    filename: pack.modsZipName,
                  ),
                ),
            ],
          ),
          if (missing.isNotEmpty)
            MsAlert(
              title: v.missingTitle(missing.length),
              text: v.missingText(missing.map((m) => m.name ?? m.file).join(', ')),
              tone: MsAlertTone.warn,
              actions: [
                for (final m in missing)
                  if (safeHomepage(m.pageUrl) case final url?)
                    MsButton(
                      label: v.openPage(m.name ?? m.file),
                      size: MsButtonSize.sm,
                      icon: const MsIcon(MsIcons.globe),
                      onPressed: () => app.platform.openExternal(url),
                    ),
              ],
            ),
          Columns(
            minWidth: 240,
            children: [
              (
                1,
                MsStack(
                  gap: 8,
                  children: [
                    MsRow(
                      gap: 8,
                      children: [
                        MsText(v.withApp, weight: 700),
                        MsChip(v.recommended, tone: MsChipTone.accent),
                      ],
                    ),
                    MsText.small(v.withAppText(space.name)),
                  ],
                ),
              ),
              (
                1,
                MsStack(
                  gap: 8,
                  children: [
                    MsText(v.withPrism, weight: 700),
                    step(1, v.prism1),
                    step(2, v.prism2),
                    step(3, v.prism3(address)),
                  ],
                ),
              ),
              (
                1,
                MsStack(
                  gap: 8,
                  children: [
                    MsText(v.withOfficial, weight: 700),
                    step(1, v.official1(loader, mc)),
                    step(2, v.official2),
                    step(3, v.official3),
                  ],
                ),
              ),
            ],
          ),
          MsAlert(title: v.youLaunch, text: v.youLaunchText, tone: MsAlertTone.info),
          if (app.isAdmin) MsText.small(v.adminNote, tone: MsTextTone.secondary),
        ],
      ),
    );
  }
}
