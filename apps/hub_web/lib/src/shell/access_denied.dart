// "Non ti riconosco": l'hub ha risposto 401 a GET /hub, quindi questo
// dispositivo non è un membro della rete ZeroTier. Tre passi e Riprova.
// L'indirizzo e la rete compaiono solo se l'hub li manda nei dettagli
// dell'errore (`details.ip`, `details.network`).
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../state/hub_state.dart';
import '../widgets/page.dart';

/// Pagina informativa di ZeroTier.
final zeroTierInfo = Uri.parse('https://www.zerotier.com/');

class AccessDeniedPage extends StatelessWidget {
  const AccessDeniedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final s = context.s.shell;
    final g = PixelScope.of(context);
    final err = app.lastError;
    final details = err is ApiError ? err.details : const <String, Object?>{};
    final facts = [
      if (details['ip'] is String) MsFact(s.deniedAddress, details['ip']! as String),
      if (details['network'] is String) MsFact(s.deniedNetwork, details['network']! as String),
    ];
    Widget step(int n, String title, String text) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsLevel('$n'),
        const PixelGap(12, 0),
        Expanded(
          child: MsStack(
            gap: 2,
            children: [
              MsText(title, weight: 700),
              MsText.small(text, tone: MsTextTone.secondary),
            ],
          ),
        ),
      ],
    );
    return PageTitle(
      page: s.deniedPage,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(g.d(16), g.d(72), g.d(16), g.d(64)),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: g.d(640)),
            child: MsPanel(
              raised: true,
              padding: MsPanelPadding.none,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MsTexture(MsTextureKind.grass, height: g.d(24)),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: g.d(24), vertical: g.d(32)),
                    child: MsStack(
                      gap: 20,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        MsEmptyState(
                          title: s.deniedTitle,
                          text: s.deniedText,
                          error: true,
                          art: const MsIcon(MsIcons.lock, size: 32),
                        ),
                        if (facts.isNotEmpty)
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: g.d(420)),
                            child: MsSlot(child: MsFacts(facts)),
                          ),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: g.d(420)),
                          child: MsStack(
                            gap: 12,
                            children: [
                              step(1, s.deniedStep1, s.deniedStep1Text),
                              step(2, s.deniedStep2, s.deniedStep2Text),
                              step(3, s.deniedStep3, s.deniedStep3Text),
                            ],
                          ),
                        ),
                        MsRow(
                          children: [
                            MsButton(
                              label: s.retry,
                              variant: MsButtonVariant.primary,
                              icon: const MsIcon(MsIcons.refresh),
                              onPressed: app.retry,
                            ),
                            MsButton(
                              label: s.whatIsZeroTier,
                              variant: MsButtonVariant.ghost,
                              icon: const MsIcon(MsIcons.info),
                              onPressed: () => app.platform.openExternal(zeroTierInfo),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
