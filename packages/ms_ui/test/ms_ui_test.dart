import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

void main() {
  testWidgets('il segnaposto mostra il prodotto', (tester) async {
    await tester.pumpWidget(const MsPlaceholder(product: 'test'));
    expect(find.text('MineSync 0.1.0 · test'), findsOneWidget);
  });
}
