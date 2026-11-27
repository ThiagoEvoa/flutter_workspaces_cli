// Standalone concurrency probe for the two-process race test.
//
// This is NOT part of the library under test. It exists so the two-process
// race test in test/flutter_workspaces_cli_real_fs_test.dart can drive the
// real CLI against a real temp workspace in two REAL OS processes at the
// same time: one clone claims the workspace reservation, the other must
// refuse to touch it. The probe is spawned twice (once per process) with
// the SAME workspace and the SAME package name:
//
//   dart test/helpers/concurrency_probe.dart <workspaceDir> <packageName>
//
// Exits 0 when the setup workflow completes, exits non-zero with the friendly
// message on stderr when the claim is rejected (or any failure occurs).
//
// The Flutter toolchain is still mocked (no real `flutter` anywhere): the
// scripted ProcessRunner below reproduces the scripted answers used by the
// real-filesystem tests — `--version --machine`, `--version`, and
// `flutter create`. Alongside the usual no-op scripted answers, the runner
// sleeps inside two scripted steps:
//
//   - the first scripted call (`--version --machine`, run BEFORE the
//     workspace claim), so both spawned processes pass the read-only guard
//     before either reaches the atomic claim — the sentinel link is then
//     the only gate, which is what this test proves;
//   - the `flutter create` step (while the winner holds the sentinel),
//     widening that holding window.
//
// The delay is a deliberate, honest part of the harness: without it the two
// processes would usually run sequentially, and the "loser" would be
// rejected by the read-only guard (or nothing) instead of actually racing
// the held atomic claim. The delay applies to the scripted toolchain only —
// never to real subprocesses — and both processes run this same probe, so
// only the process that passes the claim (the winner) pays it again in the
// create step.
import 'dart:io' as io;

import 'package:file/local.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

class ProbeProcessRunner implements ProcessRunner {
  const ProbeProcessRunner();

  /// How long the scripted toolchain sleeps in its scripted steps. See the
  /// file header for why this exists.
  static const Duration createDelay = Duration(milliseconds: 250);

  @override
  ProcessRunnerResult runSync(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
  }) {
    final joined = arguments.join(' ');

    // Version detection — the same shapes the real-fs tests use. The sleep
    // here happens BEFORE the workspace claim, so both processes pass the
    // read-only guard before either reaches the atomic claim.
    if (joined == '--version --machine') {
      io.sleep(createDelay);
      return ProcessRunnerResult(
        exitCode: 0,
        stdout:
            '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
        stderr: '',
      );
    }
    if (joined == '--version') {
      return ProcessRunnerResult(
        exitCode: 0,
        stdout: 'Dart SDK version: 3.12.0',
        stderr: '',
      );
    }

    // Scaffolding: mirror flutter create by creating the directories the
    // CLI expects, then sleep while the winner still holds the sentinel.
    if (arguments.contains('create') &&
        arguments.contains('--template=package')) {
      final packageName = arguments.last;
      final path = workingDirectory != null
          ? '$workingDirectory/$packageName'
          : packageName;
      io.Directory(path).createSync(recursive: true);
      io.sleep(createDelay);
      return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (arguments.contains('create')) {
      final appName = arguments.last;
      final workingDir = workingDirectory ?? '.';
      io.Directory('$workingDir/$appName/lib').createSync(recursive: true);
      io.Directory('$workingDir/$appName/test').createSync(recursive: true);
      io.sleep(createDelay);
      return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
    }

    // Everything else (flutter pub add / flutter pub get / no-ops) succeeds.
    return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    io.stderr.writeln(
      'Usage: concurrency_probe.dart <workspaceDir> <packageName>',
    );
    io.exit(64);
  }
  final workspaceDir = arguments[0];
  final packageName = arguments[1];

  final fs = LocalFileSystem();
  // Set the process cwd to the workspace (same as invoking the CLI from the
  // workspace root).
  fs.currentDirectory = io.Directory(workspaceDir);

  final runner = const ProbeProcessRunner();
  try {
    SetupRunner(
      fs: fs,
      runner: runner,
      log: (m) => io.stdout.writeln(m),
      errorLog: (m) => io.stderr.writeln(m),
    ).run(['--name', packageName]);
    io.exit(0);
  } on ExitException catch (e) {
    io.exit(e.code);
  } catch (e) {
    io.stderr.writeln('❌ $e');
    io.exit(1);
  }
}
