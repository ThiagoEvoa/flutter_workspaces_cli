// Real-filesystem tests for Issue #31 (atomic reservation and rollback
// ownership).
//
// The mocked suite (test/flutter_workspaces_cli_test.dart) drives the CLI
// against an in-memory FileSystem. THIS FILE is the compatibility boundary
// for real filesystem semantics: package:file's LocalFileSystem on a temp
// directory under the OS temp dir — real symlinks, real directories, real
// path semantics — with the Flutter toolchain mocked exactly as in the
// mocked tests (no real `flutter` subprocess runs, no real flutter anywhere).
// The only real component is the filesystem.
//
// These tests exercise what memory-fs cannot cover:
//  - the sentinel link is created by REAL symlinks (the atomic claim);
//  - a dangling/broken symlink at a destination is detected and never
//    deleted by rollback;
//  - rollback against the real FS removes the reserved directory while
//    leaving the invocation (parent) directory's files intact;
//  - the workspace lock is held mid-run (observed inside the flutter
//    subprocess hook) and released on completion.
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
              .link(tempPath('.my_app_workspaces.reserved'))
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
        fs.link(tempPath('.my_app_workspaces.reserved')).existsSync(),
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
      fs.link(tempPath('.my_app_workspaces.reserved')).createSync('reserved');

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
        fs.link(tempPath('.my_app_workspaces.reserved')).existsSync(),
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
        fs.link(tempPath('.my_app_workspaces.reserved')).existsSync(),
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
                .link(tempPath('.flutter_workspaces_cli.lock'))
                .existsSync();
            destinationHeldDuringCreate = fs
                .link(tempPath('packages/.new_pkg.reserved'))
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
          fs.link(tempPath('.flutter_workspaces_cli.lock')).existsSync(),
          isFalse,
        );
        expect(
          fs.link(tempPath('packages/.new_pkg.reserved')).existsSync(),
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
          fs.link(tempPath('.flutter_workspaces_cli.lock')).existsSync(),
          isFalse,
        );
        expect(
          fs.link(tempPath('packages/.new_pkg.reserved')).existsSync(),
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
      fs.link(tempPath('packages/.new_pkg.reserved')).createSync('reserved');

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
        fs.link(tempPath('packages/.new_pkg.reserved')).existsSync(),
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
        fs.link(tempPath('packages/.new_pkg.reserved')).existsSync(),
        isFalse,
      );
      expect(
        fs.file(tempPath('pubspec.yaml')).readAsStringSync(),
        equals('workspace:\n  - app\n'),
      );
    });
  });
}
