import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

void main() {
  testWidgets('il app parte con il segnaposto', (tester) async {
    await tester.pumpWidget(const MsPlaceholder(product: 'app'));
    expect(find.byType(MsPlaceholder), findsOneWidget);
  });
}
