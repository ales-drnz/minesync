// Pezzi comuni alle pagine: titolo della scheda del browser, corpo della
// pagina (larghezza massima, margini del design, avviso hub offline),
// griglie che vanno a capo, icona di un server.
import 'package:flutter/widgets.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/hub_state.dart';

/// Riga secondaria di [MsListRow] con più dati brevi: MsListRow la divide
/// e la mostra come etichette piatte separate ([MsMeta]), senza separatori.
String listMeta(Iterable<String> items) => items.join(' · ');

/// Titolo della scheda del browser: "[page] (`hub`)".
class PageTitle extends StatelessWidget {
  const PageTitle({super.key, required this.page, required this.child});

  final String page;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hub = HubStateScope.of(context).hub?.name;
    return Title(
      title: context.s.shell.pageTitle(page, hub),
      color: MsTheme.colorsOf(context).accent,
      child: child,
    );
  }
}

/// Larghezza di [constraints] in px di design.
double designWidth(BuildContext context, double logical) => logical / PixelScope.of(context).scale;

/// Corpo di una pagina: scorre in verticale, larga al massimo 1280 px di
/// design, margini laterali tra 16 e 24 px come `clamp(16px,4vw,24px)`,
/// 32 sopra e 64 sotto. Con l'hub offline mostra l'avviso in cima.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.children, this.gap = 24, this.title});

  final List<Widget> children;
  final double gap;

  /// Titolo della scheda del browser (vedi [PageTitle]).
  final String? title;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final app = HubStateScope.of(context);
    final body = LayoutBuilder(
      builder: (context, c) {
        final side = (designWidth(context, c.maxWidth) * .04).clamp(16.0, 24.0);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(g.d(side), g.d(32), g.d(side), g.d(64)),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: g.d(MsSize.maxWidth)),
              child: MsStack(
                gap: gap,
                children: [
                  if (app.connection == HubConnection.offline) const OfflineBanner(),
                  ...children,
                ],
              ),
            ),
          ),
        );
      },
    );
    return title == null ? body : PageTitle(page: title!, child: body);
  }
}

/// Avviso "non raggiungo l'hub" con Riprova.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.shell;
    return MsAlert(
      tone: MsAlertTone.warn,
      title: s.offlineTitle,
      text: s.offlineText(app.deps.retryEvery.inSeconds),
      actions: [
        MsButton(
          label: s.retry,
          size: MsButtonSize.sm,
          icon: const MsIcon(MsIcons.refresh),
          onPressed: app.retry,
        ),
      ],
    );
  }
}

/// Griglia di elementi larghi almeno [minWidth] px di design
/// (`repeat(auto-fit, minmax(min(X,100%),1fr))`).
///
/// Con [equal] gli elementi della stessa riga sono alti uguali
/// ([MsEqualRow]): i pannelli affiancati finiscono alla stessa altezza.
class AutoGrid extends StatelessWidget {
  const AutoGrid({
    super.key,
    required this.children,
    this.minWidth = 300,
    this.gap = 16,
    this.equal = false,
  });

  final List<Widget> children;
  final double minWidth;
  final double gap;

  /// Elementi di una stessa riga alti uguali.
  final bool equal;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final gap = g.d(this.gap);
        // auto-fit: le colonne vuote spariscono e gli elementi si allargano
        final cols = ((c.maxWidth + gap) / (g.d(minWidth) + gap)).floor().clamp(
          1,
          children.isEmpty ? 1 : children.length,
        );
        final w = g.phys(((c.maxWidth - gap * (cols - 1)) / cols * g.dpr).floorToDouble());
        if (equal && cols > 1) {
          // righe di colonne alte uguali; l'ultima riga tiene le stesse
          // larghezze con posti vuoti
          return MsStack(
            gap: this.gap,
            children: [
              for (var i = 0; i < children.length; i += cols)
                MsEqualRow(
                  gap: this.gap,
                  children: [
                    for (var j = i; j < i + cols; j++)
                      j < children.length ? children[j] : const SizedBox.shrink(),
                  ],
                ),
            ],
          );
        }
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final c in children) SizedBox(width: w, child: c)],
        );
      },
    );
  }
}

/// Colonne affiancate con un peso ciascuna, una sotto l'altra quando non
/// c'è posto per [minWidth] px di design ciascuna.
///
/// Affiancate sono alte uguali ([MsEqualRow]): un pannello riempie la
/// colonna con il piede in fondo, una colonna di più pannelli usa
/// `MsStack(fillLast: true)` così l'ultimo arriva al fondo della vicina.
/// Con [equal] falso ogni colonna resta alta quanto il suo contenuto (es.
/// un dettaglio accanto a un elenco lungo).
class Columns extends StatelessWidget {
  const Columns({
    super.key,
    required this.children,
    this.minWidth = 360,
    this.gap = 24,
    this.equal = true,
  });

  final List<(int, Widget)> children;

  /// Colonne alte uguali quando sono affiancate.
  final bool equal;
  final double minWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final need = children.length * g.d(minWidth) + (children.length - 1) * g.d(gap);
        if (c.maxWidth < need) {
          return MsStack(gap: gap, children: [for (final e in children) e.$2]);
        }
        if (equal) {
          return MsEqualRow(
            gap: gap,
            flex: [for (final e in children) e.$1],
            children: [for (final e in children) e.$2],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: g.d(gap),
          children: [for (final e in children) Expanded(flex: e.$1, child: e.$2)],
        );
      },
    );
  }
}

/// Texture predefinita del riquadro di un server, stabile per id.
MsTextureKind textureFor(String id) {
  const kinds = [
    MsTextureKind.grass,
    MsTextureKind.stone,
    MsTextureKind.amethyst,
    MsTextureKind.wood,
    MsTextureKind.copper,
    MsTextureKind.dirt,
    MsTextureKind.slate,
  ];
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return kinds[h % kinds.length];
}

/// Riquadro quadrato di un server: `server-icon.png` della HEAD se c'è,
/// altrimenti la texture predefinita.
class SpaceIcon extends StatelessWidget {
  const SpaceIcon({super.key, required this.id, this.size = 48});

  final String id;

  /// Lato esterno in px di design.
  final double size;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final app = HubStateScope.of(context);
    final inner = g.d(size - 8);
    final fallback = MsTexture(textureFor(id), width: inner, height: inner);
    final img = app.platform.networkImage(app.api.iconUrl(id));
    return SizedBox(
      width: g.d(size),
      height: g.d(size),
      child: MsSlot.square(
        side: size,
        child: img == null
            ? fallback
            : Image(
                image: img,
                width: inner,
                height: inner,
                fit: BoxFit.cover,
                // icona pixel: niente sfumature
                filterQuality: FilterQuality.none,
                excludeFromSemantics: true,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}
