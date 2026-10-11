// Kept so `flutter create .` doesn't generate the default counter test.
import 'package:flutter_test/flutter_test.dart';
import 'package:homechat/ui/widgets.dart';

void main() {
  test('initials', () {
    expect(initials('Maria Clara'), 'MC');
    expect(initials('lola'), 'L');
    expect(initials('  '), '?');
  });
}
