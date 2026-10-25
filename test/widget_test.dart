
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_camera_pro_2027/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Camera app can be constructed', () {
    const app = CameraApp();
    expect(app, isA<CameraApp>());
  });
}
