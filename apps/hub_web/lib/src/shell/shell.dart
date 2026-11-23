// Cornice di ogni pagina: sfondo a blocchi, header e contenuto. Se l'hub
// risponde 401 al posto della pagina c'è "Non ti riconosco".
import 'package:flutter/widgets.dart';
import 'package:ms_ui/ms_ui.dart';

import '../state/hub_state.dart';
import 'access_denied.dart';
import 'header.dart';

class HubShell extends StatelessWidget {
  const HubShell({super.key, required this.location, required this.child});

  /// Percorso corrente (per la scheda evidenziata).
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final app = HubStateScope.of(context);
    final c = MsTheme.colorsOf(context);
    return ColoredBox(
      color: c.bg,
      child: MsBlocksBackground(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HubHeader(location: location),
            Expanded(
              child: app.connection == HubConnection.denied ? const AccessDeniedPage() : child,
            ),
          ],
        ),
      ),
    );
  }
}
