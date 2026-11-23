// Download (`/dl`): l'app desktop per questo PC (sistema riconosciuto
// dallo user agent), tre passi, tutte le piattaforme con SHA-256, requisiti
// (ZeroTier, Java, spazio), aggiornamento automatico e nota per i telefoni.
// Senza file in MINESYNC_DL: stato vuoto.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';
import '../../platform/client_os.dart';
import '../../shell/feedback.dart';
import '../../state/hub_state.dart';
import '../../widgets/page.dart';

MsIconData osIcon(DlOs os) => switch (os) {
  DlOs.windows => MsIcons.osWindows,
  DlOs.macos => MsIcons.osMac,
  DlOs.linux => MsIcons.terminal,
};

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  late Future<DlListing> _listing;

  @override
  void initState() {
    super.initState();
    _listing = HubStateScope.read(context).api.downloads();
  }

  void _reload() => setState(() {
    _listing = HubStateScope.read(context).api.downloads();
  });

  @override
  Widget build(BuildContext context) {
    final s = context.s.download;
    return PageBody(
      title: s.pageTitle,
      children: [
        MsStack(
          gap: 4,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MsEyebrow(s.eyebrow),
            MsText.h1(s.title),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: PixelScope.of(context).d(720)),
              child: MsText(s.lead, kind: MsTextKind.lg, tone: MsTextTone.secondary),
            ),
          ],
        ),
        FutureBuilder<DlListing>(
          future: _listing,
          builder: (context, snap) {
            if (snap.hasError) {
              return MsAlert(
                tone: MsAlertTone.err,
                title: s.loadError,
                text: errorText(context.s, snap.error!),
                actions: [
                  MsButton(
                    label: context.s.common.retry,
                    size: MsButtonSize.sm,
                    icon: const MsIcon(MsIcons.refresh),
                    onPressed: _reload,
                  ),
                ],
              );
            }
            if (!snap.hasData) {
              return const MsStack(
                gap: 12,
                children: [MsSkeleton.title(), MsSkeleton.text(), MsSkeleton.short()],
              );
            }
            return _Listing(listing: snap.data!);
          },
        ),
      ],
    );
  }
}

class _Listing extends StatelessWidget {
  const _Listing({required this.listing});
  final DlListing listing;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.download;
    final files = listing.files;
    final client = ClientOs.detect(app.platform.userAgent);
    final mine = client?.pick(files);
    final phone = MsAlert(title: s.phoneTitle, text: s.phoneText);
    if (files.isEmpty) {
      return MsStack(
        gap: 24,
        children: [
          MsPanel(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: PixelScope.of(context).d(24)),
              child: MsEmptyState(
                title: s.noneTitle,
                text: app.isAdmin ? s.noneAdmin : s.noneMember,
                art: const MsIcon(MsIcons.download, size: 32),
              ),
            ),
          ),
          const _Requirements(),
        ],
      );
    }
    return MsStack(
      gap: 32,
      children: [
        if (mine != null) _ThisPc(file: mine, os: client!.os, signedSums: listing.signedSums),
        if (client == null) phone,
        const _Steps(),
        MsStack(
          gap: 12,
          children: [
            MsText.label(s.allPlatforms, tone: MsTextTone.secondary),
            AutoGrid(children: [for (final f in files) _FileCard(file: f)]),
            if (files.any((f) => f.sha256 != null)) _Integrity(files: files),
          ],
        ),
        Columns(
          minWidth: 380,
          children: [
            (1, const _Requirements()),
            (
              1,
              MsStack(
                gap: 16,
                children: [
                  if (listing.updates.isNotEmpty)
                    MsAlert(tone: MsAlertTone.ok, title: s.updatesTitle, text: s.updatesText),
                  if (client != null) phone,
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

void _download(BuildContext context, DlFile f) {
  final app = HubStateScope.read(context);
  app.platform.download(app.api.downloadUrl(f.name), filename: f.name);
}

String _osLabel(DownloadStrings s, DlFile f) =>
    f.arch == null || f.arch == 'universal' ? s.osName(f.os) : '${s.osName(f.os)} (${f.arch})';

class _ThisPc extends StatelessWidget {
  const _ThisPc({required this.file, required this.os, required this.signedSums});
  final DlFile file;
  final DlOs os;
  final bool signedSums;

  @override
  Widget build(BuildContext context) {
    final s = context.s.download;
    final f = context.s.fmt;
    final g = PixelScope.of(context);
    final name = s.osName(os);
    final info = MsStack(
      gap: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsEyebrow(s.forThisPc(name)),
        MsText.h2(s.appFor(name)),
        MsText(s.osDetail(os), tone: MsTextTone.secondary),
        MsRow(
          gap: 4,
          children: [
            if (file.version != null) MsChip('v${file.version}'),
            MsChip(f.size(file.size)),
            if (signedSums) MsPill(s.signedSums, tone: MsStatusTone.ok),
          ],
        ),
      ],
    );
    final action = MsStack(
      gap: 8,
      children: [
        MsButton(
          label: s.downloadFor(name),
          variant: MsButtonVariant.primary,
          size: MsButtonSize.lg,
          icon: const MsIcon(MsIcons.download),
          block: true,
          onPressed: () => _download(context, file),
        ),
        MsText(
          file.name,
          kind: MsTextKind.mono,
          tone: MsTextTone.secondary,
          align: TextAlign.center,
        ),
      ],
    );
    return MsPanel(
      raised: true,
      padding: MsPanelPadding.none,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MsTexture(MsTextureKind.grass, height: g.d(20)),
          Padding(
            padding: EdgeInsets.all(g.d(28)),
            child: LayoutBuilder(
              builder: (context, c) {
                final icon = SizedBox(
                  width: g.d(96),
                  height: g.d(96),
                  child: MsSlot.square(side: 96, child: MsIcon(osIcon(os), size: 32)),
                );
                if (designWidth(context, c.maxWidth) < 720) {
                  return MsStack(
                    gap: 24,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [icon, info, action],
                  );
                }
                return Row(
                  children: [
                    icon,
                    const PixelGap(32, 0),
                    Expanded(child: info),
                    const PixelGap(32, 0),
                    SizedBox(width: g.d(320), child: action),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.download;
    final g = PixelScope.of(context);
    Widget step(int n, MsIconData icon, String title, String text) => MsPanel(
      child: MsStack(
        gap: 12,
        children: [
          Row(
            children: [
              MsLevel('$n'),
              const PixelGap(12, 0),
              SizedBox(
                width: g.d(44),
                height: g.d(44),
                child: MsSlot.square(side: 44, child: MsIcon(icon, size: 24)),
              ),
              const PixelGap(12, 0),
              Expanded(child: MsText.h3(title)),
            ],
          ),
          MsText(text, tone: MsTextTone.secondary),
        ],
      ),
    );
    final origin = app.platform.origin.toString().replaceAll(RegExp(r'/$'), '');
    return MsStack(
      gap: 12,
      children: [
        MsText.h2(s.stepsTitle),
        AutoGrid(
          minWidth: 260,
          equal: true,
          children: [
            step(1, MsIcons.download, s.step1, s.step1Text),
            step(2, MsIcons.signal, s.step2, s.step2Text(origin)),
            step(3, MsIcons.play, s.step3, s.step3Text),
          ],
        ),
      ],
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.file});
  final DlFile file;

  @override
  Widget build(BuildContext context) {
    final s = context.s.download;
    final f = context.s.fmt;
    return MsPanel(
      child: MsStack(
        gap: 12,
        children: [
          Row(
            children: [
              MsSlot.square(child: MsIcon(osIcon(file.os), size: 24)),
              const PixelGap(12, 0),
              Expanded(
                child: MsStack(
                  gap: 0,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MsText.h3(_osLabel(s, file), maxLines: 1),
                    MsText(f.size(file.size), tone: MsTextTone.secondary),
                  ],
                ),
              ),
            ],
          ),
          MsText.small(s.osDetail(file.os), tone: MsTextTone.secondary),
          Row(
            children: [
              Expanded(child: MsText(file.name, kind: MsTextKind.mono)),
              const PixelGap(8, 0),
              MsButton(
                label: s.download,
                size: MsButtonSize.sm,
                icon: const MsIcon(MsIcons.download),
                semanticLabel: '${s.download} ${file.name}',
                onPressed: () => _download(context, file),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Integrity extends StatefulWidget {
  const _Integrity({required this.files});
  final List<DlFile> files;

  @override
  State<_Integrity> createState() => _IntegrityState();
}

class _IntegrityState extends State<_Integrity> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final s = context.s.download;
    final g = PixelScope.of(context);
    return MsSlot(
      child: MsStack(
        gap: 6,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MsButton(
            label: _open ? s.integrityHide : s.integrity,
            variant: MsButtonVariant.ghost,
            size: MsButtonSize.sm,
            icon: const MsIcon(MsIcons.shield),
            onPressed: () => setState(() => _open = !_open),
          ),
          if (_open)
            for (final f in widget.files)
              if (f.sha256 != null)
                Row(
                  children: [
                    SizedBox(width: g.d(160), child: MsText.small(f.name, maxLines: 1)),
                    Expanded(
                      child: MsText(
                        f.sha256!,
                        kind: MsTextKind.mono,
                        tone: MsTextTone.secondary,
                        maxLines: 1,
                      ),
                    ),
                    MsButton.icon(
                      icon: const MsIcon(MsIcons.copy),
                      semanticLabel: '${s.copyHash} ${f.name}',
                      variant: MsButtonVariant.ghost,
                      size: MsButtonSize.sm,
                      onPressed: () => copyText(context, f.sha256!),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}

class _Requirements extends StatelessWidget {
  const _Requirements();

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.download;
    final f = context.s.fmt;
    final sizes = [
      for (final sp in app.spaces)
        if (sp.head != null) '${sp.name} ${f.size(sp.head!.stats.size)}',
    ];
    Widget item(MsIconData icon, MsTextTone tone, List<Widget> head, String text) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsSlot.square(
          child: MsIcon(icon, size: 24, color: msToneColor(MsTheme.colorsOf(context), tone)),
        ),
        const PixelGap(12, 0),
        Expanded(
          child: MsStack(
            gap: 4,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MsRow(gap: 8, children: head),
              MsText.small(text, tone: MsTextTone.secondary),
            ],
          ),
        ),
      ],
    );
    return MsPanel(
      title: s.requirements,
      child: MsStack(
        gap: 16,
        children: [
          item(MsIcons.signal, MsTextTone.ok, [
            MsText(s.zeroTier, weight: 700),
            if (app.online) MsPill(s.zeroTierOk, tone: MsStatusTone.ok),
          ], s.zeroTierText),
          item(MsIcons.java, MsTextTone.warn, [
            MsText(s.java, weight: 700),
            MsMeta(s.javaVersions),
          ], s.javaText),
          item(MsIcons.disk, MsTextTone.info, [
            MsText(s.diskSpace, weight: 700),
          ], sizes.isEmpty ? s.diskNone : s.diskText(sizes.join(', '))),
        ],
      ),
    );
  }
}
