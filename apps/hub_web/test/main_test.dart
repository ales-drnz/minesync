import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

void main() {
  testWidgets('il hub parte con il segnaposto', (tester) async {
    await tester.pumpWidget(const MsPlaceholder(product: 'hub'));
    expect(find.byType(MsPlaceholder), findsOneWidget);
  });
}
