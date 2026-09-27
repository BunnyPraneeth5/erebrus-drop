import 'package:integration_test/integration_test_driver.dart';

/// Driver for running integration tests in profile/release (AOT) mode:
///   flutter drive --profile --driver=test_driver/integration_test.dart \
///     --target=integration_test/media_grab_test.dart -d DEVICE_ID
Future<void> main() => integrationDriver();
