import 'process_runner.dart';

/// Helpers to verify Flutter SDK availability.
///
/// Provides a synchronous check that ensures the `flutter` command is present
/// and executable in the system PATH before performing Flutter-dependent tasks.
class FlutterProcess {
  final ProcessRunner runner;
  final void Function(String) log;

  FlutterProcess({
    required this.runner,
    this.log = print,
  });

  /// Verifies that the Flutter CLI is installed and accessible in PATH.
  ///
  /// Runs `flutter --version` synchronously and throws when the command fails.
  ///
  /// Throws:
  /// - [Exception] when the `flutter` command cannot be executed.
  void isFlutterInstalledSync() {
    try {
      log('🔍 Checking if Flutter is installed...');
      runner.runSync('flutter', ['--version']);
      log('✅ Flutter is installed');
    } catch (_) {
      throw Exception(
        'Flutter is not installed or not in PATH. Please install Flutter to use this CLI.',
      );
    }
  }
}
