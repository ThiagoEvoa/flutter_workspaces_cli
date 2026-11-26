import 'dart:io';

/// Abstraction for running processes to enable testing.
abstract class ProcessRunner {
  /// Runs a process synchronously.
  ProcessRunnerResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  });
}

/// Simple result class for [ProcessRunner].
class ProcessRunnerResult {
  final int exitCode;
  final dynamic stdout;
  final dynamic stderr;

  ProcessRunnerResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

/// Concrete implementation of [ProcessRunner] using [Process.runSync].
class RealProcessRunner implements ProcessRunner {
  const RealProcessRunner();

  @override
  ProcessRunnerResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) {
    final result = Process.runSync(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
    );
    return ProcessRunnerResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }
}

/// Error thrown when a subprocess invocation fails.
///
/// Carries the failed [operation] label (e.g. `flutter create my_app`), the
/// [exitCode] returned by the process (`null` when the process could not be
/// started at all), and the relevant process [output] captured from the failed
/// invocation. The [toString] message includes all of these so the error is
/// useful on its own.
class SubprocessException implements Exception {
  /// Human-readable label of the operation that failed.
  final String operation;

  /// Exit code returned by the process, or `null` when the process could not
  /// be started (e.g. the executable is missing).
  final int? exitCode;

  /// Relevant process output (captured stdout and/or stderr) from the failed
  /// invocation.
  final String output;

  const SubprocessException({
    required this.operation,
    this.exitCode,
    this.output = '',
  });

  @override
  String toString() {
    if (exitCode == null) {
      return '$operation could not be started (missing executable?)';
    }
    final trimmed = output.trim();
    final detail = trimmed.isEmpty ? '' : '\n$trimmed';
    return '$operation failed with exit code $exitCode$detail';
  }
}

/// Throws a descriptive [SubprocessException] when [result] reports a non-zero
/// exit code.
///
/// The thrown message includes the failed [operation] label, the exit status,
/// and the relevant captured Flutter output (stdout and/or stderr). A [result]
/// with exit code `0` means the step succeeded; this helper returns normally.
///
/// This is the shared result check for Flutter subprocesses used by the CLI's
/// Flutter/Dart helpers. Process-start failures (missing executable) are
/// handled separately by the call sites, which throw a missing-executable
/// message instead.
void checkProcessResult({
  required ProcessRunnerResult result,
  required String operation,
}) {
  if (result.exitCode == 0) return;

  final stdout = result.stdout?.toString().trim() ?? '';
  final stderr = result.stderr?.toString().trim() ?? '';
  final output = [stdout, stderr].where((s) => s.isNotEmpty).join('\n');

  throw SubprocessException(
    operation: operation,
    exitCode: result.exitCode,
    output: output,
  );
}
