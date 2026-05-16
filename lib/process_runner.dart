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
