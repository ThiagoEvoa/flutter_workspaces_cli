// Real-filesystem tests for Issue #31 (atomic reservation and rollback
// ownership).
//
// The mocked suite (test/flutter_workspaces_cli_test.dart) drives the CLI
// against an in-memory FileSystem. THIS FILE is the compatibility boundary
// for real filesystem semantics: package:file's LocalFileSystem on a temp
// directory under the OS temp dir — real files, real directories, real
// path semantics — with the Flutter toolchain mocked exactly as in the
// mocked tests (no real `flutter` subprocess runs, no real flutter anywhere).
// The only real component is the filesystem.
//
// These tests exercise what memory-fs cannot cover:
//  - the sentinel is a REAL file created by an exclusive create (the atomic
//    claim) and probed for as a file;
//  - a dangling/broken symlink at a destination is detected and never
//    deleted by rollback;
//  - rollback against the real FS removes the reserved directory while
//    leaving the invocation (parent) directory's files intact;
//  - the workspace lock is held mid-run (observed inside the flutter
//    subprocess hook) and released on completion.
//
// Issue #37: the claim moved from a symlink to an exclusive regular-file
// create. On a real filesystem an existing entity (including a stale file
// left by an interrupted run) at the sentinel path makes the exclusive
// create fail; the CLI then treats it as a stale lock and recovers, so the
// real-fs tests below create stale sentinels as *files* and probe for
// *files*.
import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';
import 'package:test/test.dart';

/// A self-contained stand-in for the Flutter toolchain.
///
/// Mirrors the mock answers used by the mocked suite (same version-detection
/// and scaffolding shapes), with two switches that let the tests fail the
/// scaffold step, and a hook that fires inside the scaffold step so the
/// tests can observe real filesystem state *during* a run (e.g. the held
/// sentinel/lock). Never invokes a real subprocess.
class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner({
    required this.fs,
    this.appCreateExitCode = 0,
    this.packageCreateExitCode = 0,
    this.createHook,
  });

  /// The injected [FileSystem] backing the temp directory.
  final FileSystem fs;

  /// Exit code returned for `flutter create <app>` (app creation step).
  final int appCreateExitCode;

  /// Exit code returned for `flutter create --template=package <name>`.
  final int packageCreateExitCode;

  /// Fired inside `flutter create` (after the partial scaffold), letting the
  /// test observe real filesystem state mid-run. Must not throw.
  final void Function(List<String> arguments)? createHook;

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

    if (joined == '--version --machine') {
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
    if (arguments.contains('create') &&
        arguments.contains('--template=package')) {
      // Package scaffold: create the package directory (mirroring flutter's
      // partial failure — the directory exists even when create fails).
      final packageName = arguments.last;
      final path = workingDirectory != null
          ? '$workingDirectory/$packageName'
          : packageName;
      fs.directory(path).createSync(recursive: true);
      createHook?.call(arguments);
      if (packageCreateExitCode != 0) {
        return ProcessRunnerResult(
          exitCode: packageCreateExitCode,
          stdout: 'create failed',
          stderr: '',
        );
      }
      return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (arguments.contains('create')) {
      // App scaffold: create the app lib/test directories (partial scaffold
      // also in the failure case — same as the mocked tests).
      final appName = arguments.last;
      fs.directory('$appName/lib').createSync(recursive: true);
      fs.directory('$appName/test').createSync(recursive: true);
      createHook?.call(arguments);
      if (appCreateExitCode != 0) {
        return ProcessRunnerResult(
          exitCode: appCreateExitCode,
          stdout: 'create failed',
          stderr: '',
        );
      }
      return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
    }
    // Everything else (flutter pub add / flutter pub get / no-ops) succeeds.
    return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  late String originalCwd;
  late io.Directory tempDir;
  late LocalFileSystem fs;

  setUp(() {
    originalCwd = io.Directory.current.path;
    tempDir = io.Directory.systemTemp.createTempSync('issue31-real-fs-');
    fs = LocalFileSystem();
    fs.currentDirectory = tempDir;
  });

  tearDown(() {
    // Always restore the process working directory first, then delete the
    // temp directory — deleting a directory that is the process cwd fails.
    fs.currentDirectory = originalCwd;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String tempPath(String relative) => '${tempDir.path}/$relative';

  group('Real filesystem: setup', () {
    test('full run succeeds on the real FS, sentinel held during the run and '
        'released after, parent directory untouched', () {
      final notesFile = fs.file(tempPath('notes.txt'))
        ..writeAsStringSync('keep me');

      var sentinelHeldDuringCreate = false;
      final runner = FakeProcessRunner(
        fs: fs,
        createHook: (_) {
          sentinelHeldDuringCreate = fs
              .file(tempPath('.my_app_workspaces.reserved'))
              .existsSync();
        },
      );

      final logs = <String>[];
      SetupRunner(
        fs: fs,
        runner: runner,
        log: (m) => logs.add(m),
      ).run(['--name', 'my_app']);

      // Mid-run: the sentinel was held while the workspace was being created.
      expect(sentinelHeldDuringCreate, isTrue);

      // Success: workspace and app exist on the real FS.
      expect(
        logs,
        contains(contains('Flutter workspace setup completed successfully')),
      );
      expect(fs.directory(tempPath('my_app_workspaces')).existsSync(), isTrue);
      expect(
        fs.directory(tempPath('my_app_workspaces/my_app')).existsSync(),
        isTrue,
      );
      expect(
        fs.file(tempPath('my_app_workspaces/pubspec.yaml')).existsSync(),
        isTrue,
      );
      expect(
        fs
            .file(tempPath('my_app_workspaces/packages/core/pubspec.yaml'))
            .existsSync(),
        isTrue,
      );

      // Sentinel released on success; the invocation-parent file is intact.
      expect(
        fs.file(tempPath('.my_app_workspaces.reserved')).existsSync(),
        isFalse,
      );
      expect(notesFile.readAsStringSync(), equals('keep me'));
    });

    test('a second same-name setup after a successful run fails with the '
        'friendly error and leaves the first workspace intact', () {
      SetupRunner(
        fs: fs,
        runner: FakeProcessRunner(fs: fs),
        log: (_) {},
      ).run(['--name', 'my_app']);

      final logs = <String>[];
      final runner2 = FakeProcessRunner(fs: fs);
      expect(
        () => SetupRunner(
          fs: fs,
          runner: runner2,
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );
      expect(logs, contains(contains('already exists')));

      // The winner's workspace is intact and the runner restored cwd.
      expect(fs.directory('my_app_workspaces').existsSync(), isTrue);
      expect(
        fs.file(tempPath('my_app_workspaces/pubspec.yaml')).existsSync(),
        isTrue,
      );
    });

    test('setup interrupted before scaffolding: stale sentinel blocks the next '
        'run, no files created, parent file intact', () {
      final notesFile = fs.file(tempPath('notes.txt'))
        ..writeAsStringSync('keep me');
      // Simulate an interrupted winner: the sentinel is left behind and the
      // workspace directory does not exist.
      fs
          .file(tempPath('.my_app_workspaces.reserved'))
          .createSync(exclusive: true);

      final logs = <String>[];
      expect(
        () => SetupRunner(
          fs: fs,
          runner: FakeProcessRunner(fs: fs),
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      expect(logs, contains(contains('already reserved')));

      // Nothing was created; the stale sentinel is NOT deleted by the loser.
      expect(fs.directory('my_app_workspaces').existsSync(), isFalse);
      expect(
        fs.file(tempPath('.my_app_workspaces.reserved')).existsSync(),
        isTrue,
      );
      expect(notesFile.readAsStringSync(), equals('keep me'));
    });

    test('failed scaffolding rolls back the reserved directory only, on the '
        'real FS', () {
      final notesFile = fs.file(tempPath('notes.txt'))
        ..writeAsStringSync('keep me');

      final runner = FakeProcessRunner(fs: fs, appCreateExitCode: 2);
      final logs = <String>[];
      expect(
        () => SetupRunner(
          fs: fs,
          runner: runner,
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The reserved workspace directory was removed (including the partial
      // app), the sentinel was released, and the parent file survives.
      expect(fs.directory('my_app_workspaces').existsSync(), isFalse);
      expect(
        fs.file(tempPath('.my_app_workspaces.reserved')).existsSync(),
        isFalse,
      );
      expect(notesFile.readAsStringSync(), equals('keep me'));
    });
  });

  group('Real filesystem: add-package', () {
    void layoutWorkspace() {
      fs
          .file(tempPath('pubspec.yaml'))
          .writeAsStringSync('workspace:\n  - app\n');
      fs.file(tempPath('pubspec.lock')).writeAsStringSync('ORIGINAL-LOCK\n');
      fs.directory(tempPath('packages')).createSync();
      // A dangling (broken) symlink inside packages/ — the rollback must
      // never remove this pre-existing entity.
      fs
          .link(tempPath('packages/broken_link'))
          .createSync(tempPath('does-not-exist'));
    }

    test(
      'full add-package run: sentinel and lock held during the run, released '
      'after; manifest updated; broken link untouched',
      () {
        layoutWorkspace();

        var lockHeldDuringCreate = false;
        var destinationHeldDuringCreate = false;
        final runner = FakeProcessRunner(
          fs: fs,
          createHook: (_) {
            lockHeldDuringCreate = fs
                .file(tempPath('.flutter_workspaces_cli.lock'))
                .existsSync();
            destinationHeldDuringCreate = fs
                .file(tempPath('packages/.new_pkg.reserved'))
                .existsSync();
          },
        );

        final logs = <String>[];
        AddPackageRunner(
          fs: fs,
          runner: runner,
          log: (m) => logs.add(m),
        ).run(['--name', 'new_pkg']);

        expect(lockHeldDuringCreate, isTrue);
        expect(destinationHeldDuringCreate, isTrue);

        expect(
          logs,
          contains(contains('Package "new_pkg" added successfully!')),
        );
        expect(
          fs.file(tempPath('pubspec.yaml')).readAsStringSync(),
          contains('packages/new_pkg'),
        );
        expect(fs.directory(tempPath('packages/new_pkg')).existsSync(), isTrue);

        // Workspace lock and destination reservation released; the pre-existing
        // broken symlink is untouched.
        expect(
          fs.file(tempPath('.flutter_workspaces_cli.lock')).existsSync(),
          isFalse,
        );
        expect(
          fs.file(tempPath('packages/.new_pkg.reserved')).existsSync(),
          isFalse,
        );
        expect(fs.link(tempPath('packages/broken_link')).existsSync(), isTrue);
      },
    );

    test(
      'add-package failure rolls back on the real FS: manifest, lockfile and '
      'reserved package directory restored; lock and sentinel released; '
      'broken link untouched',
      () {
        layoutWorkspace();

        final runner = FakeProcessRunner(fs: fs, packageCreateExitCode: 2);
        final logs = <String>[];
        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: (m) => logs.add(m),
            errorLog: (m) => logs.add(m),
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // Original manifest and lockfile restored byte-for-byte.
        expect(
          fs.file(tempPath('pubspec.yaml')).readAsStringSync(),
          equals('workspace:\n  - app\n'),
        );
        expect(
          fs.file(tempPath('pubspec.lock')).readAsStringSync(),
          equals('ORIGINAL-LOCK\n'),
        );

        // The reserved package directory was removed (partial scaffold).
        expect(
          fs.directory(tempPath('packages/new_pkg')).existsSync(),
          isFalse,
        );

        // Lock and destination reservation released; the dangling symlink
        // survives the rollback.
        expect(
          fs.file(tempPath('.flutter_workspaces_cli.lock')).existsSync(),
          isFalse,
        );
        expect(
          fs.file(tempPath('packages/.new_pkg.reserved')).existsSync(),
          isFalse,
        );
        expect(fs.link(tempPath('packages/broken_link')).existsSync(), isTrue);
      },
    );

    test('stale destination reservation blocks the run; no files created; '
        'manifest unchanged; stale sentinel untouched', () {
      layoutWorkspace();
      // Simulate an interrupted winner: the destination reservation is left
      // behind and the package directory does not exist.
      fs
          .file(tempPath('packages/.new_pkg.reserved'))
          .createSync(exclusive: true);

      final logs = <String>[];
      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: FakeProcessRunner(fs: fs),
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      expect(logs, contains(contains('already reserved')));

      // Nothing was created; the manifest is unchanged; the stale sentinel
      // is NOT deleted by the loser.
      expect(fs.directory(tempPath('packages/new_pkg')).existsSync(), isFalse);
      expect(
        fs.file(tempPath('pubspec.yaml')).readAsStringSync(),
        equals('workspace:\n  - app\n'),
      );
      expect(
        fs.file(tempPath('packages/.new_pkg.reserved')).existsSync(),
        isTrue,
      );
    });

    test('add-package into a pre-existing (dangling) symlink destination fails '
        'the destination guard and never touches the symlink', () {
      layoutWorkspace();
      // A broken symlink at the target destination.
      fs
          .link(tempPath('packages/new_pkg'))
          .createSync(tempPath('does-not-exist'));

      final logs = <String>[];
      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: FakeProcessRunner(fs: fs),
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      expect(logs, contains(contains('already exists')));

      // The dangling symlink is untouched and no reserved sentinel survives.
      expect(fs.link(tempPath('packages/new_pkg')).existsSync(), isTrue);
      expect(
        fs.file(tempPath('packages/.new_pkg.reserved')).existsSync(),
        isFalse,
      );
      expect(
        fs.file(tempPath('pubspec.yaml')).readAsStringSync(),
        equals('workspace:\n  - app\n'),
      );
    });
  });

  group('Real filesystem: two-process race (Issue #31)', () {
    /// The package root, resolved from this test file's own location (the
    /// suite's cwd may be mutated by other tests — and the JIT kernel path
    /// is not a valid anchor under `dart test`). The frame's source URI is
    /// what `StackTrace.current` reports for this file, so parsing it gives
    /// the root: `<root>/test/<file>.dart` -> `<root>`.
    String packageRoot() {
      final st = StackTrace.current.toString();
      final match = RegExp(r'\(file://([^)]+)\)').firstMatch(st);
      if (match == null) {
        throw StateError(
          'could not resolve the package root from the stack trace',
        );
      }
      // The frame keeps a `:line:column` suffix; strip it before converting.
      final uriPath = match
          .group(1)!
          .replaceFirst(RegExp(r':(\d+):(\d+)$'), '');
      return io.File(
        Uri.parse('file://$uriPath').toFilePath(),
      ).parent.parent.absolute.path;
    }

    test('two concurrent setup runs on the same name — exactly one wins, the '
        'other is rejected with the friendly reservation message, and the '
        'winner\'s workspace survives untouched', () async {
      // Two REAL OS processes (`dart` from PATH) — not in-process
      // interleaving — both invoking the CLI against the SAME temp workspace
      // (the one created in setUp). The only deliberate fakery is the
      // scripted ProcessRunner inside each probe (see the file header of
      // test/helpers/concurrency_probe.dart): no real flutter runs, but the
      // filesystem interactions are real — two distinct OS processes
      // racing the same sentinel link, which is the atomic claim.
      final probeScript = io.File(
        '${packageRoot()}/test/helpers/concurrency_probe.dart',
      ).absolute.path;
      expect(
        io.File(probeScript).existsSync(),
        isTrue,
        reason: 'the probe script must exist to be spawned',
      );

      final probeArgs = [probeScript, tempDir.path, 'my_app'];
      final processA = await io.Process.start(
        'dart',
        probeArgs,
        workingDirectory: packageRoot(),
      );
      final processB = await io.Process.start(
        'dart',
        probeArgs,
        workingDirectory: packageRoot(),
      );

      // Drain stdout AND stderr concurrently: attach the read on each
      // stream before awaiting the exit codes. A child whose stdout pipe is
      // never drained can block indefinitely on a full pipe buffer (this is
      // what hung the Windows CI leg); awaiting exit codes before the
      // streams are drained would deadlock. Await the exit codes first,
      // then the (already-closing) stream futures, then assert.
      final stdoutAFuture = processA.stdout.transform(utf8.decoder).join();
      final stderrAFuture = processA.stderr.transform(utf8.decoder).join();
      final stdoutBFuture = processB.stdout.transform(utf8.decoder).join();
      final stderrBFuture = processB.stderr.transform(utf8.decoder).join();
      final exitA = await processA.exitCode;
      final exitB = await processB.exitCode;
      final stdoutA = await stdoutAFuture;
      final stderrA = await stderrAFuture;
      final stdoutB = await stdoutBFuture;
      final stderrB = await stderrBFuture;

      final codes = [exitA, exitB];
      // Exactly one process completes; the other is rejected.
      expect(
        codes.where((c) => c == 0).length,
        equals(1),
        reason:
            'expected exactly one winning process; exits were A=$exitA B=$exitB; '
            'A stdout: $stdoutA\nA stderr: $stderrA\nB stdout: $stdoutB\nB stderr: $stderrB',
      );
      final loserStderr = exitA == 0 ? stderrB : stderrA;
      final loserStdout = exitA == 0 ? stdoutB : stdoutA;

      // The loser was rejected with a friendly CLI error (not a low-level
      // exception or a crash). Two OS processes have unbounded startup
      // variance, so the loser may be rejected either by the read-only
      // guard ("already exists") or by the atomic claim ("already reserved");
      // both prove the CLI refused to touch the winner's workspace. The
      // sentinel — not the guard — is what closes the TOCTOU window in
      // production; this is a timing artifact of the two-process harness.
      expect(
        loserStderr,
        anyOf(contains('already reserved'), contains('already exists')),
        reason:
            'expected a friendly rejection message, got stderr: $loserStderr; stdout: $loserStdout',
      );

      // The winner's workspace survived intact: the workspace directory and
      // its scaffolded artifacts (workspace pubspec, app, core package) were
      // not touched by the loser, and the winner released its reservation
      // on the success path.
      expect(fs.directory(tempPath('my_app_workspaces')).existsSync(), isTrue);
      expect(
        fs.file(tempPath('my_app_workspaces/pubspec.yaml')).existsSync(),
        isTrue,
      );
      expect(
        fs.directory(tempPath('my_app_workspaces/my_app')).existsSync(),
        isTrue,
      );
      expect(
        fs
            .file(tempPath('my_app_workspaces/packages/core/pubspec.yaml'))
            .existsSync(),
        isTrue,
      );
      expect(
        fs.file(tempPath('.my_app_workspaces.reserved')).existsSync(),
        isFalse,
        reason: 'the winner releases its reservation on success',
      );
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}
