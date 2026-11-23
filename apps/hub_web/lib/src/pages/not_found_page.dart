// Percorso sconosciuto o server che non esiste (più).
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:ms_ui/ms_ui.dart';

import '../l10n/l10n.dart';
import '../router.dart';
import '../widgets/page.dart';

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.s.shell;
    return PageBody(
      title: s.notFoundTitle,
      children: [
        Padding(
          padding: EdgeInsets.only(top: PixelScope.of(context).d(40)),
          child: MsEmptyState(
            title: s.notFoundTitle,
            text: s.notFoundText,
            art: const MsArt(MsArts.crackedBlock),
            action: MsButton(
              label: s.backToServers,
              variant: MsButtonVariant.primary,
              icon: const MsIcon(MsIcons.server),
              onPressed: () => context.go(HubRoutes.overview),
            ),
          ),
        ),
      ],
    );
  }
}
