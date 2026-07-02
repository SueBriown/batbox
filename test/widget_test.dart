import 'package:flutter_test/flutter_test.dart';

import 'package:batbox/main.dart';

void main() {
  testWidgets('app loads with the main title', (WidgetTester tester) async {
    await tester.pumpWidget(const BatboxApp());

    expect(find.text('BatBox'), findsWidgets);
    expect(find.text('Record a short reference sound to begin.'), findsOneWidget);
  });
}
