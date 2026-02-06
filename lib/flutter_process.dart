import 'dart:io';

/// Helpers to verify Flutter SDK availability.
///
/// Provides a synchronous check that ensures the `flutter` command is present
/// and executable in the system PATH before performing Flutter-dependent tasks.
abstract class FlutterProcess {
  /// Verifies that the Flutter CLI is installed and accessible in PATH.
  ///
  /// Runs `flutter --version` synchronously and throws when the command fails.
  ///
  /// Throws:
  /// - [Exception] when the `flutter` command cannot be executed.
  static void isFlutterInstalledSync() {
    try {
      print('🔍 Checking if Flutter is installed...');
      Process.runSync('flutter', ['--version']);
      print('✅ Flutter is installed');
    } catch (_) {
      throw Exception(
        'Flutter is not installed or not in PATH. Please install Flutter to use this CLI.',
      );
    }
  }
}
