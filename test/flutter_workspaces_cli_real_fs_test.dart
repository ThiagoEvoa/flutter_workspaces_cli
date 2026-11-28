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
//    subprocess hook) and released on completion;
//  - setup and add-package coordinate on ONE workspace reservation (Issue #38):
//    an add-package driven from inside the same workspace *while setup is
//    still active* is refused before it can snapshot or mutate the half-built
//    workspace, and a failed setup rolls back only its own output.
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

/// Best-effort "make [dir] non-writable on the real OS" that works where the
/// platform enforces directory write permissions and *reports honestly* where it
/// does not.
///
/// It clears the write bits via the platform `chmod` program (`chmod 500`, i.e.
/// read + execute only) and then probes by attempting a real exclusive create of
/// a probe file inside the directory. The probe is the authority: when it
/// *succeeds* the platform did not gate the write (notably Windows, where
/// `chmod` is absent or does not enforce directory write protection for a
/// non-elevated account) and the function returns `false` so the caller can
/// skip the test instead of producing a false result. When the probe *fails*,
/// the directory is genuinely non-writable and `true` is returned, guaranteeing
/// the caller's `createSync(exclusive: true)` will hit a real permission/IO
/// error (not contention). On the POSIX runners/hosts that enforce `chmod` this
/// always returns `true`.
///
/// It invokes the `chmod` *program* rather than `dart:io`'s
/// `FileSystemEntity.chmod` deliberately: the Flutter-bundled `dart:io` used by
/// `dart test` on this host (and inside the workspaces the CLI generates) does
/// not expose that API, while the standalone Dart used by the CI `Real-FS` job
/// does. Driving the probe through the real create keeps the assertion honest on
/// every platform without depending on a specific `dart:io` surface. Callers
/// must restore the write bit with [restoreDirWritable] before the parent can be
/// cleaned up. The function is self-cleaning: when the platform cannot enforce a
/// non-writable directory the write protection it attempted is immediately
/// cleared, so the directory is left writable on the caller's skip path too. A
/// top-level registry ([_nonWritableDirs]) plus the suite `tearDown` provide a
/// final safety net that clears any leftover write protection before the temp
/// tree is deleted, on every exit path.
final _nonWritableDirs = <io.Directory>[];

bool makeRealDirNonWritable(io.Directory dir) {
  // Track the directory so the suite teardown can guarantee write protection is
  // cleared before a recursive delete, even on a path that returns early (e.g.
  // a skipped test whose `try/finally` never runs).
  _nonWritableDirs.add(dir);
  try {
    io.Process.runSync('chmod', ['500', dir.path]);
  } catch (_) {
    // No `chmod` available (e.g. Windows): fall through to the probe, which
    // reports the directory is still writable and lets the caller skip.
  }
  final probe = io.File('${dir.path}/.fws_write_probe');
  try {
    probe.createSync(exclusive: true);
    // The write succeeded: not enforceable here. Clear any write protection we
    // just attempted so the directory stays writable for teardown on this
    // (skip) path — the caller's `try/finally` restore does not run when it
    // returns early after `markTestSkipped`.
    probe.deleteSync();
    restoreDirWritable(dir);
    return false;
  } catch (_) {
    // The write failed: the directory is genuinely non-writable.
    return true;
  }
}

/// Restores the write bit on [dir] so its parent can be cleaned up. Best-effort:
/// a failure to restore (e.g. no `chmod`) is swallowed because the parent
/// directory remains writable regardless, so teardown can still delete the tree.
///
/// On Windows `chmod 500` sets the directory read-only attribute, which a
/// recursive `deleteSync` cannot remove; the `attrib -R` fallback clears that
/// attribute where `chmod` alone does not, so the temp tree is always deletable.
void restoreDirWritable(io.Directory dir) {
  try {
    io.Process.runSync('chmod', ['700', dir.path]);
  } catch (_) {
    // No `chmod`; the parent stays writable, so cleanup is unaffected.
  }
  if (io.Platform.isWindows) {
    try {
      // Clear the Windows read-only attribute that `chmod 500` may have set,
      // which a recursive delete cannot otherwise remove.
      io.Process.runSync('attrib', ['-R', dir.path]);
    } catch (_) {
      // No `attrib` (or nothing to clear); the delete stays best-effort.
    }
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
    // Final safety net: clear any write protection attempted by
    // [makeRealDirNonWritable] before the recursive delete. This runs on every
    // exit path — including the skip path, where a test returns early after
    // `markTestSkipped` and its own `try/finally` restore never runs — so a
    // read-only child directory (e.g. on Windows) is always cleared first and
    // `deleteSync(recursive: true)` cannot fail with an access-denied error.
    for (final dir in _nonWritableDirs) {
      restoreDirWritable(dir);
    }
    _nonWritableDirs.clear();
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

    test('setup in a non-writable directory surfaces the permission/IO diagnostic '
        '(ioError, not contended), creating nothing', () {
      // Force a genuine permission/IO error (not contention): the workspace
      // sentinel is created in the invocation directory, so a non-writable
      // invocation directory makes the exclusive create fail with a real
      // filesystem error. This exercises the runner-level ioError branch of
      // [WorkspaceProcess.createWorkspaceFolderSync] (the "could not be
      // reserved" diagnostic) that the raw-exception tests in
      // test/reservation_test.dart do not reach through a runner.
      final invocationDir = io.Directory('${tempDir.path}/readonly_invocation');
      invocationDir.createSync();
      // Skip honestly where the platform cannot enforce a non-writable directory
      // (e.g. Windows, where chmod does not gate writes for a non-elevated
      // account); on POSIX the probe confirms it is genuinely non-writable, so
      // the createSync that follows hits a real permission/IO error.
      final nonWritable = makeRealDirNonWritable(invocationDir);
      if (!nonWritable) {
        markTestSkipped(
          'chmod cannot enforce a non-writable directory on this platform '
          '(e.g. Windows); the ioError runner path is verified on the POSIX '
          'CI leg.',
        );
        return;
      }
      try {
        fs.currentDirectory = invocationDir;

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

        // The ioError runner diagnostic surfaced (not the contended one),
        // naming the affected sentinel path.
        expect(logs, contains(contains('could not be reserved')));
        expect(logs, contains(contains('permission or file-system error')));
        expect(logs, isNot(contains('already reserved or occupied')));

        // Nothing was created in the non-writable invocation directory: no
        // workspace folder and no sentinel left behind.
        expect(fs.directory('my_app_workspaces').existsSync(), isFalse);
        expect(fs.file('my_app_workspaces').existsSync(), isFalse);
      } finally {
        // Restore the write bit so the parent can clean up the temp tree, and
        // restore the process working directory out of the invocation dir.
        restoreDirWritable(invocationDir);
        fs.currentDirectory = tempDir;
      }
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

    test('add-package in a non-writable packages directory surfaces the '
        'permission/IO diagnostic (ioError, not contended), touching nothing', () {
      // Force a genuine permission/IO error (not contention): the per-package
      // sentinel is created in the `packages` directory, so a non-writable
      // `packages` makes the exclusive create fail with a real filesystem
      // error. This exercises the runner-level ioError branch of
      // [AddPackageRunner] (the "could not be reserved" diagnostic) that the
      // raw-exception tests in test/reservation_test.dart do not reach through
      // a runner.
      layoutWorkspace();
      final packagesDir = io.Directory(tempPath('packages'));
      // Skip honestly where the platform cannot enforce a non-writable directory
      // (e.g. Windows, where chmod does not gate writes for a non-elevated
      // account); on POSIX the probe confirms it is genuinely non-writable.
      final nonWritable = makeRealDirNonWritable(packagesDir);
      if (!nonWritable) {
        markTestSkipped(
          'chmod cannot enforce a non-writable directory on this platform '
          '(e.g. Windows); the ioError runner path is verified on the POSIX '
          'CI leg.',
        );
        return;
      }
      try {
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

        // The ioError runner diagnostic surfaced (not the contended one),
        // naming the affected sentinel path.
        expect(logs, contains(contains('could not be reserved')));
        expect(logs, contains(contains('permission or file-system error')));
        expect(logs, isNot(contains('already reserved')));

        // Nothing was created or changed: no package directory, the manifest is
        // untouched, and no sentinel was left behind (the pre-existing broken
        // link inside packages/ is never touched either).
        expect(
          fs.directory(tempPath('packages/new_pkg')).existsSync(),
          isFalse,
        );
        expect(
          fs.file(tempPath('pubspec.yaml')).readAsStringSync(),
          equals('workspace:\n  - app\n'),
        );
        expect(
          fs.file(tempPath('packages/.new_pkg.reserved')).existsSync(),
          isFalse,
        );
      } finally {
        // Restore the write bit so the temp tree (including the pre-existing
        // broken link inside packages/) can be cleaned up.
        restoreDirWritable(packagesDir);
      }
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

    // AC#3 / Issue #38: "Concurrent work on independent workspaces remains
    // possible." Two real OS processes run setup for DIFFERENT names against the
    // SAME parent directory. Distinct names produce distinct reservations:
    // distinct `.<name>_workspaces.reserved` sentinels beside the parent and
    // distinct `<name>_workspaces/.flutter_workspaces_cli.lock` in-folder locks,
    // so the two runs do not contend and both complete. This is the mirror image
    // of the same-name race above (where exactly one wins): here BOTH must win,
    // which proves the coordination does not serialize unrelated workspaces.
    test(
      'two independent workspaces (different names) set up concurrently do not '
      'contend; each claims its own sentinel and in-folder lock (AC#3 / #38)',
      () async {
        final probeScript = io.File(
          '${packageRoot()}/test/helpers/concurrency_probe.dart',
        ).absolute.path;
        expect(
          io.File(probeScript).existsSync(),
          isTrue,
          reason: 'the probe script must exist to be spawned',
        );

        final processA = await io.Process.start('dart', [
          probeScript,
          tempDir.path,
          'alpha_ws',
        ], workingDirectory: packageRoot());
        final processB = await io.Process.start('dart', [
          probeScript,
          tempDir.path,
          'beta_ws',
        ], workingDirectory: packageRoot());

        // Drain stdout AND stderr concurrently (the Windows pipe-buffer pitfall the
        // same-name race above guards against): attach the reads before awaiting
        // the exit codes.
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

        // No contention on a shared gate: BOTH independent workspaces complete.
        expect(
          exitA,
          equals(0),
          reason:
              'workspace A (alpha_ws) must complete; stderr: $stderrA; stdout: $stdoutA',
        );
        expect(
          exitB,
          equals(0),
          reason:
              'workspace B (beta_ws) must complete; stderr: $stderrB; stdout: $stdoutB',
        );

        // Both workspaces exist under the shared parent, each with its OWN
        // (distinct) reservation: the sentinel beside it and the in-folder lock
        // inside it. Both reservations are released on the success path, which
        // confirms two distinct reservations coexisted (no shared gate contended).
        expect(
          fs.directory(tempPath('alpha_ws_workspaces')).existsSync(),
          isTrue,
        );
        expect(
          fs.directory(tempPath('beta_ws_workspaces')).existsSync(),
          isTrue,
        );
        expect(
          fs.file(tempPath('.alpha_ws_workspaces.reserved')).existsSync(),
          isFalse,
          reason: 'a completed setup releases its own reservation sentinel',
        );
        expect(
          fs.file(tempPath('.beta_ws_workspaces.reserved')).existsSync(),
          isFalse,
          reason: 'a completed setup releases its own reservation sentinel',
        );
        expect(
          fs
              .file(
                tempPath('alpha_ws_workspaces/.flutter_workspaces_cli.lock'),
              )
              .existsSync(),
          isFalse,
          reason: 'a completed setup releases its in-folder lock',
        );
        expect(
          fs
              .file(tempPath('beta_ws_workspaces/.flutter_workspaces_cli.lock'))
              .existsSync(),
          isFalse,
          reason: 'a completed setup releases its in-folder lock',
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // Issue #38: mixed-command coordination. setup and add-package must take ONE
  // consistent workspace reservation so that an add-package started while setup
  // is still active for the same workspace refuses before it can snapshot or
  // mutate the half-built workspace, and so that a failed setup rolls back only
  // its own output. These are deterministic single-process tests: the
  // setup runner's createHook is the synchronization point while setup is
  // active (it holds its reservation AND the workspace lock at that instant),
  // and a competing add-package is driven *from inside the same workspace*
  // during that window. The same real-fs file also runs on the CI windows-
  // latest Real-FS job, which is where the cross-platform (standard-Windows
  // account) behavior of this exclusive-file reservation is demonstrated.
  group('Real filesystem: setup vs add-package (Issue #38)', () {
    // Runs a competing add-package against the workspace that setup is building
    // *right now* (the caller invokes this from inside setup's createHook, so
    // setup holds its workspace lock at the call site) and reports whether it
    // was refused and whether it left any of its own output behind. Its log and
    // error lines are routed into `logSink` so the test can assert on the
    // refusal message.
    //
    // The competing add-package carries NO createHook and is refused at the
    // workspace-lock acquire — its first action, before validation, snapshot, or
    // any write — so its subprocess steps are never reached and it can never
    // re-enter the setup runner's hook.
    void runCompetingAddPackage({
      required String packageName,
      required List<String> logSink,
      required void Function(bool refused) onOutcome,
      required void Function() captureAfterRefusal,
    }) {
      var refused = false;
      try {
        AddPackageRunner(
          fs: fs,
          runner: FakeProcessRunner(fs: fs),
          log: logSink.add,
          errorLog: logSink.add,
        ).run(['--name', packageName]);
        refused = false;
      } on ExitException {
        refused = true;
      }
      onOutcome(refused);
      captureAfterRefusal();
    }

    test('add-package is refused while setup is active; a successful setup lets the '
        'same add-package retry complete', () {
      // A file in the invocation parent that no workspace write may touch.
      final notesFile = fs.file(tempPath('notes.txt'))
        ..writeAsStringSync('keep me');

      var refusedDuringActiveSetup = false;
      var competingScaffoldedPackage = false;
      var competingWroteManifest = false;
      var competingWroteLockfile = false;

      // The createHook fires on *every* `flutter create` (app-create and later
      // core-package create). Drive the competing add-package only on the FIRST
      // fire — during app-create, while setup holds the lock and has not yet
      // written the root manifest — so the "left no output" check is measured
      // against a workspace that does not yet contain setup's own manifest.
      var ranCompeting = false;
      final setupRunner = FakeProcessRunner(
        fs: fs,
        createHook: (_) {
          if (ranCompeting) {
            return;
          }
          ranCompeting = true;
          runCompetingAddPackage(
            packageName: 'new_pkg',
            logSink: <String>[],
            onOutcome: (refused) => refusedDuringActiveSetup = refused,
            captureAfterRefusal: () {
              // After the competing add-package returned, did it leave any of
              // its own output in the half-built workspace? It was refused at
              // the lock (before any write), so it must have scaffolded no
              // package and written neither the root manifest nor the lockfile.
              competingScaffoldedPackage = fs
                  .directory(tempPath('my_app_workspaces/packages/new_pkg'))
                  .existsSync();
              competingWroteManifest = fs
                  .file(tempPath('my_app_workspaces/pubspec.yaml'))
                  .existsSync();
              competingWroteLockfile = fs
                  .file(tempPath('my_app_workspaces/pubspec.lock'))
                  .existsSync();
            },
          );
        },
      );

      // A successful setup, active throughout the competing add-package's run.
      SetupRunner(
        fs: fs,
        runner: setupRunner,
        log: (_) {},
        errorLog: (_) {},
      ).run(['--name', 'my_app']);

      // AC#1: the competing add-package was refused while setup held the lock.
      expect(
        refusedDuringActiveSetup,
        isTrue,
        reason:
            'the competing add-package must be refused while setup is active',
      );
      // ...and it left none of its own output in the half-built workspace: no
      // package directory, no root manifest, no lockfile.
      expect(
        competingScaffoldedPackage,
        isFalse,
        reason: 'a refused add-package must not scaffold into the workspace',
      );
      expect(
        competingWroteManifest,
        isFalse,
        reason: 'a refused add-package must not write the root manifest',
      );
      expect(
        competingWroteLockfile,
        isFalse,
        reason: 'a refused add-package must not write the lockfile',
      );

      // A successful setup completed and released BOTH reservations, so the
      // workspace is fully built and the lock is free.
      expect(fs.directory(tempPath('my_app_workspaces')).existsSync(), isTrue);
      expect(
        fs
            .file(tempPath('my_app_workspaces/.flutter_workspaces_cli.lock'))
            .existsSync(),
        isFalse,
        reason: 'a completed setup releases the workspace lock',
      );

      // AC#2: the same add-package that was refused now completes once setup
      // released the lock. It runs from the workspace root, as a user would.
      fs.currentDirectory = fs.directory(tempPath('my_app_workspaces'));
      AddPackageRunner(
        fs: fs,
        runner: FakeProcessRunner(fs: fs),
        log: (_) {},
      ).run(['--name', 'new_pkg']);

      expect(
        fs
            .directory(tempPath('my_app_workspaces/packages/new_pkg'))
            .existsSync(),
        isTrue,
        reason: 'a retry after a successful setup must complete',
      );
      expect(notesFile.readAsStringSync(), equals('keep me'));
    });

    test('a competing add-package driven AFTER the root manifest is written is '
        'refused by the shared workspace lock (not "Workspace root not found"), '
        'scaffolds nothing, and a retry completes (F-1 / AC#1)', () {
      // F-1 strengthens the success case. The earlier test in this group drives
      // the competing add-package at the FIRST `flutter create` (the app-create),
      // when the root manifest does not yet exist, so the add-package is refused
      // at "Workspace root not found" regardless of the lock. That makes its
      // "left no output" assertions near-vacuous with respect to the shared lock:
      // a mutation that un-shares the lock still passes that earlier test, because
      // the add-package is refused for a different reason (a missing manifest).
      //
      // This test drives the competing add-package at a LATER sync point: the
      // core-package create, the SECOND `flutter create` fire, by which time
      // createRootPubspecSync and createPackagesFolderSync have run. The add-
      // package therefore PASSES manifest validation and can be refused ONLY by
      // the workspace lock setup still holds. If the lock were not shared, the
      // add-package would proceed and scaffold new_pkg; the "scaffolded nothing"
      // assertion below guards the shared lock (verified by the mutation sanity
      // check in the correction notes).
      final notesFile = fs.file(tempPath('notes.txt'))
        ..writeAsStringSync('keep me');

      var refusedDuringActiveSetup = false;
      var competingScaffoldedPackage = false;
      var competingWroteLockfile = false;
      var competingRefusedByLock = false;
      var competingRefusedByMissingManifest = false;
      final competingLogs = <String>[];

      // The createHook fires on every `flutter create`. Drive the competing
      // add-package only on the core-package create: the first fire whose
      // argument name is `core` (the SECOND `flutter create`, which happens
      // after the manifest and packages/ exist). Never on the app-create. The
      // `ranCompeting` flag guards against re-entry: a refused add-package is
      // refused at the lock and never reaches its own `flutter create`, so it
      // cannot re-enter this hook; the flag is a belt-and-suspenders guard.
      var ranCompeting = false;
      final setupRunner = FakeProcessRunner(
        fs: fs,
        createHook: (arguments) {
          if (ranCompeting || arguments.last != 'core') {
            return;
          }
          ranCompeting = true;
          runCompetingAddPackage(
            packageName: 'new_pkg',
            logSink: competingLogs,
            onOutcome: (refused) => refusedDuringActiveSetup = refused,
            captureAfterRefusal: () {
              // After the competing add-package returned, did it leave any of its
              // own output in the half-built workspace? It was refused at the
              // lock (before any write), so it scaffolded no package and wrote
              // neither the root manifest nor the lockfile.
              competingScaffoldedPackage = fs
                  .directory(tempPath('my_app_workspaces/packages/new_pkg'))
                  .existsSync();
              competingWroteLockfile = fs
                  .file(tempPath('my_app_workspaces/pubspec.lock'))
                  .existsSync();
            },
          );
          // Classify the refusal cause from the add-package's own output. At this
          // sync point the manifest exists, so "already reserved" (the lock) must
          // be the cause, not "Workspace root not found" (a validation failure).
          final joined = competingLogs.join('\n');
          competingRefusedByLock = joined.contains('already reserved');
          competingRefusedByMissingManifest = joined.contains(
            'Workspace root not found',
          );
        },
      );

      // A successful setup, active throughout the competing add-package's run.
      SetupRunner(
        fs: fs,
        runner: setupRunner,
        log: (_) {},
        errorLog: (_) {},
      ).run(['--name', 'my_app']);

      // AC#1 (F-1): the competing add-package was refused while setup held the
      // lock...
      expect(
        refusedDuringActiveSetup,
        isTrue,
        reason:
            'the competing add-package must be refused while setup is active',
      );
      // ... and the refusal is the SHARED LOCK, not a missing manifest: at this
      // sync point the manifest exists, so the add-package passed validation and
      // was refused at the lock acquire (the message names the lock).
      expect(
        competingRefusedByLock,
        isTrue,
        reason:
            'the refusal must be the shared workspace lock, not a missing manifest',
      );
      expect(
        competingRefusedByMissingManifest,
        isFalse,
        reason:
            'the add-package is driven after the manifest is written, so it must '
            'not be refused at "Workspace root not found"',
      );
      // ... and it left none of its own output in the half-built workspace: no
      // package directory and no root lockfile. The root manifest is NOT a
      // meaningful "no output" guard here: the workspace's `packages/*` member
      // makes a completing add-package skip the manifest edit, so the manifest's
      // absence does not by itself prove the add-package was refused. The
      // scaffolded-package and refusal-message checks do the guarding.
      expect(
        competingScaffoldedPackage,
        isFalse,
        reason:
            'a refused add-package must not scaffold into the workspace; if the '
            'lock were not shared it would scaffold new_pkg here',
      );
      expect(
        competingWroteLockfile,
        isFalse,
        reason: 'a refused add-package must not write the root lockfile',
      );

      // A successful setup completed and released BOTH reservations, so the
      // workspace is fully built and the lock is free.
      expect(fs.directory(tempPath('my_app_workspaces')).existsSync(), isTrue);
      expect(
        fs
            .file(tempPath('my_app_workspaces/.flutter_workspaces_cli.lock'))
            .existsSync(),
        isFalse,
        reason: 'a completed setup releases the workspace lock',
      );

      // AC#2: the same add-package that was refused now completes once setup
      // released the lock. It runs from the workspace root, as a user would.
      fs.currentDirectory = fs.directory(tempPath('my_app_workspaces'));
      AddPackageRunner(
        fs: fs,
        runner: FakeProcessRunner(fs: fs),
        log: (_) {},
      ).run(['--name', 'new_pkg']);

      expect(
        fs
            .directory(tempPath('my_app_workspaces/packages/new_pkg'))
            .existsSync(),
        isTrue,
        reason: 'a retry after a successful setup must complete',
      );
      expect(notesFile.readAsStringSync(), equals('keep me'));
    });

    test('a failed setup cleans only its own output while an add-package is '
        'refused mid-setup', () {
      final notesFile = fs.file(tempPath('notes.txt'))
        ..writeAsStringSync('keep me');

      var refusedDuringActiveSetup = false;
      var competingScaffoldedPackage = false;
      var competingWroteManifest = false;
      var competingWroteLockfile = false;
      final competingLogs = <String>[];

      // As in the success case, drive the competing add-package only on the
      // first `flutter create` fire, so the message it surfaces is the busy/
      // retry refusal from the lock contention with the active setup.
      var ranCompeting = false;
      final setupRunner = FakeProcessRunner(
        fs: fs,
        appCreateExitCode: 2,
        createHook: (_) {
          if (ranCompeting) {
            return;
          }
          ranCompeting = true;
          runCompetingAddPackage(
            packageName: 'new_pkg',
            logSink: competingLogs,
            onOutcome: (refused) => refusedDuringActiveSetup = refused,
            captureAfterRefusal: () {
              competingScaffoldedPackage = fs
                  .directory(tempPath('my_app_workspaces/packages/new_pkg'))
                  .existsSync();
              competingWroteManifest = fs
                  .file(tempPath('my_app_workspaces/pubspec.yaml'))
                  .existsSync();
              competingWroteLockfile = fs
                  .file(tempPath('my_app_workspaces/pubspec.lock'))
                  .existsSync();
            },
          );
        },
      );

      final logs = <String>[];
      expect(
        () => SetupRunner(
          fs: fs,
          runner: setupRunner,
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The competing add-package was refused while the failing setup held the
      // lock, and it left no output of its own to be clobbered by the
      // rollback.
      expect(
        refusedDuringActiveSetup,
        isTrue,
        reason:
            'the competing add-package must be refused while setup is active',
      );
      expect(
        competingLogs,
        contains(contains('already reserved')),
        reason: 'the refusal must surface a clear busy/retry message',
      );
      expect(
        competingScaffoldedPackage,
        isFalse,
        reason: 'a refused add-package must not scaffold into the workspace',
      );
      expect(
        competingWroteManifest,
        isFalse,
        reason: 'a refused add-package must not write the root manifest',
      );
      expect(
        competingWroteLockfile,
        isFalse,
        reason: 'a refused add-package must not write the root lockfile',
      );

      // AC#2: the failed setup rolled back ONLY its own output — the workspace
      // directory and its partial contents are gone, both reservations are
      // released, and the parent's file (an independent run's output) survives.
      expect(
        fs.directory(tempPath('my_app_workspaces')).existsSync(),
        isFalse,
        reason: 'a failed setup removes its own reserved directory',
      );
      expect(
        fs.file(tempPath('.my_app_workspaces.reserved')).existsSync(),
        isFalse,
        reason: 'a failed setup releases its reservation sentinel',
      );
      expect(
        fs
            .file(tempPath('my_app_workspaces/.flutter_workspaces_cli.lock'))
            .existsSync(),
        isFalse,
        reason: 'a failed setup releases the workspace lock',
      );
      expect(notesFile.readAsStringSync(), equals('keep me'));
    });
  });
}
