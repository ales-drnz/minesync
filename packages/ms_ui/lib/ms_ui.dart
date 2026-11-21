/// MineSync design system: tokens, pixel components, icons and fonts.
library;

import 'package:flutter/widgets.dart';

/// Schermata segnaposto della Fase 0, condivisa da app desktop e hub web:
/// verifica che entrambi i prodotti compilino contro lo stesso pacchetto.
class MsPlaceholder extends StatelessWidget {
  const MsPlaceholder({super.key, required this.product});

  /// Nome del prodotto mostrato (app o hub).
  final String product;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1B1712),
      child: Center(
        child: Text(
          'MineSync 0.1.0 · $product',
          textDirection: TextDirection.ltr,
          style: const TextStyle(color: Color(0xFFF3EBDD), fontSize: 24),
        ),
      ),
    );
  }
}
