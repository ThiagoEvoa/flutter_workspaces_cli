import 'process_runner.dart';

/// Helpers to verify Flutter SDK availability.
///
/// Provides a synchronous check that ensures the `flutter` command is present
/// and executable in the system PATH before performing Flutter-dependent tasks.
class FlutterProcess {
  final ProcessRunner runner;
  final void Function(String) log;

  FlutterProcess({required this.runner, this.log = print});

  /// Verifies that the Flutter CLI is installed and accessible in PATH.
  ///
  /// Runs `flutter --version` synchronously and throws when the command fails.
  ///
  /// Throws:
  /// - [SubprocessException] when `flutter --version` exits with a non-zero
  ///   status (message includes the operation, exit status, and Flutter output).
  /// - [Exception] when the `flutter` command cannot be started (missing
  ///   executable).
  void isFlutterInstalledSync() {
    try {
      log('🔍 Checking if Flutter is installed...');
      final result = runner.runSync('flutter', ['--version']);
      checkProcessResult(result: result, operation: 'flutter --version');
      log('✅ Flutter is installed');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        'Flutter is not installed or not in PATH. Please install Flutter to use this CLI. '
        '(flutter --version could not be started. $e)',
      );
    }
  }
}
