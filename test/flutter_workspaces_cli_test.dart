import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';
import 'package:flutter_workspaces_cli/run_reservation.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockProcessRunner extends Mock implements ProcessRunner {}

class MockFileSystem extends Mock implements FileSystem {}

class MockDirectory extends Mock implements Directory {}

class MockFile extends Mock implements File {}

class MockLink extends Mock implements Link {}

void main() {
  late MemoryFileSystem fs;
  late MockProcessRunner runner;
  late List<String> logs;

  void logger(String message) => logs.add(message);

  setUp(() {
    fs = MemoryFileSystem();
    runner = MockProcessRunner();
    logs = [];
  });

  group('ProjectNameProcess', () {
    test('getProjectName returns project name when --name is provided', () {
      final process = ProjectNameProcess(log: logger);
      final arguments = ['--name', 'my_app'];
      final result = process.getProjectName(arguments: arguments);
      expect(result, equals('my_app'));
    });

    test('getProjectName throws ArgumentError when --name is missing', () {
      final process = ProjectNameProcess(log: logger);
      final arguments = <String>[];
      expect(
        () => process.getProjectName(arguments: arguments),
        throwsArgumentError,
      );
    });

    group('reserved Dart words (Issue #32)', () {
      test('every word in kReservedDartWords is rejected by the validator', () {
        for (final word in kReservedDartWords) {
          expect(
            () => validateProjectName(word),
            throwsArgumentError,
            reason: 'the reserved word "$word" must be rejected',
          );
          expect(
            () => validateProjectName(word),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('must not be a reserved Dart word'),
              ),
            ),
            reason: 'the reserved word "$word" must name the rule',
          );
        }
      });

      test('non-reserved names still pass (class_tools, help, int)', () {
        expect(() => validateProjectName('class_tools'), returnsNormally);
        expect(() => validateProjectName('help'), returnsNormally);
        // `int` is a built-in type, not a reserved word; Flutter's package-name
        // validation does not reject it.
        expect(() => validateProjectName('int'), returnsNormally);
      });
    });
  });

  group('DartProcess', () {
    test('getDartVersionSync returns a version string on success', () {
      final process = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.44.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      final version = process.getDartVersionSync();
      expect(version, equals('3.12.0'));
    });

    test('getDartVersionSync throws on failed detection (nonzero exit)', () {
      final process = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 1, stdout: '', stderr: ''));

      expect(
        () => process.getDartVersionSync(),
        throwsA(isA<SubprocessException>()),
      );
    });
  });

  group('Issue #15: Flutter toolchain Dart version', () {
    test('different PATH dart vs toolchain dart: the toolchain version is '
        'serialized and drives the workspace layout', () {
      // The Flutter toolchain bundles Dart 3.12.0; the CLI never invokes a
      // `dart` binary on PATH (e.g. one reporting 3.14.0).
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.44.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      final version = dart.getDartVersionSync();

      // The machine output is used, not any PATH dart version.
      expect(version, equals('3.12.0'));
      expect(version, isNot(contains('^')));
      verifyNever(() => runner.runSync('dart', any()));

      // The serialized manifests use the toolchain version, and the glob
      // layout is always emitted (every supported toolchain is >= 3.12).
      final workspace = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      workspace.createRootPubspecSync(dartVersion: version, projectName: 'app');
      final content = fs.file('pubspec.yaml').readAsStringSync();
      expect(content, contains('sdk: ^3.12.0'));
      expect(content, isNot(contains('^^')));
      expect(content, contains('- packages/*'));
      expect(content, isNot(contains('- packages/core')));
    });

    test(
      'machine output is preferred over the text output of flutter --version',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.44.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          ),
        );
        // A text output that would report a different version must not win.
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.14.0',
            stderr: '',
          ),
        );

        expect(dart.getDartVersionSync(), equals('3.12.0'));
      },
    );

    test(
      'machine output falls back to the text parse when dart_version is missing',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: '{"channel": "stable", "output": []}',
            stderr: '',
          ),
        );
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0 (stable)',
            stderr: '',
          ),
        );

        expect(dart.getDartVersionSync(), equals('3.12.0'));
      },
    );

    test(
      'machine output falls back to the text parse when JSON is malformed',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.44.0", "flutterRoot": "/opt/flutter", "dartSdkVersion": "3.12.0"',
            stderr: '',
          ),
        );
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(exitCode: 0, stdout: 'Dart 3.12.0', stderr: ''),
        );

        expect(dart.getDartVersionSync(), equals('3.12.0'));
      },
    );

    test(
      'missing machine dart_version and unparseable text → actionable throw',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(exitCode: 0, stdout: '{}', stderr: ''),
        );
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Flutter is busy',
            stderr: '',
          ),
        );

        expect(
          () => dart.getDartVersionSync(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'msg',
              contains('Flutter toolchain'),
            ),
          ),
        );
      },
    );

    test('malformed machine JSON and unparseable text → actionable throw', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(exitCode: 0, stdout: 'not json at all', stderr: ''),
      );
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(exitCode: 0, stdout: 'no version here', stderr: ''),
      );

      expect(
        () => dart.getDartVersionSync(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('Flutter toolchain'),
          ),
        ),
      );
    });

    test('machine output cannot be started → actionable throw', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenThrow(Exception('no such executable'));

      expect(
        () => dart.getDartVersionSync(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('Flutter toolchain'),
          ),
        ),
      );
    });

    test(
      'unsupported machine version (3.0.0) → actionable throw, no filesystem writes',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.30.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.0.0"}',
            stderr: '',
          ),
        );

        expect(
          () => dart.getDartVersionSync(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'msg',
              contains('3.12.0'),
            ),
          ),
        );
      },
    );

    test(
      'unsupported text version below the floor (3.5.0) → actionable throw',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(exitCode: 0, stdout: '{}', stderr: ''),
        );
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.5.0',
            stderr: '',
          ),
        );

        expect(
          () => dart.getDartVersionSync(),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'msg',
              contains('3.12.0'),
            ),
          ),
        );
      },
    );

    test(
      'below floor (3.11.x) → error naming both detected and required versions',
      () {
        final dart = DartProcess(runner: runner, log: logger);
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.43.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.11.9"}',
            stderr: '',
          ),
        );

        expect(
          () => dart.getDartVersionSync(),
          throwsA(
            isA<Exception>()
                .having((e) => e.toString(), 'msg', contains('3.11.9'))
                .having((e) => e.toString(), 'msg', contains('3.12.0')),
          ),
        );
      },
    );

    test('malformed version (3.x) in text output → actionable throw', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '{}', stderr: ''));
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.x',
          stderr: '',
        ),
      );

      expect(
        () => dart.getDartVersionSync(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'msg',
            contains('Flutter toolchain'),
          ),
        ),
      );
    });

    test('prerelease machine version (3.8.0-dev.0) → actionable throw', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.29.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.8.0-dev.0"}',
          stderr: '',
        ),
      );
      // The text parse must also reject the prerelease token.
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.8.0-dev.0',
          stderr: '',
        ),
      );

      expect(() => dart.getDartVersionSync(), throwsA(isA<Exception>()));
    });

    test('prerelease text version (3.11.0-beta.1) → actionable throw', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '{}', stderr: ''));
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.11.0-beta.1',
          stderr: '',
        ),
      );

      expect(() => dart.getDartVersionSync(), throwsA(isA<Exception>()));
    });

    test('machine output tolerates other plausible Dart version fields', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: '{"dartVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      expect(dart.getDartVersionSync(), equals('3.12.0'));
    });

    test('setup: failed detection stops before any filesystem writes '
        '(workspace never created, cwd restored, exit 1)', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '{}', stderr: ''));
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(exitCode: 0, stdout: 'no version here', stderr: ''),
      );

      expect(
        () => setupRunner.run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // Detection runs before any filesystem write: the workspace folder is
      // never created (no rollback needed) and the invocation directory is
      // restored.
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
      expect(fs.currentDirectory.path, equals('/work'));
      expect(logs, contains(contains('Flutter toolchain')));
      expect(logs, isNot(contains(contains('completed successfully'))));
    });

    test(
      'setup: below-floor toolchain rejected before any filesystem writes',
      () {
        final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

        final initialDir = fs.directory('/work')..createSync();
        fs.currentDirectory = initialDir;

        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Flutter 3.43.0 · channel stable · Dart version: 3.11.9',
            stderr: '',
          ),
        );

        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.43.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.11.9"}',
            stderr: '',
          ),
        );

        expect(
          () => setupRunner.run(['--name', 'my_app']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // The error names the detected and required versions (toolchain source
        // included) and the workspace is never created, cwd is restored, and
        // no scaffolding/lockfile work happens.
        expect(logs, contains(contains('3.11.9')));
        expect(logs, contains(contains('3.12.0')));
        expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
        expect(fs.currentDirectory.path, equals('/work'));
      },
    );

    test(
      'add-package: failed detection stops before scaffolding (manifest untouched)',
      () {
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app\n');
        fs.directory('packages').createSync();

        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(exitCode: 0, stdout: '{}', stderr: ''),
        );
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'no version here',
            stderr: '',
          ),
        );

        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: logger,
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // The root manifest is untouched and no package is created.
        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals('workspace:\n  - my_app\n'),
        );
        expect(fs.directory('packages/new_pkg').existsSync(), isFalse);
        expect(logs, contains(contains('Flutter toolchain')));
      },
    );

    test(
      'add-package: below-floor toolchain rejected before any filesystem writes',
      () {
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app\n');
        fs.directory('packages').createSync();

        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.43.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.11.9"}',
            stderr: '',
          ),
        );
        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Flutter 3.43.0 · channel stable · Dart version: 3.11.9',
            stderr: '',
          ),
        );

        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: logger,
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // The error names the detected and required versions; the root
        // manifest is untouched, no package is created, and no lockfile or
        // directory state changes happened.
        expect(logs, contains(contains('3.11.9')));
        expect(logs, contains(contains('3.12.0')));
        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals('workspace:\n  - my_app\n'),
        );
        expect(fs.directory('packages/new_pkg').existsSync(), isFalse);
        verifyNever(
          () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
        );
      },
    );

    test('root workspace layout is always the glob form (packages/*)', () {
      final workspace = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      workspace.createRootPubspecSync(
        dartVersion: '3.12.0',
        projectName: 'app',
      );

      final content = fs.file('pubspec.yaml').readAsStringSync();
      expect(content, contains('- packages/*'));
      expect(content, isNot(contains('- packages/core')));
      expect(content, contains('sdk: ^3.12.0'));
    });

    test('floor boundary: 3.12.0 (the minimum supported toolchain) passes and '
        'is serialized into every manifest', () {
      final dart = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.44.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      expect(dart.getDartVersionSync(), equals('3.12.0'));

      final workspace = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      workspace.createRootPubspecSync(
        dartVersion: '3.12.0',
        projectName: 'app',
      );
      final rootContent = fs.file('pubspec.yaml').readAsStringSync();
      expect(rootContent, contains('sdk: ^3.12.0'));
      expect(rootContent, contains('flutter: ">=3.44.0"'));
      expect(rootContent, contains('- packages/*'));

      fs.directory('packages/my_pkg').createSync(recursive: true);
      final packageProcess = PackageProcess(
        fs: fs,
        runner: runner,
        log: logger,
      );
      packageProcess.updatePubspecSync(
        packageName: 'my_pkg',
        dartVersion: '3.12.0',
      );
      final packageContent = fs
          .file('packages/my_pkg/pubspec.yaml')
          .readAsStringSync();
      expect(packageContent, contains('sdk: ^3.12.0'));
      expect(packageContent, contains('flutter: ">=3.44.0"'));
      expect(packageContent, contains('flutter_lints: ^6.0.0'));
      expect(packageContent, contains('resolution: workspace'));

      fs.directory('app').createSync(recursive: true);
      final appProcess = FlutterAppProcess(fs: fs, runner: runner, log: logger);
      appProcess.updateFlutterAppPubspecSync(
        dartVersion: '3.12.0',
        projectName: 'app',
      );
      final appContent = fs.file('app/pubspec.yaml').readAsStringSync();
      expect(appContent, contains('sdk: ^3.12.0'));
      expect(appContent, contains('flutter: ">=3.44.0"'));
      expect(appContent, contains('material_ui: ^1.1.0'));
      expect(appContent, contains('resolution: workspace'));
      expect(appContent, contains('core:'));
      expect(appContent, contains('path: ../packages/core'));
    });

    test('manifests contain sdk constraints serialized exactly once', () {
      final workspace = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      workspace.createRootPubspecSync(
        dartVersion: '3.12.0',
        projectName: 'app',
      );
      final rootContent = fs.file('pubspec.yaml').readAsStringSync();
      expect(rootContent, contains('sdk: ^3.12.0'));
      expect(rootContent, isNot(contains('^^')));

      fs.directory('packages/my_pkg').createSync(recursive: true);
      final packageProcess = PackageProcess(
        fs: fs,
        runner: runner,
        log: logger,
      );
      packageProcess.updatePubspecSync(
        packageName: 'my_pkg',
        dartVersion: '3.12.0',
      );
      final packageContent = fs
          .file('packages/my_pkg/pubspec.yaml')
          .readAsStringSync();
      expect(packageContent, contains('sdk: ^3.12.0'));
      expect(packageContent, isNot(contains('^^')));

      fs.directory('app').createSync(recursive: true);
      final appProcess = FlutterAppProcess(fs: fs, runner: runner, log: logger);
      appProcess.updateFlutterAppPubspecSync(
        dartVersion: '3.12.0',
        projectName: 'app',
      );
      final appContent = fs.file('app/pubspec.yaml').readAsStringSync();
      expect(appContent, contains('sdk: ^3.12.0'));
      expect(appContent, isNot(contains('^^')));
      expect(appContent, contains('core:'));
      expect(appContent, contains('path: ../packages/core'));
      expect(appContent, contains('material_ui:'));
    });
  });

  group('FlutterProcess', () {
    test('isFlutterInstalledSync does not throw when Flutter is available', () {
      final process = FlutterProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

      expect(() => process.isFlutterInstalledSync(), returnsNormally);
    });

    test('isFlutterInstalledSync throws when Flutter is not available', () {
      final process = FlutterProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenThrow(Exception());

      expect(() => process.isFlutterInstalledSync(), throwsException);
    });
  });

  group('CommonProcess', () {
    test('deleteFilesSync deletes existing file', () {
      final process = CommonProcess(fs: fs, runner: runner, log: logger);
      final file = fs.file('test.txt')..createSync();
      process.deleteFilesSync(filePath: 'test.txt');
      expect(file.existsSync(), isFalse);
    });
  });

  group('WorkspaceProcess', () {
    test('createPackagesFolderSync creates packages directory', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      process.createPackagesFolderSync();
      expect(fs.directory('packages').existsSync(), isTrue);
    });

    test('createRootPubspecSync writes pubspec.yaml', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      process.createRootPubspecSync(dartVersion: '3.12.0', projectName: 'app');
      final file = fs.file('pubspec.yaml');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('name: _'));
    });

    test('createRootPubspecSync always emits the glob workspace layout', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      process.createRootPubspecSync(dartVersion: '3.12.0', projectName: 'app');
      final content = fs.file('pubspec.yaml').readAsStringSync();
      expect(content, contains('- packages/*'));
      expect(content, isNot(contains('- packages/core')));
    });

    test('updateRootPubspecSync skips addition if packages/* is present', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs.file('pubspec.yaml').writeAsStringSync('''
name: _
workspace:
  - app
  - packages/*
''');

      process.updateRootPubspecSync(packageName: 'new_pkg');

      final content = fs.file('pubspec.yaml').readAsStringSync();
      expect(content, isNot(contains('- packages/new_pkg')));
      expect(logs, contains(contains('Wildcard "packages/*" detected')));
    });

    test('updateRootPubspecSync appends new package to workspace section', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs.file('pubspec.yaml').writeAsStringSync('''
name: _
workspace:
  - app
  - packages/core
''');

      process.updateRootPubspecSync(packageName: 'new_pkg');

      final content = fs.file('pubspec.yaml').readAsStringSync();
      expect(content, contains('- packages/new_pkg'));
      expect(content, contains('- packages/core'));
    });

    test('updateRootPubspecSync does not add duplicate package', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs.file('pubspec.yaml').writeAsStringSync('''
name: _
workspace:
  - packages/existing
''');

      process.updateRootPubspecSync(packageName: 'existing');

      final content = fs.file('pubspec.yaml').readAsStringSync();
      final occurrences = 'packages/existing'.allMatches(content).length;
      expect(occurrences, equals(1));
    });

    test('updateRootPubspecSync throws when workspace section is missing', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs.file('pubspec.yaml').writeAsStringSync('name: _');

      expect(
        () => process.updateRootPubspecSync(packageName: 'any'),
        throwsException,
      );
    });
  });

  group('PackageProcess', () {
    test('createPackageSync runs flutter create', () {
      final process = PackageProcess(fs: fs, runner: runner, log: logger);
      when(
        () => runner.runSync(
          'flutter',
          ['create', '--template=package', 'my_pkg'],
          workingDirectory: 'packages',
          runInShell: true,
        ),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

      process.createPackageSync(packageName: 'my_pkg');

      verify(
        () => runner.runSync(
          'flutter',
          ['create', '--template=package', 'my_pkg'],
          workingDirectory: 'packages',
          runInShell: true,
        ),
      ).called(1);
    });

    test('updatePubspecSync writes pubspec.yaml with workspace resolution', () {
      final process = PackageProcess(fs: fs, runner: runner, log: logger);
      fs.directory('packages/my_pkg').createSync(recursive: true);

      process.updatePubspecSync(packageName: 'my_pkg', dartVersion: '3.12.0');

      final file = fs.file('packages/my_pkg/pubspec.yaml');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('name: my_pkg'));
      expect(content, contains('resolution: workspace'));
      expect(content, contains('sdk: ^3.12.0'));
      expect(content, contains('flutter: ">=3.44.0"'));
      expect(content, contains('flutter:'));
      expect(content, contains('sdk: flutter'));
      expect(content, contains('flutter_test:'));
      expect(content, contains('flutter_lints: ^6.0.0'));
    });
  });

  group('FlutterAppProcess (Issue #16: generated app passes analyze and test)', () {
    test(
      'updateFlutterAppWidgetTestSync writes test/widget_test.dart exercising the starter UI',
      () {
        final process = FlutterAppProcess(fs: fs, runner: runner, log: logger);
        fs.directory('my_app/test').createSync(recursive: true);

        process.updateFlutterAppWidgetTestSync(projectName: 'my_app');

        final file = fs.file('my_app/test/widget_test.dart');
        expect(file.existsSync(), isTrue);
        final content = file.readAsStringSync();
        expect(content, contains('package:flutter_test/flutter_test.dart'));
        expect(content, contains('package:material_ui/material_ui.dart'));
        expect(content, contains('package:my_app/main.dart'));
        expect(
          content,
          contains("testWidgets('Counter increments smoke test'"),
        );
        expect(content, contains('Icons.add'));
        // The test file is written to the app's test/ directory, not elsewhere.
        expect(fs.file('my_app/widget_test.dart').existsSync(), isFalse);
      },
    );

    test(
      'updateFlutterAppWidgetSync writes a main.dart that uses the core package',
      () {
        final process = FlutterAppProcess(fs: fs, runner: runner, log: logger);
        fs.directory('my_app/lib').createSync(recursive: true);

        process.updateFlutterAppWidgetSync(projectName: 'my_app');

        final file = fs.file('my_app/lib/main.dart');
        expect(file.existsSync(), isTrue);
        final content = file.readAsStringSync();
        expect(content, contains('package:core/core.dart'));
        expect(content, contains('material_ui'));
        expect(content, contains('This is the flutter_workspaces_cli'));
        expect(content, contains('_count'));
        expect(content, contains('Icons.add'));
      },
    );

    test('updateAnalysisOptionsFileSync: legacy plugins removed', () {
      final process = FlutterAppProcess(fs: fs, runner: runner, log: logger);
      fs.directory('my_app').createSync(recursive: true);

      process.updateAnalysisOptionsFileSync(projectName: 'my_app');

      final file = fs.file('my_app/analysis_options.yaml');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, isNot(contains('plugins:')));
      expect(content, isNot(contains('custom_lint')));
      expect(content, contains('exclude:'));
      expect(content, contains('build/**'));
      expect(content, contains('flutter_lints'));
    });
  });

  group('AddPackageRunner (Issue #13: rollback on failure)', () {
    // A valid workspace root (manifest with a "workspace:" section and a
    // "packages" directory) shared by most Issue #13 tests.
    void stubSuccessfulFlutter() {
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });
    }

    test(
      'rejects an invalid root before scaffolding (no Flutter/Dart call)',
      () {
        // No pubspec.yaml at all.
        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: logger,
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>()),
        );
        expect(logs, contains(contains('Workspace root not found')));
        verifyNever(() => runner.runSync(any(), any()));

        // A pubspec.yaml without a "workspace:" section is also rejected.
        fs.file('pubspec.yaml').writeAsStringSync('name: my_app\n');
        fs.directory('packages').createSync();
        logs.clear();
        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: logger,
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>()),
        );
        expect(logs, contains(contains('Workspace root not found')));
        verifyNever(() => runner.runSync(any(), any()));
      },
    );

    test('refuses an occupied target before scaffolding', () {
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - app\n');
      fs.directory('packages/new_pkg').createSync(recursive: true);
      fs.file('packages/new_pkg/kept.txt').writeAsStringSync('keep me');

      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      expect(logs, contains(contains('already exists')));
      // The existing package is untouched.
      expect(
        fs.file('packages/new_pkg/kept.txt').readAsStringSync(),
        equals('keep me'),
      );
      verifyNever(() => runner.runSync(any(), any()));
    });

    test('failure in creation leaves root manifest and lockfile intact, and '
        'removes the partial package directory', () {
      fs
          .file('pubspec.yaml')
          .writeAsStringSync('workspace:\n  - app\n  - packages/core\n');
      fs.file('pubspec.lock').writeAsStringSync('ORIGINAL-LOCK\n');
      fs.directory('packages').createSync();

      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          'flutter',
          ['create', '--template=package', 'new_pkg'],
          workingDirectory: 'packages',
          runInShell: true,
        ),
      ).thenAnswer((_) {
        // Partial scaffold: the directory and an artifact are left behind
        // before the command fails.
        fs.directory('packages/new_pkg').createSync(recursive: true);
        fs.file('packages/new_pkg/artifact.txt').writeAsStringSync('x');
        return ProcessRunnerResult(
          exitCode: 2,
          stdout: 'package create failed',
          stderr: '',
        );
      });

      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The root manifest and lockfile are unchanged.
      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals('workspace:\n  - app\n  - packages/core\n'),
      );
      expect(
        fs.file('pubspec.lock').readAsStringSync(),
        equals('ORIGINAL-LOCK\n'),
      );
      // The partial package directory is removed.
      expect(fs.directory('packages/new_pkg').existsSync(), isFalse);
    });

    test('failure in pub get leaves manifest and lockfile intact and allows a '
        'clean retry', () {
      fs
          .file('pubspec.yaml')
          .writeAsStringSync('workspace:\n  - app\n  - packages/core\n');
      fs.file('pubspec.lock').writeAsStringSync('ORIGINAL-LOCK\n');
      fs.directory('packages').createSync();

      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });
      when(
        () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(exitCode: 2, stdout: 'pub get failed', stderr: ''),
      );

      // First attempt fails in dependency resolution.
      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // Rollback restores the original manifest and lockfile, and removes the
      // created package directory.
      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals('workspace:\n  - app\n  - packages/core\n'),
      );
      expect(
        fs.file('pubspec.lock').readAsStringSync(),
        equals('ORIGINAL-LOCK\n'),
      );
      expect(fs.directory('packages/new_pkg').existsSync(), isFalse);

      // Clean retry succeeds (the reserved path is free again).
      when(
        () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        returnsNormally,
      );

      expect(fs.file('packages/new_pkg/pubspec.yaml').existsSync(), isTrue);
      final manifest = fs.file('pubspec.yaml').readAsStringSync();
      final occurrences = 'packages/new_pkg'.allMatches(manifest).length;
      expect(occurrences, equals(1));
    });

    test('explicit member list: successful addition registers the package '
        'exactly once', () {
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app\n');
      fs.directory('packages').createSync();
      stubSuccessfulFlutter();

      AddPackageRunner(
        fs: fs,
        runner: runner,
        log: logger,
      ).run(['--name', 'new_pkg']);

      final manifest = fs.file('pubspec.yaml').readAsStringSync();
      expect('packages/new_pkg'.allMatches(manifest).length, equals(1));
      expect(manifest, contains('- packages/new_pkg'));
      expect(logs, contains(contains('added successfully')));
    });

    test(
      'explicit member list: already-registered package is not duplicated',
      () {
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'workspace:\n  - my_app\n  - packages/new_pkg\n',
            );
        fs.directory('packages').createSync();
        stubSuccessfulFlutter();

        AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']);

        final manifest = fs.file('pubspec.yaml').readAsStringSync();
        // No duplicate entry was appended.
        expect('packages/new_pkg'.allMatches(manifest).length, equals(1));
        expect(logs, contains(contains('already in the workspace')));
      },
    );

    test('wildcard workspace: rollback leaves the root manifest unchanged, '
        'removes the package directory, and restores the lockfile', () {
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - packages/*\n');
      fs.file('pubspec.lock').writeAsStringSync('ORIGINAL-LOCK\n');
      fs.directory('packages').createSync();

      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });
      when(
        () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(exitCode: 2, stdout: 'pub get failed', stderr: ''),
      );

      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // Root manifest unchanged (no manual entry existed for the wildcard).
      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals('workspace:\n  - packages/*\n'),
      );
      // Lockfile restored to its original content.
      expect(
        fs.file('pubspec.lock').readAsStringSync(),
        equals('ORIGINAL-LOCK\n'),
      );
      // The new package directory is removed.
      expect(fs.directory('packages/new_pkg').existsSync(), isFalse);
    });

    test('wildcard workspace: successful addition does not append a manual '
        'entry', () {
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - packages/*\n');
      fs.directory('packages').createSync();
      stubSuccessfulFlutter();

      AddPackageRunner(
        fs: fs,
        runner: runner,
        log: logger,
      ).run(['--name', 'new_pkg']);

      final manifest = fs.file('pubspec.yaml').readAsStringSync();
      expect(manifest, equals('workspace:\n  - packages/*\n'));
      expect(logs, contains(contains('Wildcard')));
    });

    test('cleanup failure is reported alongside the original error, not '
        'swallowed', () {
      final mockFs = MockFileSystem();
      final baseDir = MockDirectory();
      final packagesDir = MockDirectory();
      final reservedDir = MockDirectory();
      final rootFile = MockFile();
      final targetFile = MockFile();
      final targetLink = MockLink();
      final lockFile = MockFile();
      final runner2 = MockProcessRunner();
      final logs2 = <String>[];

      // Sentinel links used by the workspace lock (acquire + release) and the
      // destination reservation. The stub is stateful: acquisition records the
      // sentinel as created so release actually deletes it (a plain
      // existsSync()→false stub would make release a silent no-op).
      final sentinelLink = MockLink();
      var sentinelCreated = false;
      when(() => mockFs.link(any())).thenReturn(sentinelLink);
      when(() => sentinelLink.createSync(any())).thenAnswer((_) {
        sentinelCreated = true;
      });
      when(() => sentinelLink.existsSync()).thenAnswer((_) => sentinelCreated);
      // Let the rollback's root-pubspec restore exercise cleanly on the mock.
      when(() => rootFile.writeAsStringSync(any())).thenAnswer((_) {});

      when(() => mockFs.currentDirectory).thenReturn(baseDir);
      when(() => baseDir.path).thenReturn('/work');
      when(() => mockFs.file('pubspec.yaml')).thenReturn(rootFile);
      when(() => rootFile.existsSync()).thenReturn(true);
      when(
        () => rootFile.readAsStringSync(),
      ).thenReturn('workspace:\n  - app\n');
      when(() => mockFs.directory('packages')).thenReturn(packagesDir);
      when(() => packagesDir.existsSync()).thenReturn(true);
      when(() => targetFile.existsSync()).thenReturn(false);
      when(() => targetLink.existsSync()).thenReturn(false);
      when(() => packagesDir.childFile(any())).thenReturn(targetFile);
      when(() => packagesDir.childLink(any())).thenReturn(targetLink);
      var reservedCreated = false;
      when(() => mockFs.directory('packages/new_pkg')).thenReturn(reservedDir);
      when(() => reservedDir.path).thenReturn('packages/new_pkg');
      when(() => reservedDir.existsSync()).thenAnswer((_) => reservedCreated);
      when(
        () => reservedDir.deleteSync(recursive: true),
      ).thenThrow(Exception('cannot delete reserved directory'));
      when(() => mockFs.file('pubspec.lock')).thenReturn(lockFile);
      when(() => lockFile.existsSync()).thenReturn(false);

      when(
        () => runner2.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner2.runSync(
          'flutter',
          ['create', '--template=package', 'new_pkg'],
          workingDirectory: 'packages',
          runInShell: true,
        ),
      ).thenAnswer((_) {
        // The partial scaffold runs and leaves the directory behind, then
        // fails — so rollback must attempt the scoped cleanup.
        reservedCreated = true;
        return ProcessRunnerResult(
          exitCode: 2,
          stdout: 'create failed',
          stderr: '',
        );
      });

      final runner = AddPackageRunner(
        fs: mockFs,
        runner: runner2,
        log: logs2.add,
      );

      expect(
        () => runner.run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // Both the original failure and the cleanup failure are reported.
      expect(logs2, contains(contains('create')));
      expect(logs2, contains(contains('Cleanup also failed')));
      expect(logs2, contains(contains('cannot delete reserved directory')));
      // Both the destination reservation and the workspace lock are released:
      // release() deletes the sentinel once per raised reservation.
      verify(() => sentinelLink.deleteSync()).called(2);
    });

    test('failure while writing the package pubspec rolls back cleanly', () {
      final mockFs = MockFileSystem();
      final baseDir = MockDirectory();
      final packagesDir = MockDirectory();
      final reservedDir = MockDirectory();
      final rootFile = MockFile();
      final lockFile = MockFile();
      final pkgPubspecFile = MockFile();
      final targetFile = MockFile();
      final targetLink = MockLink();
      final runner2 = MockProcessRunner();
      final logs2 = <String>[];
      // Sentinel links used by the workspace lock (acquire + release) and the
      // destination reservation. The stub is stateful: acquisition records the
      // sentinel as created so release actually deletes it.
      final sentinelLink = MockLink();
      var sentinelCreated = false;
      when(() => mockFs.link(any())).thenReturn(sentinelLink);
      when(() => sentinelLink.createSync(any())).thenAnswer((_) {
        sentinelCreated = true;
      });
      when(() => sentinelLink.existsSync()).thenAnswer((_) => sentinelCreated);
      const originalContent = 'workspace:\n  - app\n';
      const originalLockContent = 'ORIGINAL-LOCK\n';
      var reservedDirExists = false;
      String? restoredRootContent;
      String? restoredLockContent;

      when(() => mockFs.currentDirectory).thenReturn(baseDir);
      when(() => baseDir.path).thenReturn('/work');
      when(() => mockFs.file('pubspec.yaml')).thenReturn(rootFile);
      when(() => rootFile.existsSync()).thenReturn(true);
      when(() => rootFile.readAsStringSync()).thenReturn(originalContent);
      when(() => rootFile.writeAsStringSync(any())).thenAnswer((invocation) {
        restoredRootContent = invocation.positionalArguments[0] as String;
      });
      when(() => mockFs.directory('packages')).thenReturn(packagesDir);
      when(() => packagesDir.existsSync()).thenReturn(true);
      when(() => packagesDir.childFile(any())).thenReturn(targetFile);
      when(() => targetFile.existsSync()).thenReturn(false);
      when(() => packagesDir.childLink(any())).thenReturn(targetLink);
      when(() => targetLink.existsSync()).thenReturn(false);
      when(() => mockFs.directory('packages/new_pkg')).thenReturn(reservedDir);
      when(() => reservedDir.path).thenReturn('packages/new_pkg');
      when(() => reservedDir.existsSync()).thenAnswer((_) => reservedDirExists);
      when(() => reservedDir.deleteSync(recursive: true)).thenAnswer((_) {
        reservedDirExists = false;
      });
      when(
        () => mockFs.file('packages/new_pkg/pubspec.yaml'),
      ).thenReturn(pkgPubspecFile);
      when(
        () => pkgPubspecFile.writeAsStringSync(any()),
      ).thenThrow(Exception('cannot write package pubspec'));
      when(() => mockFs.file('pubspec.lock')).thenReturn(lockFile);
      when(() => lockFile.existsSync()).thenReturn(true);
      when(() => lockFile.readAsStringSync()).thenReturn(originalLockContent);
      when(() => lockFile.writeAsStringSync(any())).thenAnswer((invocation) {
        restoredLockContent = invocation.positionalArguments[0] as String;
      });

      when(
        () => runner2.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner2.runSync(
          'flutter',
          ['create', '--template=package', 'new_pkg'],
          workingDirectory: 'packages',
          runInShell: true,
        ),
      ).thenAnswer((_) {
        // The mocked flutter create scaffolds the package directory, then
        // the flow fails while rewriting the package pubspec.
        reservedDirExists = true;
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      final runner = AddPackageRunner(
        fs: mockFs,
        runner: runner2,
        log: logs2.add,
      );

      expect(
        () => runner.run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The original error is reported, not hidden by a cleanup problem,
      // and the success message is absent.
      expect(logs2, contains(contains('cannot write package pubspec')));
      expect(logs2, isNot(contains(contains('added successfully'))));

      // The root manifest and lockfile are restored byte-identical.
      expect(restoredRootContent, equals(originalContent));
      expect(restoredLockContent, equals(originalLockContent));

      // The reserved package directory is removed.
      expect(reservedDirExists, isFalse);
      verify(() => reservedDir.deleteSync(recursive: true)).called(1);
      // The destination reservation and the workspace lock were both released.
      verify(() => sentinelLink.deleteSync()).called(2);
    });

    test('creation failure (flutter create nonzero exit) leaves the workspace '
        'clean and a clean retry succeeds, registering the package once', () {
      const originalManifest = 'workspace:\n  - app\n  - packages/core\n';
      const originalLock = 'ORIGINAL-LOCK\n';
      fs.file('pubspec.yaml').writeAsStringSync(originalManifest);
      fs.file('pubspec.lock').writeAsStringSync(originalLock);
      fs.directory('packages').createSync();

      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      var failCreate = true;
      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          // Partial scaffold: the directory and an artifact are left behind
          // before the command fails.
          fs.directory(path).createSync(recursive: true);
          if (failCreate) {
            return ProcessRunnerResult(
              exitCode: 2,
              stdout: 'package create failed',
              stderr: '',
            );
          }
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      // First attempt: flutter create fails partway through the scaffold.
      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The workspace is back in a clean state.
      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals(originalManifest),
      );
      expect(fs.file('pubspec.lock').readAsStringSync(), equals(originalLock));
      expect(fs.directory('packages/new_pkg').existsSync(), isFalse);

      // Clean retry: every step succeeds.
      failCreate = false;
      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        returnsNormally,
      );

      expect(fs.file('packages/new_pkg/pubspec.yaml').existsSync(), isTrue);
      final manifest = fs.file('pubspec.yaml').readAsStringSync();
      expect('packages/new_pkg'.allMatches(manifest).length, equals(1));
    });
  });

  group('AddPackageRunner', () {
    test('run successfully adds a package', () {
      final addPackageRunner = AddPackageRunner(
        fs: fs,
        runner: runner,
        log: logger,
      );

      fs.directory('packages').createSync();
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');

      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      addPackageRunner.run(['--name', 'new_pkg']);

      expect(fs.file('packages/new_pkg/pubspec.yaml').existsSync(), isTrue);
      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        contains('- packages/new_pkg'),
      );
      expect(logs, contains(contains('Package "new_pkg" added successfully!')));
    });

    test('run throws when packages directory is missing', () {
      final addPackageRunner = AddPackageRunner(
        fs: fs,
        runner: runner,
        log: logger,
      );

      // A valid workspace root exists, but the "packages" directory is absent.
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');

      expect(
        () => addPackageRunner.run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>()),
      );
      expect(logs, contains(contains('Directory "packages" not found')));
    });

    test('Issue #43: run adds a package when the workspace key is quoted', () {
      final addPackageRunner = AddPackageRunner(
        fs: fs,
        runner: runner,
        log: logger,
      );

      // A valid workspace root whose `workspace:` key is double-quoted — valid
      // YAML that Flutter resolves, which the pre-fix editor missed and reported
      // as a missing workspace section after preflight had already accepted it.
      final originalRoot =
          'name: _\n'
          'description: "root manifest"\n'
          '"workspace":\n'
          '  - packages/core\n'
          '  - packages/feature\n';
      fs.directory('packages').createSync();
      fs.file('pubspec.yaml').writeAsStringSync(originalRoot);

      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      // The command completes successfully for the quoted-key root manifest.
      addPackageRunner.run(['--name', 'new_pkg']);

      // The generated package exists ...
      expect(fs.file('packages/new_pkg/pubspec.yaml').existsSync(), isTrue);

      // ... and the new member was appended to the quoted-key list, with the
      // quoted key spelling and the unrelated root content preserved.
      final after = fs.file('pubspec.yaml').readAsStringSync();
      expect(
        after,
        equals(
          'name: _\n'
          'description: "root manifest"\n'
          '"workspace":\n'
          '  - packages/core\n'
          '  - packages/feature\n'
          '  - packages/new_pkg\n',
        ),
      );
      // The new member appears exactly once, and the quoted key / unrelated
      // content are intact.
      expect(after.split('packages/new_pkg').length - 1, equals(1));
      expect(after, contains('"workspace":'));
      expect(after, contains('description: "root manifest"'));
      expect(logs, contains(contains('Package "new_pkg" added successfully!')));
    });
  });

  group('SetupRunner', () {
    test('run successfully completes simple workflow', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      // Setup initial directory
      final initialDir = fs.directory('/test')..createSync();
      fs.currentDirectory = initialDir;

      // Mock dart version
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      // Mock flutter version check
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

      // Mock other flutter commands
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final executable = invocation.positionalArguments[0] as String;
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      try {
        setupRunner.run(['--name', 'test_app']);
      } catch (e) {
        print('Logs:');
        logs.forEach(print);
        rethrow;
      }

      expect(fs.directory('/test/test_app_workspaces').existsSync(), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Issue #11: protect existing workspace directories during setup and rollback.
  // ---------------------------------------------------------------------------
  group('CommonProcess.revertAllProcesses (Issue #11: scoped rollback)', () {
    test(
      'surfaces a cleanup error (returns it) instead of swallowing/throwing',
      () {
        final mockFs = MockFileSystem();
        final mockDir = MockDirectory();

        when(() => mockDir.existsSync()).thenReturn(true);
        when(() => mockDir.path).thenReturn('/work/app_workspaces');
        when(() => mockDir.deleteSync(recursive: true)).thenAnswer((_) {
          throw Exception('cannot delete reserved directory');
        });

        final common = CommonProcess(fs: mockFs, runner: runner, log: logger);

        // The cleanup error must be returned (surfaced) rather than thrown,
        // so the original failure can be reported alongside it.
        final cleanupError = common.revertAllProcesses(
          reservedDirectory: mockDir,
        );

        expect(cleanupError, isNotNull);
        expect(cleanupError, isA<Exception>());
        expect(logs, isNot(contains(contains('Failed to clean up'))));
      },
    );

    test('removes only the exact reserved directory when cleanup succeeds', () {
      final common = CommonProcess(fs: fs, runner: runner, log: logger);
      final reserved = fs.directory('/work/app_workspaces')
        ..createSync(recursive: true);
      final sibling = fs.file('/work/sibling.txt')..createSync();

      final cleanupError = common.revertAllProcesses(
        reservedDirectory: reserved,
      );

      expect(cleanupError, isNull);
      expect(fs.directory('/work/app_workspaces').existsSync(), isFalse);
      // A sibling directory/file is never touched.
      expect(sibling.existsSync(), isTrue);
      expect(fs.directory('/work').existsSync(), isTrue);
    });
  });

  group('SetupRunner (Issue #11: workspace protection)', () {
    test('(a) a pre-existing target is rejected, untouched, and runs no '
        'Flutter/Dart command', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      // A pre-existing workspace with a user file at the target path.
      final userFile = fs.file('/work/my_app_workspaces/config.yaml');
      userFile.createSync(recursive: true);
      userFile.writeAsStringSync('user: data\n');

      expect(
        () => setupRunner.run(['--name', 'my_app']),
        throwsA(isA<ExitException>()),
      );

      // The existing workspace and its user file are left untouched.
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isTrue);
      expect(
        fs.file('/work/my_app_workspaces/config.yaml').readAsStringSync(),
        equals('user: data\n'),
      );

      // No Flutter/Dart process was invoked for the rejected attempt.
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      );
      expect(logs, contains(contains('already exists')));
    });

    test('(b) a partial scaffold removes only the reserved dir, preserves the '
        'invocation dir, and restores the working directory', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      // A sibling the rollback must NOT remove.
      fs.file('/work/keep_me.txt').createSync();

      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      // The Flutter app scaffold fails mid-way, forcing a rollback.
      when(
        () => runner.runSync(
          'flutter',
          ['create', 'partial_app'],
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenThrow(Exception('flutter create failed'));

      expect(
        () => setupRunner.run(['--name', 'partial_app']),
        throwsA(isA<ExitException>()),
      );

      // Only the reserved workspace directory was removed.
      expect(
        fs.directory('/work/partial_app_workspaces').existsSync(),
        isFalse,
      );

      // The invocation directory and its sibling are preserved.
      expect(fs.directory('/work').existsSync(), isTrue);
      expect(fs.file('/work/keep_me.txt').existsSync(), isTrue);

      // The working directory was restored to the invocation directory.
      expect(fs.currentDirectory.path, equals('/work'));
    });

    test('(c) a cleanup failure is surfaced alongside the original failure, '
        'not swallowed', () {
      final mockFs = MockFileSystem();
      final baseDir = MockDirectory();
      final reservedDir = MockDirectory();
      final childFile = MockFile();
      final childLink = MockLink();
      final runner2 = MockProcessRunner();
      final logs2 = <String>[];

      // The workspace reservation sentinels. Two distinct paths are claimed in
      // this run: the beside-sentinel that guards the reserved directory
      // (`/work/.compete_app_workspaces.reserved`) and the workspace-wide lock
      // the add-package flow also takes. In this mock, `currentDirectory` reads
      // always resolve to the invocation dir `/work`, so the lock resolves to
      // `/work/.flutter_workspaces_cli.lock` here (the real filesystem nests it
      // inside the reserved dir; the real-fs tests exercise that). Each sentinel
      // is a stateful stub: acquisition records it as created so release actually
      // deletes it. Routing each path to its own mock keeps the two releases
      // independent, so the single-delete verification below is precise.
      final sentinelLink = MockLink();
      var sentinelCreated = false;
      final lockLink = MockLink();
      var lockCreated = false;
      when(
        () => mockFs.link('/work/.compete_app_workspaces.reserved'),
      ).thenReturn(sentinelLink);
      when(
        () => mockFs.link('/work/.flutter_workspaces_cli.lock'),
      ).thenReturn(lockLink);
      when(() => sentinelLink.createSync(any())).thenAnswer((_) {
        sentinelCreated = true;
      });
      when(() => sentinelLink.existsSync()).thenAnswer((_) => sentinelCreated);
      when(() => lockLink.createSync(any())).thenAnswer((_) {
        lockCreated = true;
      });
      when(() => lockLink.existsSync()).thenAnswer((_) => lockCreated);

      // currentDirectory reads return baseDir; the restore setter is a no-op on
      // the mock, so the rollback path exercises without touching it.
      when(() => mockFs.currentDirectory).thenReturn(baseDir);

      when(
        () => baseDir.childDirectory('compete_app_workspaces'),
      ).thenReturn(reservedDir);
      when(() => baseDir.childFile(any())).thenReturn(childFile);
      when(() => baseDir.childLink(any())).thenReturn(childLink);
      when(() => baseDir.path).thenReturn('/work');
      when(() => childFile.existsSync()).thenReturn(false);
      when(() => childLink.existsSync()).thenReturn(false);

      // The reserved directory is created on the happy path and then cannot be
      // deleted, so rollback surfaces a cleanup error.
      var reservedCreated = false;
      when(() => reservedDir.existsSync()).thenAnswer((_) => reservedCreated);
      when(() => reservedDir.createSync()).thenAnswer((_) {
        reservedCreated = true;
      });
      when(() => reservedDir.absolute).thenReturn(reservedDir);
      when(() => reservedDir.path).thenReturn('/work/compete_app_workspaces');
      when(
        () => reservedDir.deleteSync(recursive: true),
      ).thenThrow(Exception('cannot delete reserved directory'));

      when(
        () => runner2.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner2.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      // The app scaffold fails mid-way, forcing a rollback that then fails too.
      when(
        () => runner2.runSync(
          'flutter',
          ['create', 'compete_app'],
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenThrow(Exception('flutter create failed'));

      final setupRunner = SetupRunner(
        fs: mockFs,
        runner: runner2,
        log: logs2.add,
      );

      expect(
        () => setupRunner.run(['--name', 'compete_app']),
        throwsA(isA<ExitException>()),
      );

      // Both the original failure and the cleanup failure are reported.
      expect(logs2, contains(contains('Failed to create Flutter app')));
      expect(logs2, contains(contains('Cleanup also failed')));
      expect(logs2, contains(contains('cannot delete reserved directory')));
      // The workspace reservation sentinel is deleted on the failure exit path.
      verify(() => sentinelLink.deleteSync()).called(1);
      // ...and so is the workspace lock the add-package flow also takes: a
      // failed setup must release it too, so a later retry is never blocked.
      verify(() => lockLink.deleteSync()).called(1);
    });

    test('(d) two attempts for the same name: exactly one succeeds, the '
        'other is rejected', () {
      // Attempt 1 succeeds and populates the workspace.
      final runner1 = MockProcessRunner();
      final logs1 = <String>[];

      when(
        () => runner1.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner1.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner1.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final executable = invocation.positionalArguments[0] as String;
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      final setupRunner1 = SetupRunner(fs: fs, runner: runner1, log: logs1.add);
      setupRunner1.run(['--name', 'compete_app']);

      final reserved = fs.directory('/work/compete_app_workspaces');
      expect(reserved.existsSync(), isTrue);
      expect(
        fs.file('/work/compete_app_workspaces/pubspec.yaml').existsSync(),
        isTrue,
      );

      // Attempt 2 reuses the same name; the target is now occupied.
      final runner2 = MockProcessRunner();
      final logs2 = <String>[];
      fs.currentDirectory = initialDir;

      final setupRunner2 = SetupRunner(fs: fs, runner: runner2, log: logs2.add);

      expect(
        () => setupRunner2.run(['--name', 'compete_app']),
        throwsA(isA<ExitException>()),
      );

      // Exactly one succeeded: attempt 1's content is intact and attempt 2 did
      // not touch it or invoke any Flutter/Dart process.
      expect(reserved.existsSync(), isTrue);
      expect(
        fs.file('/work/compete_app_workspaces/pubspec.yaml').existsSync(),
        isTrue,
      );
      verifyNever(() => runner2.runSync('flutter', any()));
      verifyNever(
        () => runner2.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      );
    });

    test('(e) a successful setup restores the working directory to the '
        'invocation directory (success path)', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final executable = invocation.positionalArguments[0] as String;
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      setupRunner.run(['--name', 'my_app']);

      expect(fs.directory('/work/my_app_workspaces').existsSync(), isTrue);
      // The working directory is restored to the invocation directory on the
      // success path (finally block), not left inside the reserved folder.
      expect(fs.currentDirectory.path, equals('/work'));
    });

    test('(f) a file at the target path is rejected, untouched, and runs no '
        'Flutter/Dart command', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      // A pre-existing FILE (not a directory) at the target path.
      final userFile = fs.file('/work/my_app_workspaces');
      userFile.createSync();
      userFile.writeAsStringSync('not a directory\n');

      expect(
        () => setupRunner.run(['--name', 'my_app']),
        throwsA(isA<ExitException>()),
      );

      // The existing file is left untouched.
      expect(fs.file('/work/my_app_workspaces').existsSync(), isTrue);
      expect(
        fs.file('/work/my_app_workspaces').readAsStringSync(),
        equals('not a directory\n'),
      );

      // No Flutter/Dart process was invoked for the rejected attempt.
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      );
      expect(logs, contains(contains('already exists')));
    });

    test('(g) a dangling link at the target path is rejected and runs no '
        'Flutter/Dart command', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      // A dangling link (target does not exist) at the target path.
      final link = fs.link('/work/my_app_workspaces');
      link.createSync('/nonexistent/target');

      expect(
        () => setupRunner.run(['--name', 'my_app']),
        throwsA(isA<ExitException>()),
      );

      // The dangling link is left in place.
      expect(fs.link('/work/my_app_workspaces').existsSync(), isTrue);

      // No Flutter/Dart process was invoked for the rejected attempt.
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      );
      expect(logs, contains(contains('already exists')));
    });
  });

  // ---------------------------------------------------------------------------
  // Issue #44: preserve permission and I/O errors when setup acquires the shared
  // workspace lock. The inner lock is acquired *after* the outer workspace
  // reservation succeeds, so the runner must keep the two failure kinds distinct:
  // an occupied lock is the busy/retry diagnostic, while a permission/IO error
  // that prevented the claim is reported as such (naming the path and cause)
  // and must NOT suggest removing a reservation that was never created.
  // ---------------------------------------------------------------------------
  group('SetupRunner (Issue #44: preserve lock permission/IO errors)', () {
    // The inner lock lives inside the just-reserved workspace directory, so on
    // this filesystem it resolves to this path once the working directory has
    // moved into the reserved folder.
    const lockPath = '/work/my_app_workspaces/.flutter_workspaces_cli.lock';

    void stubToolchain(MockProcessRunner runner) {
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
    }

    test('an occupied inner workspace lock surfaces the busy/retry diagnostic, '
        'rolls back, and releases the outer reservation', () {
      // A contending run already holds the lock: the moment setup attempts the
      // exclusive claim, the lock sentinel exists, so setup's claim fails and
      // the existence probe sees it present -> contended. Created as a link
      // because the in-memory backend probes the sentinel as a link.
      late MemoryFileSystem fs;
      var armed = false;
      fs = MemoryFileSystem(
        opHandle: (context, op) {
          if (op == FileSystemOp.create && context == lockPath && !armed) {
            armed = true;
            fs.link(lockPath).createSync('reserved');
          }
        },
      );
      fs.directory('/work').createSync();
      // An unrelated path that must survive the rollback untouched.
      final sibling = fs.file('/work/notes.txt')..writeAsStringSync('keep me');
      fs.currentDirectory = fs.directory('/work');

      final runner = MockProcessRunner();
      stubToolchain(runner);
      final logs = <String>[];

      expect(
        () => SetupRunner(
          fs: fs,
          runner: runner,
          log: logs.add,
          errorLog: logs.add,
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The busy/retry diagnostic names the lock path and the recovery step.
      expect(
        logs,
        contains(contains('The workspace lock is already reserved')),
      );
      expect(logs, contains(contains(lockPath)));
      expect(logs, contains(contains('remove that file manually')));

      // Setup stopped before scaffolding: no `flutter create` ran and the run
      // did not complete.
      expect(
        logs,
        isNot(contains(contains('Flutter workspace setup completed'))),
      );
      verifyNever(
        () => runner.runSync(
          'flutter',
          ['create', 'my_app'],
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: true,
        ),
      );

      // The partial workspace was rolled back, the outer reservation was
      // released, and the unrelated sibling was left intact.
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
      expect(
        fs.file('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );
      expect(sibling.readAsStringSync(), equals('keep me'));
    });

    test('an I/O failure acquiring the inner workspace lock reports the lock path '
        'and the original cause, with no stale-lock removal instruction, and '
        'rolls back', () {
      // A genuine permission/IO error prevents the lock from being created at
      // all: the claim throws and the sentinel is never written, so the
      // existence probe sees "not claimed" and the failure classifies as
      // ioError (not contended).
      late MemoryFileSystem fs;
      fs = MemoryFileSystem(
        opHandle: (context, op) {
          if (op == FileSystemOp.create && context == lockPath) {
            throw io.FileSystemException('permission denied', context);
          }
        },
      );
      fs.directory('/work').createSync();
      final sibling = fs.file('/work/notes.txt')..writeAsStringSync('keep me');
      fs.currentDirectory = fs.directory('/work');

      final runner = MockProcessRunner();
      stubToolchain(runner);
      final logs = <String>[];

      expect(
        () => SetupRunner(
          fs: fs,
          runner: runner,
          log: logs.add,
          errorLog: logs.add,
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The ioError diagnostic names the lock path, reports the original cause,
      // and is the "could not be reserved" wording — NOT the busy/retry one.
      expect(
        logs,
        contains(contains('The workspace lock could not be reserved')),
      );
      expect(logs, contains(contains('permission or file-system error')));
      expect(logs, contains(contains(lockPath)));
      // The original error is retained, not swallowed.
      expect(logs, contains(contains('permission denied')));
      // Crucially, it must NOT tell the user to remove a lock that was never
      // created.
      expect(logs, isNot(contains(contains('remove that file manually'))));
      expect(logs, isNot(contains(contains('is already reserved'))));

      // Setup stopped before scaffolding.
      expect(
        logs,
        isNot(contains(contains('Flutter workspace setup completed'))),
      );
      verifyNever(
        () => runner.runSync(
          'flutter',
          ['create', 'my_app'],
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: true,
        ),
      );

      // The lock was never created, so the loser neither holds nor releases it;
      // the partial workspace is rolled back, the outer reservation is
      // released, and the unrelated sibling is left intact.
      expect(fs.link(lockPath).existsSync(), isFalse);
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
      expect(
        fs.file('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );
      expect(sibling.readAsStringSync(), equals('keep me'));
    });
  });

  // ---------------------------------------------------------------------------
  // Issue #12: fail CLI commands when Flutter subprocesses exit unsuccessfully.
  // ---------------------------------------------------------------------------
  group('Issue #12: fail on Flutter subprocess errors', () {
    test(
      'Flutter version check exits nonzero: downstream steps and success are skipped',
      () {
        final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

        final initialDir = fs.directory('/work')..createSync();
        fs.currentDirectory = initialDir;

        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 1,
            stdout: 'flutter failed to start',
            stderr: 'panic: no flutter',
          ),
        );

        expect(
          () => setupRunner.run(['--name', 'my_app']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // The error message includes the failed operation, exit status, and
        // relevant Flutter output.
        expect(logs, contains(contains('flutter --version')));
        expect(logs, contains(contains('exit code 1')));
        expect(logs, contains(contains('flutter failed to start')));

        // Downstream steps and the success message were skipped.
        expect(logs, isNot(contains(contains('completed successfully'))));
        verifyNever(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        );
        verifyNever(
          () => runner.runSync('flutter', [
            'pub',
            'get',
          ], runInShell: any(named: 'runInShell')),
        );

        // The reserved workspace is cleaned up.
        expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
      },
    );

    test(
      'flutter version check process-start failure gives a clear message',
      () {
        final process = FlutterProcess(runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenThrow(Exception('no such executable'));

        try {
          process.isFlutterInstalledSync();
          fail('expected isFlutterInstalledSync to throw');
        } catch (e) {
          expect(e.toString(), contains('Flutter is not installed'));
        }
      },
    );

    test(
      'createFlutterAppSync exits nonzero: message includes operation, exit status, and output',
      () {
        final process = FlutterAppProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync(
            'flutter',
            ['create', 'my_app'],
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 3,
            stdout: 'create failed',
            stderr: 'boom',
          ),
        );

        try {
          process.createFlutterAppSync(projectName: 'my_app');
          fail('expected createFlutterAppSync to throw');
        } catch (e) {
          expect(e, isA<SubprocessException>());
          expect(e.toString(), contains('flutter create my_app'));
          expect(e.toString(), contains('exit code 3'));
          expect(e.toString(), contains('create failed'));
          expect(e.toString(), contains('boom'));
        }
      },
    );

    test(
      'createFlutterAppSync process-start failure gives a clear message',
      () {
        final process = FlutterAppProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync(
            'flutter',
            ['create', 'my_app'],
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenThrow(Exception('no such executable'));

        try {
          process.createFlutterAppSync(projectName: 'my_app');
          fail('expected createFlutterAppSync to throw');
        } catch (e) {
          expect(e.toString(), contains('could not be started'));
          expect(e.toString(), contains('flutter create my_app'));
        }
      },
    );

    test(
      'createFlutterAppSync exits zero: returns normally and logs success',
      () {
        final process = FlutterAppProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync(
            'flutter',
            ['create', 'my_app'],
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

        expect(
          () => process.createFlutterAppSync(projectName: 'my_app'),
          returnsNormally,
        );
        expect(logs, contains(contains('✅ Flutter app created')));
      },
    );

    test(
      'package create (core) exits nonzero: runner fails, downstream steps and success are skipped',
      () {
        final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

        final initialDir = fs.directory('/work')..createSync();
        fs.currentDirectory = initialDir;

        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          ),
        );
        // The app scaffold and package scaffold both return failing; the setup
        // must fail fast at the app create step (first failure propagates).
        when(
          () => runner.runSync(
            'flutter',
            ['create', 'my_app'],
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 4,
            stdout: 'app create failed',
            stderr: '',
          ),
        );

        expect(
          () => setupRunner.run(['--name', 'my_app']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        expect(logs, contains(contains('flutter create my_app')));
        expect(logs, contains(contains('exit code 4')));
        expect(logs, contains(contains('app create failed')));
        expect(logs, isNot(contains(contains('completed successfully'))));

        // The reserved workspace directory is cleaned up.
        expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
      },
    );

    test(
      'PackageProcess.createPackageSync exits nonzero: message includes operation, exit status, and output',
      () {
        final process = PackageProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync(
            'flutter',
            ['create', '--template=package', 'my_pkg'],
            workingDirectory: 'packages',
            runInShell: true,
          ),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 2,
            stdout: 'pkg create failed',
            stderr: '',
          ),
        );

        try {
          process.createPackageSync(packageName: 'my_pkg');
          fail('expected createPackageSync to throw');
        } catch (e) {
          expect(e, isA<SubprocessException>());
          expect(
            e.toString(),
            contains('flutter create --template=package my_pkg'),
          );
          expect(e.toString(), contains('exit code 2'));
          expect(e.toString(), contains('pkg create failed'));
        }
      },
    );

    test('PackageProcess.createPackageSync exits zero: returns normally', () {
      final process = PackageProcess(fs: fs, runner: runner, log: logger);

      when(
        () => runner.runSync(
          'flutter',
          ['create', '--template=package', 'my_pkg'],
          workingDirectory: 'packages',
          runInShell: true,
        ),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

      expect(
        () => process.createPackageSync(packageName: 'my_pkg'),
        returnsNormally,
      );
    });

    test(
      'addingFlutterDependenciesSync exits nonzero: message includes operation, exit status, and output',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', [
            'pub',
            'add',
            'cupertino_icons',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(exitCode: 2, stdout: 'add failed', stderr: ''),
        );

        try {
          process.addingFlutterDependenciesSync();
          fail('expected addingFlutterDependenciesSync to throw');
        } catch (e) {
          expect(e, isA<SubprocessException>());
          expect(e.toString(), contains('flutter pub add cupertino_icons'));
          expect(e.toString(), contains('exit code 2'));
          expect(e.toString(), contains('add failed'));
        }
      },
    );

    test(
      'addingFlutterDevDependenciesSync exits nonzero: message includes operation, exit status, and output',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', [
            'pub',
            'add',
            '--dev',
            'flutter_lints',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 2,
            stdout: 'dev add failed',
            stderr: '',
          ),
        );

        try {
          process.addingFlutterDevDependenciesSync();
          fail('expected addingFlutterDevDependenciesSync to throw');
        } catch (e) {
          expect(e, isA<SubprocessException>());
          expect(e.toString(), contains('flutter pub add --dev flutter_lints'));
          expect(e.toString(), contains('exit code 2'));
          expect(e.toString(), contains('dev add failed'));
        }
      },
    );

    test(
      'runningFlutterPubGetSync exits nonzero: message includes operation, exit status, and output',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 4,
            stdout: 'pub get failed',
            stderr: '',
          ),
        );

        try {
          process.runningFlutterPubGetSync();
          fail('expected runningFlutterPubGetSync to throw');
        } catch (e) {
          expect(e, isA<SubprocessException>());
          expect(e.toString(), contains('flutter pub get'));
          expect(e.toString(), contains('exit code 4'));
          expect(e.toString(), contains('pub get failed'));
        }
      },
    );

    test(
      'AddPackageRunner: pub get exits nonzero → exits code 1, diagnostic shown, success skipped',
      () {
        final addPackageRunner = AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        );

        fs.directory('packages').createSync();
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace:\n  - app\n  - packages/core');

        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          ),
        );

        when(
          () => runner.runSync(
            'flutter',
            any(),
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenAnswer((invocation) {
          final args = invocation.positionalArguments[1] as List<String>;
          if (args.join(' ') == '--version --machine') {
            return ProcessRunnerResult(
              exitCode: 0,
              stdout:
                  '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
              stderr: '',
            );
          }
          if (args.join(' ') == '--version') {
            return ProcessRunnerResult(
              exitCode: 0,
              stdout: 'Dart SDK version: 3.12.0',
              stderr: '',
            );
          }
          if (args.contains('create')) {
            final packageName = args.last;
            final workingDir =
                invocation.namedArguments[#workingDirectory] as String?;
            final path = workingDir != null
                ? '$workingDir/$packageName'
                : packageName;
            fs.directory(path).createSync(recursive: true);
          }
          return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
        });

        when(
          () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 2,
            stdout: 'pub get failed',
            stderr: '',
          ),
        );

        expect(
          () => addPackageRunner.run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        expect(logs, contains(contains('flutter pub get')));
        expect(logs, contains(contains('exit code 2')));
        expect(logs, contains(contains('pub get failed')));
        expect(logs, isNot(contains(contains('added successfully'))));
      },
    );

    test(
      'AddPackageRunner: package create exits nonzero → exits code 1, diagnostic shown, success skipped',
      () {
        final addPackageRunner = AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        );

        fs.directory('packages').createSync();
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - app');

        when(
          () => runner.runSync('flutter', [
            '--version',
            '--machine',
          ], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          ),
        );
        when(
          () => runner.runSync(
            'flutter',
            ['create', '--template=package', 'new_pkg'],
            workingDirectory: 'packages',
            runInShell: true,
          ),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 2,
            stdout: 'package create failed',
            stderr: '',
          ),
        );

        expect(
          () => addPackageRunner.run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        expect(
          logs,
          contains(contains('flutter create --template=package new_pkg')),
        );
        expect(logs, contains(contains('exit code 2')));
        expect(logs, contains(contains('package create failed')));
        expect(logs, isNot(contains(contains('added successfully'))));
      },
    );

    test('flutter pub add (dependencies) exits nonzero: setup fails fast, '
        'downstream steps and success are skipped, and workspace is cleaned up', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );

      // Everything in the setup path succeeds EXCEPT `flutter pub add
      // cupertino_icons` (the add-dependencies step).
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final executable = invocation.positionalArguments[0] as String;
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (executable == 'flutter' &&
            args.contains('add') &&
            args.contains('cupertino_icons')) {
          return ProcessRunnerResult(
            exitCode: 5,
            stdout: 'dependency resolution failed',
            stderr: '',
          );
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      expect(
        () => setupRunner.run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The diagnostic log shows the operation, exit code, and Flutter output.
      expect(logs, contains(contains('flutter pub add cupertino_icons')));
      expect(logs, contains(contains('exit code 5')));
      expect(logs, contains(contains('dependency resolution failed')));

      // Downstream steps were skipped: the dev-deps add never ran and the
      // success message was not printed.
      verifyNever(
        () => runner.runSync('flutter', [
          'pub',
          'add',
          '--dev',
          'flutter_lints',
        ], runInShell: true),
      );
      expect(logs, isNot(contains(contains('completed successfully'))));

      // The reserved workspace is cleaned up.
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
    });

    test(
      'PackageProcess.createPackageSync process-start failure gives a clear message',
      () {
        final process = PackageProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync(
            'flutter',
            ['create', '--template=package', 'my_pkg'],
            workingDirectory: 'packages',
            runInShell: true,
          ),
        ).thenThrow(Exception('no such executable'));

        try {
          process.createPackageSync(packageName: 'my_pkg');
          fail('expected createPackageSync to throw');
        } catch (e) {
          expect(e.toString(), contains('could not be started'));
          expect(
            e.toString(),
            contains('flutter create --template=package my_pkg'),
          );
          expect(e.toString(), contains('no such executable'));
        }
      },
    );

    test(
      'addingFlutterDependenciesSync process-start failure gives a clear message',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', [
            'pub',
            'add',
            'cupertino_icons',
          ], runInShell: true),
        ).thenThrow(Exception('no such executable'));

        try {
          process.addingFlutterDependenciesSync();
          fail('expected addingFlutterDependenciesSync to throw');
        } catch (e) {
          expect(e.toString(), contains('could not be started'));
          expect(e.toString(), contains('flutter pub add cupertino_icons'));
          expect(e.toString(), contains('no such executable'));
        }
      },
    );

    test(
      'addingFlutterDevDependenciesSync process-start failure gives a clear message',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', [
            'pub',
            'add',
            '--dev',
            'flutter_lints',
          ], runInShell: true),
        ).thenThrow(Exception('no such executable'));

        try {
          process.addingFlutterDevDependenciesSync();
          fail('expected addingFlutterDevDependenciesSync to throw');
        } catch (e) {
          expect(e.toString(), contains('could not be started'));
          expect(e.toString(), contains('flutter pub add --dev flutter_lints'));
          expect(e.toString(), contains('no such executable'));
        }
      },
    );

    test(
      'runningFlutterPubGetSync process-start failure gives a clear message',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);

        when(
          () => runner.runSync('flutter', ['pub', 'get'], runInShell: true),
        ).thenThrow(Exception('no such executable'));

        try {
          process.runningFlutterPubGetSync();
          fail('expected runningFlutterPubGetSync to throw');
        } catch (e) {
          expect(e.toString(), contains('could not be started'));
          expect(e.toString(), contains('flutter pub get'));
          expect(e.toString(), contains('no such executable'));
        }
      },
    );
  });

  group('WorkspaceProcess (Issue #14: YAML-parsed workspace membership)', () {
    test(
      'prefix collision: adding feature does not see feature_tools as present',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace:\n  - packages/feature_tools\n');

        process.updateRootPubspecSync(packageName: 'feature');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals(
            'workspace:\n  - packages/feature_tools\n  - packages/feature\n',
          ),
        );
      },
    );

    test('prefix collision: adding feature_tools alongside feature', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync('workspace:\n  - packages/feature\n');

      process.updateRootPubspecSync(packageName: 'feature_tools');

      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals(
          'workspace:\n  - packages/feature\n  - packages/feature_tools\n',
        ),
      );
    });

    test(
      'quoted flow-style entries parse correctly and a new member is inserted',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace: ["packages/core", "apps/my_app"]\n');

        process.updateRootPubspecSync(packageName: 'new_pkg');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals(
            'workspace: ["packages/core", "apps/my_app", packages/new_pkg]\n',
          ),
        );
      },
    );

    test(
      'inline flow-style list parses as a sequence and a new member is inserted',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace: [packages/lib_a, packages/lib_b]\n');

        process.updateRootPubspecSync(packageName: 'new_pkg');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals(
            'workspace: [packages/lib_a, packages/lib_b, packages/new_pkg]\n',
          ),
        );
      },
    );

    test('empty flow-style list accepts a new member', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs.file('pubspec.yaml').writeAsStringSync('workspace: []\n');

      process.updateRootPubspecSync(packageName: 'new_pkg');

      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals('workspace: [packages/new_pkg]\n'),
      );
    });

    test(
      'a wildcard member with a trailing comment is still a covered wildcard',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'workspace:\n  - packages/*   # wildcard for all packages\n',
            );

        process.updateRootPubspecSync(packageName: 'new_pkg');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals('workspace:\n  - packages/*   # wildcard for all packages\n'),
        );
        expect(logs, contains(contains('Wildcard "packages/*" detected')));
      },
    );

    test('comment text containing a wildcard is not mistaken for a wildcard', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'workspace:\n  - packages/core   # packages/* is NOT a wildcard here\n',
          );

      process.updateRootPubspecSync(packageName: 'new_pkg');

      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals(
          'workspace:\n  - packages/core   # packages/* is NOT a wildcard here\n  - packages/new_pkg\n',
        ),
      );
    });

    test('CRLF file: insertion preserves the CRLF convention and other keys', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: _\r\n\r\nworkspace:\r\n  - app\r\n  - packages/core\r\n\r\ndependencies:\r\n  flutter:\r\n    sdk: flutter\r\n',
          );

      process.updateRootPubspecSync(packageName: 'new_pkg');

      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals(
          'name: _\r\n\r\nworkspace:\r\n  - app\r\n  - packages/core\r\n  - packages/new_pkg\r\n\r\ndependencies:\r\n  flutter:\r\n    sdk: flutter\r\n',
        ),
      );
    });

    test(
      'wildcard entry: packages/* covers packages/any_new and leaves the file unchanged',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace:\n  - packages/*\n');

        process.updateRootPubspecSync(packageName: 'any_new');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals('workspace:\n  - packages/*\n'),
        );
        expect(logs, contains(contains('Wildcard "packages/*" detected')));
      },
    );

    test(
      'wildcard entry: packages/* does not cover apps/other, so insertion happens',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - apps/*\n');

        process.updateRootPubspecSync(packageName: 'other');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals('workspace:\n  - apps/*\n  - packages/other\n'),
        );
      },
    );

    test('unrelated settings and comments are preserved byte-for-byte', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original = """name: _
version: 0.1.0
description: A Dart workspace example
publish_to: none

# A comment about this file
environment:
  sdk: ^3.10.8

workspace:
  - my_app
  - packages/core

dependencies:
  flutter:
    sdk: flutter
""";
      fs.file('pubspec.yaml').writeAsStringSync(original);

      process.updateRootPubspecSync(packageName: 'new_pkg');

      const expected = """name: _
version: 0.1.0
description: A Dart workspace example
publish_to: none

# A comment about this file
environment:
  sdk: ^3.10.8

workspace:
  - my_app
  - packages/core
  - packages/new_pkg

dependencies:
  flutter:
    sdk: flutter
""";
      expect(fs.file('pubspec.yaml').readAsStringSync(), equals(expected));
    });

    test('explicit member layouts are preserved when inserting a new member', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original =
          'workspace:\n  - app\n  # keep this comment\n  - packages/core\n';
      fs.file('pubspec.yaml').writeAsStringSync(original);

      process.updateRootPubspecSync(packageName: 'new_pkg');

      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals(
          'workspace:\n  - app\n  # keep this comment\n  - packages/core\n  - packages/new_pkg\n',
        ),
      );
    });

    test(
      'missing workspace field is rejected with a distinct message before any mutation',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        const original = 'name: _\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        expect(
          () => process.updateRootPubspecSync(packageName: 'any'),
          throwsException,
        );
        try {
          process.updateRootPubspecSync(packageName: 'any');
        } catch (e) {
          expect(e.toString(), contains('missing "workspace:" section'));
        }
        expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
      },
    );

    test(
      'malformed YAML is rejected with a distinct message before any mutation',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        const original = 'workspace:\n  - [unclosed\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        try {
          process.updateRootPubspecSync(packageName: 'any');
          fail('expected updateRootPubspecSync to throw');
        } catch (e) {
          expect(e.toString(), contains('malformed YAML'));
        }
        expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
      },
    );

    test('scalar workspace field is rejected with a distinct message', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original = 'workspace: 123\n';
      fs.file('pubspec.yaml').writeAsStringSync(original);

      try {
        process.updateRootPubspecSync(packageName: 'any');
        fail('expected updateRootPubspecSync to throw');
      } catch (e) {
        expect(e.toString(), contains('must be a sequence of strings'));
        expect(e.toString(), contains('got an integer'));
      }
      expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
    });

    test('map workspace field is rejected with a distinct message', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original = 'workspace: {a: b}\n';
      fs.file('pubspec.yaml').writeAsStringSync(original);

      try {
        process.updateRootPubspecSync(packageName: 'any');
        fail('expected updateRootPubspecSync to throw');
      } catch (e) {
        expect(e.toString(), contains('must be a sequence of strings'));
        expect(e.toString(), contains('got a map'));
      }
      expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
    });

    test(
      'list-of-non-strings workspace field is rejected with a distinct message',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        const original = 'workspace:\n  - "packages/core"\n  - 123\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        try {
          process.updateRootPubspecSync(packageName: 'any');
          fail('expected updateRootPubspecSync to throw');
        } catch (e) {
          expect(e.toString(), contains('member #2 is not a string'));
          expect(e.toString(), contains('got an integer'));
        }
        expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
      },
    );

    test(
      'add-package preflight rejects an invalid workspace field before any scaffolding',
      () {
        final original = 'workspace: 123\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);
        fs.directory('packages').createSync();

        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: logger,
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        expect(logs, contains(contains('Workspace root not found')));
        expect(logs, contains(contains('must be a sequence of strings')));
        verifyNever(() => runner.runSync(any(), any()));
        expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
      },
    );

    test(
      'workspace line with a bracketed comment is not treated as flow-style',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace:  # [draft]\n  - packages/core\n');

        process.updateRootPubspecSync(packageName: 'new_pkg');

        // The edit must keep the list block-style and insert the new member
        // in the block list; the comment must be left byte-for-byte unchanged.
        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'workspace:  # [draft]\n'
            '  - packages/core\n'
            '  - packages/new_pkg\n',
          ),
        );

        // The final file re-parses, with the new member present exactly once.
        final manifest = parseWorkspaceManifest(after);
        expect(manifest.members, equals(['packages/core', 'packages/new_pkg']));
      },
    );

    test(
      'flow-style list with a comment before the closing bracket stays valid',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace: [packages/a,  # note\n]\n');

        process.updateRootPubspecSync(packageName: 'new_pkg');

        final after = fs.file('pubspec.yaml').readAsStringSync();

        // The final file re-parses, with the new member present exactly once,
        // and the comment content is intact.
        expect(
          after,
          equals('workspace: [packages/a, packages/new_pkg  # note\n]\n'),
        );
        final manifest = parseWorkspaceManifest(after);
        expect(manifest.members, equals(['packages/a', 'packages/new_pkg']));
        expect(after, contains('# note'));
      },
    );

    // -------------------------------------------------------------------------
    // Issue #43: quoted workspace keys ("workspace": / 'workspace':).
    // The editor must locate the section through the parsed YAML structure so
    // a quoted key is handled like a plain key, in both block and flow style.
    // -------------------------------------------------------------------------
    test(
      'Issue #43: double-quoted block key inserts a member and keeps unrelated content intact',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        final original =
            'name: _\n'
            'description: "root"\n'
            '"workspace":\n'
            '  - packages/core\n'
            '  - packages/feature\n'
            '\n'
            '# trailing comment\n'
            'dependencies:\n'
            '  flutter: null\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        process.updateRootPubspecSync(packageName: 'new_pkg');

        final after = fs.file('pubspec.yaml').readAsStringSync();

        // The new member is appended to the block list; the existing members,
        // the quoted key spelling, the unrelated keys, the blank line and the
        // comment are all preserved byte-for-byte.
        expect(
          after,
          equals(
            'name: _\n'
            'description: "root"\n'
            '"workspace":\n'
            '  - packages/core\n'
            '  - packages/feature\n'
            '  - packages/new_pkg\n'
            '\n'
            '# trailing comment\n'
            'dependencies:\n'
            '  flutter: null\n',
          ),
        );

        // The new member appears exactly once and the file re-parses.
        expect(after.split('packages/new_pkg').length - 1, equals(1));
        expect(after, contains('"workspace":'));
        expect(after, contains('description: "root"'));
        expect(after, contains('# trailing comment'));
        final manifest = parseWorkspaceManifest(after);
        expect(
          manifest.members,
          equals(['packages/core', 'packages/feature', 'packages/new_pkg']),
        );
      },
    );

    test('Issue #43: single-quoted block key inserts a member', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync("name: _\n'workspace':\n  - packages/core\n");

      process.updateRootPubspecSync(packageName: 'new_pkg');

      expect(
        fs.file('pubspec.yaml').readAsStringSync(),
        equals(
          "name: _\n'workspace':\n  - packages/core\n  - packages/new_pkg\n",
        ),
      );
    });

    test(
      'Issue #43: double-quoted flow key inserts a member into the flow list',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'name: _\n"workspace": [packages/core, packages/feature]\n',
            );

        process.updateRootPubspecSync(packageName: 'new_pkg');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'name: _\n"workspace": [packages/core, packages/feature, packages/new_pkg]\n',
          ),
        );
        expect(after.split('packages/new_pkg').length - 1, equals(1));
      },
    );

    test(
      'Issue #43: single-quoted flow key inserts a member into the flow list',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              "name: _\n'workspace': [packages/core, packages/feature]\n",
            );

        process.updateRootPubspecSync(packageName: 'new_pkg');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            "name: _\n'workspace': [packages/core, packages/feature, packages/new_pkg]\n",
          ),
        );
        expect(after.split('packages/new_pkg').length - 1, equals(1));
      },
    );

    test('Issue #43: double-quoted block key preserves CRLF line endings', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: _\r\n"workspace":\r\n  - packages/core\r\n  - packages/feature\r\n',
          );

      process.updateRootPubspecSync(packageName: 'new_pkg');

      final after = fs.file('pubspec.yaml').readAsStringSync();
      expect(
        after,
        equals(
          'name: _\r\n"workspace":\r\n  - packages/core\r\n  - packages/feature\r\n  - packages/new_pkg\r\n',
        ),
      );
      // Every newline is a CRLF: after stripping CRLF pairs no lone LF remains.
      expect(after.replaceAll('\r\n', ''), isNot(contains('\n')));
    });

    test(
      'Issue #43: a quoted key with a non-sequence value is still rejected',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        final original = 'name: _\n"workspace": 123\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        // Validation runs before any write, so the file is left untouched.
        expect(
          () => process.updateRootPubspecSync(packageName: 'new_pkg'),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('must be a sequence of strings'),
            ),
          ),
        );
        expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
      },
    );

    test(
      'Issue #43: a quoted key with a wildcard member still covers new packages',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        final original = 'name: _\n"workspace":\n  - packages/*\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        process.updateRootPubspecSync(packageName: 'new_pkg');

        // The wildcard covers the new package, so nothing is inserted.
        expect(fs.file('pubspec.yaml').readAsStringSync(), equals(original));
        expect(logs, contains(contains('Wildcard "packages/*" detected')));
      },
    );
  });

  // -----------------------------------------------------------------------------
  // Issue #47: block-style workspace list indentation is preserved on insert.
  // The editor always wrote `  - <member>` regardless of the existing
  // members' indentation, so a four-space list produced an invalid manifest.
  // The new member must use the indentation of the existing sequence entries.
  // -----------------------------------------------------------------------------
  group('Issue #47: block-style list indentation is preserved', () {
    test(
      'four-space block list: new member hyphen aligns with the existing entries',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'name: _\n'
              'workspace:\n'
              '    - demo_app\n'
              '    - packages/core\n',
            );

        process.updateRootPubspecSync(packageName: 'shared_ui');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'name: _\n'
            'workspace:\n'
            '    - demo_app\n'
            '    - packages/core\n'
            '    - packages/shared_ui\n',
          ),
        );
        expect(after.split('packages/shared_ui').length - 1, equals(1));
        expect(
          parseWorkspaceManifest(after).members,
          equals(['demo_app', 'packages/core', 'packages/shared_ui']),
        );
      },
    );

    test('four-space block list with a quoted workspace key', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            "name: _\n'workspace':\n    - demo_app\n    - packages/core\n",
          );

      process.updateRootPubspecSync(packageName: 'shared_ui');

      final after = fs.file('pubspec.yaml').readAsStringSync();
      expect(
        after,
        equals(
          "name: _\n'workspace':\n    - demo_app\n    - packages/core\n"
          '    - packages/shared_ui\n',
        ),
      );
      expect(
        parseWorkspaceManifest(after).members,
        equals(['demo_app', 'packages/core', 'packages/shared_ui']),
      );
    });

    test(
      'four-space block list preserves comments, blank lines and unrelated content byte-for-byte',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        const original =
            'name: _\n'
            '# a comment about the workspace\n'
            'workspace:\n'
            '    # leading comment inside the list\n'
            '    - demo_app\n'
            '    - packages/core\n'
            '\n'
            'dependencies:\n'
            '  flutter:\n'
            '    sdk: flutter\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        process.updateRootPubspecSync(packageName: 'shared_ui');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals(
            'name: _\n'
            '# a comment about the workspace\n'
            'workspace:\n'
            '    # leading comment inside the list\n'
            '    - demo_app\n'
            '    - packages/core\n'
            '    - packages/shared_ui\n'
            '\n'
            'dependencies:\n'
            '  flutter:\n'
            '    sdk: flutter\n',
          ),
        );
      },
    );

    test(
      'four-space block list without a trailing newline keeps the missing newline',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'workspace:\n    - demo_app\n    - packages/core',
            );

        process.updateRootPubspecSync(packageName: 'shared_ui');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'workspace:\n    - demo_app\n    - packages/core\n'
            '    - packages/shared_ui',
          ),
        );
        expect(after.endsWith('\n'), isFalse);
        expect(
          parseWorkspaceManifest(after).members,
          equals(['demo_app', 'packages/core', 'packages/shared_ui']),
        );
      },
    );

    test(
      'four-space block list with CRLF line endings preserves the convention',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'workspace:\r\n    - demo_app\r\n    - packages/core\r\n',
            );

        process.updateRootPubspecSync(packageName: 'shared_ui');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'workspace:\r\n    - demo_app\r\n    - packages/core\r\n'
            '    - packages/shared_ui\r\n',
          ),
        );
        // Every newline is a CRLF: no lone LF remains.
        expect(after.replaceAll('\r\n', ''), isNot(contains('\n')));
      },
    );

    test('column-one block list: new member hyphen starts in column one', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: _\n'
            'workspace:\n'
            '- demo_app\n'
            '- packages/core\n',
          );

      process.updateRootPubspecSync(packageName: 'shared_ui');

      final after = fs.file('pubspec.yaml').readAsStringSync();
      expect(
        after,
        equals(
          'name: _\n'
          'workspace:\n'
          '- demo_app\n'
          '- packages/core\n'
          '- packages/shared_ui\n',
        ),
      );
      expect(after.split('packages/shared_ui').length - 1, equals(1));
      expect(
        parseWorkspaceManifest(after).members,
        equals(['demo_app', 'packages/core', 'packages/shared_ui']),
      );
    });

    test(
      'column-one block list preserves comments, blank lines and unrelated content byte-for-byte',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        const original =
            'name: _\n'
            '# a comment about the workspace\n'
            'workspace:\n'
            '# leading comment inside the list\n'
            '- demo_app\n'
            '- packages/core\n'
            '\n'
            'dependencies:\n'
            '  flutter:\n'
            '    sdk: flutter\n';
        fs.file('pubspec.yaml').writeAsStringSync(original);

        process.updateRootPubspecSync(packageName: 'shared_ui');

        expect(
          fs.file('pubspec.yaml').readAsStringSync(),
          equals(
            'name: _\n'
            '# a comment about the workspace\n'
            'workspace:\n'
            '# leading comment inside the list\n'
            '- demo_app\n'
            '- packages/core\n'
            '- packages/shared_ui\n'
            '\n'
            'dependencies:\n'
            '  flutter:\n'
            '    sdk: flutter\n',
          ),
        );
        expect(
          parseWorkspaceManifest(
            fs.file('pubspec.yaml').readAsStringSync(),
          ).members,
          equals(['demo_app', 'packages/core', 'packages/shared_ui']),
        );
      },
    );

    test(
      'column-one block list without a trailing newline keeps the missing newline',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync('workspace:\n- demo_app\n- packages/core');

        process.updateRootPubspecSync(packageName: 'shared_ui');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'workspace:\n- demo_app\n- packages/core\n'
            '- packages/shared_ui',
          ),
        );
        expect(after.endsWith('\n'), isFalse);
        expect(
          parseWorkspaceManifest(after).members,
          equals(['demo_app', 'packages/core', 'packages/shared_ui']),
        );
      },
    );

    test(
      'column-one block list with CRLF line endings preserves the convention',
      () {
        final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
        fs
            .file('pubspec.yaml')
            .writeAsStringSync(
              'workspace:\r\n- demo_app\r\n- packages/core\r\n',
            );

        process.updateRootPubspecSync(packageName: 'shared_ui');

        final after = fs.file('pubspec.yaml').readAsStringSync();
        expect(
          after,
          equals(
            'workspace:\r\n- demo_app\r\n- packages/core\r\n'
            '- packages/shared_ui\r\n',
          ),
        );
        // Every newline is a CRLF: no lone LF remains.
        expect(after.replaceAll('\r\n', ''), isNot(contains('\n')));
      },
    );

    // Review follow-up (PR #49, finding F1): a plain-scalar block-style member
    // line containing `[` must not be mistaken for a flow-style list opener.
    // The edit must keep the list block-style and insert the member at the
    // list's own indentation instead of injecting the new member inside the
    // bracket text.
    test('column-one block list with a `[` member stays block-style', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: _\n'
            'workspace:\n'
            '- demo_app\n'
            '- packages/core[v2]\n',
          );

      process.updateRootPubspecSync(packageName: 'shared_ui');

      final after = fs.file('pubspec.yaml').readAsStringSync();
      expect(
        after,
        equals(
          'name: _\n'
          'workspace:\n'
          '- demo_app\n'
          '- packages/core[v2]\n'
          '- packages/shared_ui\n',
        ),
      );
      expect(after.split('packages/shared_ui').length - 1, equals(1));
      expect(
        parseWorkspaceManifest(after).members,
        equals(['demo_app', 'packages/core[v2]', 'packages/shared_ui']),
      );
    });

    test('an aliased workspace list leaves the anchor definition intact', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original =
          'name: _\n'
          'x-tool-members: &members [demo_app, packages/core]\n'
          'workspace: *members\n';
      final file = fs.file('pubspec.yaml')..writeAsStringSync(original);

      expect(
        () => process.updateRootPubspecSync(packageName: 'shared_ui'),
        throwsA(
          predicate(
            (error) => error.toString().contains('through a YAML alias'),
          ),
        ),
      );
      expect(file.readAsStringSync(), equals(original));
    });

    test('a workspace anchor used by a nested field stays intact', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original =
          'name: _\n'
          'workspace: &members\n'
          '- demo_app\n'
          '- packages/core\n'
          'x-tool:\n'
          '  packages: [*members]\n';
      final file = fs.file('pubspec.yaml')..writeAsStringSync(original);

      expect(
        () => process.updateRootPubspecSync(packageName: 'shared_ui'),
        throwsA(
          predicate(
            (error) => error.toString().contains('through a YAML alias'),
          ),
        ),
      );
      expect(file.readAsStringSync(), equals(original));
    });

    test('an aliased wildcard list that needs no edit stays intact', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      const original =
          'name: _\n'
          'x-tool-members: &members [demo_app, "packages/*"]\n'
          'workspace: *members\n';
      final file = fs.file('pubspec.yaml')..writeAsStringSync(original);

      process.updateRootPubspecSync(packageName: 'shared_ui');

      expect(file.readAsStringSync(), equals(original));
    });

    test('indented block list with a `[` member stays block-style', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      fs
          .file('pubspec.yaml')
          .writeAsStringSync(
            'name: _\n'
            'workspace:\n'
            '    - demo_app\n'
            '    - packages/core[v2]\n',
          );

      process.updateRootPubspecSync(packageName: 'shared_ui');

      final after = fs.file('pubspec.yaml').readAsStringSync();
      expect(
        after,
        equals(
          'name: _\n'
          'workspace:\n'
          '    - demo_app\n'
          '    - packages/core[v2]\n'
          '    - packages/shared_ui\n',
        ),
      );
      expect(
        parseWorkspaceManifest(after).members,
        equals(['demo_app', 'packages/core[v2]', 'packages/shared_ui']),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Issue #18: unified CLI argument validation, help, and exit codes.
  // ---------------------------------------------------------------------------
  group('CLI dispatch (Issue #18)', () {
    late List<String> errors;

    Cli buildCli() {
      errors = [];
      return Cli(
        fs: fs,
        runner: runner,
        log: logger,
        errorLog: (message) => errors.add(message),
      );
    }

    void stubHappySetup() {
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.12.0',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final executable = invocation.positionalArguments[0] as String;
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (executable == 'flutter' &&
            args.contains('create') &&
            args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });
    }

    void stubHappyAddPackage() {
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          'flutter',
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });
    }

    tearDown(() {
      errors = [];
    });

    test(
      'global help --help: exit 0, usage on stdout, no runner, no files',
      () {
        final initialDir = fs.directory('/test')..createSync();
        fs.currentDirectory = initialDir;

        final cli = buildCli();
        expect(cli.run(['--help']), 0);

        expect(logs, contains(contains('Usage:')));
        expect(logs, contains(contains('Global options:')));
        expect(errors, isEmpty);
        expect(fs.directory('/test/my_app_workspaces').existsSync(), isFalse);
        verifyNever(() => runner.runSync('flutter', any()));
        verifyNever(() => runner.runSync('dart', any()));
      },
    );

    test('global help -h: exit 0, usage on stdout, no runner, no files', () {
      final initialDir = fs.directory('/test')..createSync();
      fs.currentDirectory = initialDir;

      final cli = buildCli();
      expect(cli.run(['-h']), 0);

      expect(logs, contains(contains('Usage:')));
      expect(errors, isEmpty);
      expect(fs.directory('/test/my_app_workspaces').existsSync(), isFalse);
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(() => runner.runSync('dart', any()));
    });

    test(
      'global help bare help: exit 0, usage on stdout, no runner, no files',
      () {
        final initialDir = fs.directory('/test')..createSync();
        fs.currentDirectory = initialDir;

        final cli = buildCli();
        expect(cli.run(['help']), 0);

        expect(logs, contains(contains('Usage:')));
        expect(errors, isEmpty);
        expect(fs.directory('/test/my_app_workspaces').existsSync(), isFalse);
        verifyNever(() => runner.runSync('flutter', any()));
        verifyNever(() => runner.runSync('dart', any()));
      },
    );

    test(
      'global help help setup: exit 0, usage on stdout, no runner, no files',
      () {
        final initialDir = fs.directory('/test')..createSync();
        fs.currentDirectory = initialDir;

        final cli = buildCli();
        expect(cli.run(['help', 'setup']), 0);

        expect(logs, contains(contains('Usage:')));
        expect(errors, isEmpty);
        expect(fs.directory('/test/my_app_workspaces').existsSync(), isFalse);
        verifyNever(() => runner.runSync('flutter', any()));
        verifyNever(() => runner.runSync('dart', any()));
      },
    );

    test(
      'default setup alias setup --help: exit 0, usage on stdout, no runner',
      () {
        final initialDir = fs.directory('/test')..createSync();
        fs.currentDirectory = initialDir;

        final cli = buildCli();
        expect(cli.run(['setup', '--help']), 0);

        expect(logs, contains(contains('Usage:')));
        expect(logs, contains(contains('Global options:')));
        expect(errors, isEmpty);
        expect(fs.directory('/test/my_app_workspaces').existsSync(), isFalse);
        verifyNever(() => runner.runSync('flutter', any()));
        verifyNever(() => runner.runSync('dart', any()));
      },
    );

    test(
      'add-package help --help: exit 0, add-package usage, no runner, no files',
      () {
        final cli = buildCli();
        expect(cli.run(['add-package', '--help']), 0);

        expect(logs, contains(contains('add-package')));
        expect(
          logs,
          contains(
            contains('Usage: flutter_workspaces_cli add-package --name <name>'),
          ),
        );
        expect(errors, isEmpty);
        expect(fs.directory('packages').existsSync(), isFalse);
        verifyNever(() => runner.runSync('flutter', any()));
        verifyNever(() => runner.runSync('dart', any()));
      },
    );

    test('add-package help -h: exit 0, add-package usage', () {
      final cli = buildCli();
      expect(cli.run(['add-package', '-h']), 0);

      expect(
        logs,
        contains(
          contains('Usage: flutter_workspaces_cli add-package --name <name>'),
        ),
      );
      expect(errors, isEmpty);
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(() => runner.runSync('dart', any()));
    });

    test('add-package help help: exit 0, add-package usage', () {
      final cli = buildCli();
      expect(cli.run(['add-package', 'help']), 0);

      expect(
        logs,
        contains(
          contains('Usage: flutter_workspaces_cli add-package --name <name>'),
        ),
      );
      expect(errors, isEmpty);
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(() => runner.runSync('dart', any()));
    });

    test('help add-package: exit 0, add-package usage', () {
      final cli = buildCli();
      expect(cli.run(['help', 'add-package']), 0);

      expect(
        logs,
        contains(
          contains('Usage: flutter_workspaces_cli add-package --name <name>'),
        ),
      );
      expect(errors, isEmpty);
      verifyNever(() => runner.runSync('flutter', any()));
      verifyNever(() => runner.runSync('dart', any()));
    });

    test('missing name: [] exits 64 with setup usage on stderr only', () {
      final cli = buildCli();
      expect(cli.run([]), 64);

      expect(
        errors,
        contains(
          contains('Usage: flutter_workspaces_cli [setup] --name <name>'),
        ),
      );
      expect(logs, isNot(contains(contains('Usage:'))));
      expect(fs.directory('my_app_workspaces').existsSync(), isFalse);
    });

    test(
      'missing name: [add-package] exits 64 with add-package usage on stderr only',
      () {
        final cli = buildCli();
        expect(cli.run(['add-package']), 64);

        expect(
          errors,
          contains(
            contains('Usage: flutter_workspaces_cli add-package --name <name>'),
          ),
        );
        expect(logs, isNot(contains(contains('Usage:'))));
        expect(fs.directory('packages').existsSync(), isFalse);
      },
    );

    test('invalid name "Bad Name": exits 64 with usage on stderr', () {
      final cli = buildCli();
      expect(cli.run(['--name', 'Bad Name']), 64);

      expect(errors, contains(contains('must start with a lowercase letter')));
      expect(errors, contains(contains('Usage:')));
      expect(logs, isNot(contains(contains('Usage:'))));
    });

    test('invalid name "123bad": exits 64 with usage on stderr', () {
      final cli = buildCli();
      expect(cli.run(['--name', '123bad']), 64);

      expect(errors, contains(contains('must start with a lowercase letter')));
      expect(errors, contains(contains('Usage:')));
      expect(logs, isNot(contains(contains('Usage:'))));
    });

    // Issue #32: reserved Dart names are rejected before setup or add-package
    // starts — exit 64, an actionable error + the command's usage on stderr,
    // and no filesystem or subprocess effects.
    group('Reserved Dart names (Issue #32)', () {
      // Names rejected by Flutter's package-name validation
      // (`flutter create --template=package`): the `_keywords` set in the
      // Flutter tool's create_base.dart, the operative set for the `flutter`
      // invocations this CLI drives. Covers the issue's example (`class`) plus
      // a mix of standard keywords, contextual keywords Flutter rejects, and
      // contextual keywords pub allows but Flutter still rejects.
      const reservedNames = [
        'class',
        'static',
        'extension',
        'dynamic',
        'get',
        'function',
        'inout',
        'sync',
        'await',
        'yield',
      ];

      for (final name in reservedNames) {
        test(
          'setup: reserved name "$name" exits 64 with usage, no effects',
          () {
            final initialDir = fs.directory('/test_$name')..createSync();
            fs.currentDirectory = initialDir;
            final cli = buildCli();

            expect(cli.run(['--name', name]), 64);

            expect(
              errors,
              contains(contains('must not be a reserved Dart word')),
              reason: 'setup --name $name',
            );
            expect(
              errors,
              contains(
                contains('Usage: flutter_workspaces_cli [setup] --name <name>'),
              ),
              reason: 'setup --name $name',
            );
            expect(logs, isNot(contains(contains('Usage:'))));
            // No workspace folder, sentinel, or other file is created.
            expect(fs.directory('/test_$name').listSync(), isEmpty);
            verifyNever(() => runner.runSync(any(), any()));
          },
        );

        test(
          'add-package: reserved name "$name" exits 64 with usage, no effects',
          () {
            fs.directory('packages').createSync();
            fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
            final cli = buildCli();

            expect(cli.run(['add-package', '--name', name]), 64);

            expect(
              errors,
              contains(contains('must not be a reserved Dart word')),
              reason: 'add-package --name $name',
            );
            expect(
              errors,
              contains(
                contains(
                  'Usage: flutter_workspaces_cli add-package --name <name>',
                ),
              ),
              reason: 'add-package --name $name',
            );
            expect(logs, isNot(contains(contains('Usage:'))));
            // No package directory, no sentinel, manifests untouched.
            expect(fs.directory('packages').listSync(), isEmpty);
            expect(
              fs.file('pubspec.yaml').readAsStringSync(),
              equals('workspace:\n  - my_app'),
            );
            verifyNever(() => runner.runSync(any(), any()));
          },
        );
      }

      test('setup: reserved name "class" via -n exits 64 with usage', () {
        final initialDir = fs.directory('/test_class_short')..createSync();
        fs.currentDirectory = initialDir;
        final cli = buildCli();

        expect(cli.run(['-n', 'class']), 64);

        expect(errors, contains(contains('must not be a reserved Dart word')));
        expect(fs.directory('/test_class_short').listSync(), isEmpty);
        verifyNever(() => runner.runSync(any(), any()));
      });

      test('add-package: reserved name "class" via -n exits 64 with usage', () {
        fs.directory('packages').createSync();
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
        final cli = buildCli();

        expect(cli.run(['add-package', '-n', 'class']), 64);

        expect(errors, contains(contains('must not be a reserved Dart word')));
        expect(fs.directory('packages').listSync(), isEmpty);
        verifyNever(() => runner.runSync(any(), any()));
      });

      test(
        'setup: valid name "class_tools" via --name still reaches the runner',
        () {
          final initialDir = fs.directory('/test')..createSync();
          fs.currentDirectory = initialDir;
          stubHappySetup();

          final cli = buildCli();
          expect(cli.run(['--name', 'class_tools']), 0);

          expect(errors, isEmpty);
          expect(
            fs.directory('/test/class_tools_workspaces').existsSync(),
            isTrue,
          );
          expect(logs, contains(contains('completed successfully')));
        },
      );

      test(
        'setup: valid name "class_tools" via -n still reaches the runner',
        () {
          final initialDir = fs.directory('/test')..createSync();
          fs.currentDirectory = initialDir;
          stubHappySetup();

          final cli = buildCli();
          expect(cli.run(['-n', 'class_tools']), 0);

          expect(errors, isEmpty);
          expect(
            fs.directory('/test/class_tools_workspaces').existsSync(),
            isTrue,
          );
          expect(logs, contains(contains('completed successfully')));
        },
      );

      test(
        'add-package: valid name "class_tools" via --name still reaches the runner',
        () {
          fs.directory('packages').createSync();
          fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
          stubHappyAddPackage();

          final cli = buildCli();
          expect(cli.run(['add-package', '--name', 'class_tools']), 0);

          expect(errors, isEmpty);
          expect(
            logs,
            contains(contains('Package "class_tools" added successfully!')),
          );
          expect(
            fs.file('packages/class_tools/pubspec.yaml').existsSync(),
            isTrue,
          );
        },
      );

      test(
        'add-package: valid name "class_tools" via -n still reaches the runner',
        () {
          fs.directory('packages').createSync();
          fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
          stubHappyAddPackage();

          final cli = buildCli();
          expect(cli.run(['add-package', '-n', 'class_tools']), 0);

          expect(errors, isEmpty);
          expect(
            logs,
            contains(contains('Package "class_tools" added successfully!')),
          );
          expect(
            fs.file('packages/class_tools/pubspec.yaml').existsSync(),
            isTrue,
          );
        },
      );

      test(
        'setup: "int" (built-in type, not a reserved word) reaches the runner',
        () {
          final initialDir = fs.directory('/test')..createSync();
          fs.currentDirectory = initialDir;
          stubHappySetup();

          final cli = buildCli();
          expect(cli.run(['--name', 'int']), 0);

          expect(errors, isEmpty);
          expect(fs.directory('/test/int_workspaces').existsSync(), isTrue);
        },
      );

      test(
        'add-package: "int" (built-in type, not a reserved word) reaches the runner',
        () {
          fs.directory('packages').createSync();
          fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
          stubHappyAddPackage();

          final cli = buildCli();
          expect(cli.run(['add-package', '--name', 'int']), 0);

          expect(errors, isEmpty);
          expect(fs.file('packages/int/pubspec.yaml').existsSync(), isTrue);
        },
      );
    });

    group('Core name (Issue #39): reject the built-in core package name', () {
      // Setup always generates `packages/<kCorePackageName>`, so a workspace app
      // named the same collides with that member and Flutter refuses to resolve
      // the duplicate. The setup-specific check rejects it up front — before the
      // read-only availability guard, before any Flutter/Dart subprocess, and
      // before the reservation or any write — routing it to exit 64 with the
      // setup usage. `add-package` keeps its own behavior and is unaffected.

      test(
        'setup --name core exits 64 with the core-reserved message and usage, '
        'no effects (no flutter, no dir, no reservation, no manifest)',
        () {
          final initialDir = fs.directory('/test_core')..createSync();
          fs.currentDirectory = initialDir;
          final cli = buildCli();

          expect(cli.run(['--name', 'core']), 64);

          expect(errors, contains(contains('reserved for the shared package')));
          expect(errors, contains(contains('Choose a different app name')));
          expect(
            errors,
            contains(
              contains('Usage: flutter_workspaces_cli [setup] --name <name>'),
            ),
          );
          // Usage goes to stderr, not stdout.
          expect(logs, isNot(contains(contains('Usage:'))));
          // No workspace folder, reservation sentinel, or manifest is created.
          expect(fs.directory('/test_core').listSync(), isEmpty);
          // No Flutter/Dart subprocess was started for the rejected attempt.
          verifyNever(() => runner.runSync(any(), any()));
        },
      );

      test('explicit setup token + -n core also exits 64 with no effects', () {
        final initialDir = fs.directory('/test_core_short')..createSync();
        fs.currentDirectory = initialDir;
        final cli = buildCli();

        expect(cli.run(['setup', '-n', 'core']), 64);

        expect(errors, contains(contains('reserved for the shared package')));
        expect(
          errors,
          contains(
            contains('Usage: flutter_workspaces_cli [setup] --name <name>'),
          ),
        );
        expect(fs.directory('/test_core_short').listSync(), isEmpty);
        verifyNever(() => runner.runSync(any(), any()));
      });

      test(
        'setup --name core_tools still scaffolds (valid name, no regression)',
        () {
          final initialDir = fs.directory('/test')..createSync();
          fs.currentDirectory = initialDir;
          stubHappySetup();

          final cli = buildCli();
          expect(cli.run(['--name', 'core_tools']), 0);

          expect(errors, isEmpty);
          expect(
            fs.directory('/test/core_tools_workspaces').existsSync(),
            isTrue,
          );
          expect(logs, contains(contains('completed successfully')));
        },
      );

      test('add-package --name core is NOT rejected by the setup-only check '
          '(add-package keeps its own behavior)', () {
        fs.directory('packages').createSync();
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
        stubHappyAddPackage();

        final cli = buildCli();
        expect(cli.run(['add-package', '--name', 'core']), 0);

        expect(errors, isEmpty);
        expect(fs.file('packages/core/pubspec.yaml').existsSync(), isTrue);
      });
    });

    test('unknown flag --nope: exits 64 with usage on stderr', () {
      final cli = buildCli();
      expect(cli.run(['--nope', '--name', 'my_app']), 64);

      expect(errors, contains(contains('Usage:')));
      expect(logs, isNot(contains(contains('Usage:'))));
    });

    test('stray positional: [my_app] exits 64 with usage on stderr', () {
      final cli = buildCli();
      expect(cli.run(['my_app']), 64);

      expect(errors, contains(contains('Unexpected argument')));
      expect(errors, contains(contains('Usage:')));
      expect(logs, isNot(contains(contains('Usage:'))));
    });

    test('valid long form --name: full dispatch succeeds, no usage error', () {
      final initialDir = fs.directory('/test')..createSync();
      fs.currentDirectory = initialDir;
      stubHappySetup();

      final cli = buildCli();
      expect(cli.run(['--name', 'my_app']), 0);

      expect(errors, isEmpty);
      expect(fs.directory('/test/my_app_workspaces').existsSync(), isTrue);
      expect(logs, contains(contains('completed successfully')));
    });

    test('valid short form -n: full dispatch succeeds, no usage error', () {
      final initialDir = fs.directory('/test')..createSync();
      fs.currentDirectory = initialDir;
      stubHappySetup();

      final cli = buildCli();
      expect(cli.run(['-n', 'my_app']), 0);

      expect(errors, isEmpty);
      expect(fs.directory('/test/my_app_workspaces').existsSync(), isTrue);
      expect(logs, contains(contains('completed successfully')));
    });

    test(
      'valid long form add-package --name: dispatch succeeds, no usage error',
      () {
        fs.directory('packages').createSync();
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
        stubHappyAddPackage();

        final cli = buildCli();
        expect(cli.run(['add-package', '--name', 'my_feature']), 0);

        expect(errors, isEmpty);
        expect(
          logs,
          contains(contains('Package "my_feature" added successfully!')),
        );
        expect(
          fs.file('packages/my_feature/pubspec.yaml').existsSync(),
          isTrue,
        );
      },
    );

    test(
      'valid short form add-package -n: dispatch succeeds, no usage error',
      () {
        fs.directory('packages').createSync();
        fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - my_app');
        stubHappyAddPackage();

        final cli = buildCli();
        expect(cli.run(['add-package', '-n', 'my_feature']), 0);

        expect(errors, isEmpty);
        expect(
          logs,
          contains(contains('Package "my_feature" added successfully!')),
        );
        expect(
          fs.file('packages/my_feature/pubspec.yaml').existsSync(),
          isTrue,
        );
      },
    );

    test(
      'valid name "help" (long form): --name help reaches the runner, not help',
      () {
        final initialDir = fs.directory('/test')..createSync();
        fs.currentDirectory = initialDir;
        stubHappySetup();

        final cli = buildCli();
        expect(cli.run(['--name', 'help']), 0);

        // A valid name must reach the runner, so no help text on stdout.
        expect(logs, isNot(contains(contains('Usage:'))));
        expect(fs.directory('/test/help_workspaces').existsSync(), isTrue);
      },
    );

    test(
      'valid name "help" (short form): -n help reaches the runner, not help',
      () {
        final initialDir = fs.directory('/test')..createSync();
        fs.currentDirectory = initialDir;
        stubHappySetup();

        final cli = buildCli();
        expect(cli.run(['-n', 'help']), 0);

        expect(logs, isNot(contains(contains('Usage:'))));
        expect(fs.directory('/test/help_workspaces').existsSync(), isTrue);
      },
    );

    test('valid name "help" with add-package: reaches the runner, not help', () {
      fs.directory('packages').createSync();
      fs.file('pubspec.yaml').writeAsStringSync('workspace:\n  - help');
      stubHappyAddPackage();

      final cli = buildCli();
      expect(cli.run(['add-package', '--name', 'help']), 0);

      // The add-package usage must NOT be printed; the run reaches the runner.
      expect(logs, isNot(contains(contains('Usage:'))));
      expect(logs, contains(contains('Package "help" added successfully!')));
      expect(fs.file('packages/help/pubspec.yaml').existsSync(), isTrue);
    });

    test(
      'execution error: valid setup run with failing Flutter exits 1 with the error on stderr',
      () {
        final initialDir = fs.directory('/work')..createSync();
        fs.currentDirectory = initialDir;

        when(
          () => runner.runSync('flutter', ['--version'], runInShell: true),
        ).thenReturn(
          ProcessRunnerResult(
            exitCode: 1,
            stdout: 'flutter failed to start',
            stderr: 'panic: no flutter',
          ),
        );

        final cli = buildCli();
        expect(cli.run(['--name', 'my_app']), 1);

        expect(errors, contains(contains('flutter --version')));
        expect(errors, contains(contains('exit code 1')));
        // No workspace folder is created for the failed run.
        expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
        expect(logs, isNot(contains(contains('Usage:'))));
      },
    );
  });

  group('README consistency with generated manifests (#30)', () {
    test(
      'README documents the floor, the glob layout, and the rejection behavior',
      () {
        // Resolve the README relative to this test file's own location, not
        // the process working directory (the real-filesystem test group
        // mutates the cwd). `Platform.script` points at the compiled kernel
        // dump under `dart test`, so the source URI comes from the JIT stack
        // trace's first frame — that frame is this file.
        final frameMatch = RegExp(
          r'\(file://([^)]+)\)',
        ).firstMatch(StackTrace.current.toString());
        if (frameMatch == null) {
          throw StateError(
            'could not resolve the package root from the stack trace',
          );
        }
        final uriPath = frameMatch
            .group(1)!
            .replaceFirst(RegExp(r':(\d+):(\d+)$'), '');
        final packageRoot = io.File(
          Uri.parse('file://$uriPath').toFilePath(),
        ).parent.parent.absolute.path;
        final readme = io.File('$packageRoot/README.md').readAsStringSync();

        // The supported toolchain floor stated in the README matches the
        // constants the CLI enforces and serializes.
        expect(readme, contains(DartProcess.supportedMinimumVersion));
        expect(readme, contains(DartProcess.supportedMinimumFlutterVersion));

        // The glob workspace layout is documented as always emitted.
        expect(readme, contains('packages/*'));

        // The rejection behavior (detected vs required, before any writes) is documented.
        expect(readme, contains('before any filesystem writes'));
        expect(readme, contains('3.12.0'));
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Issue #31: atomic reservation and run isolation.
  //
  // The synchronized overlaps drive the race through the one hook point the
  // memory backend exposes for this: the `opHandle` parameter of
  // MemoryFileSystem, which fires synchronously inside the sentinel claim —
  // i.e. inside the loser's atomic acquire. The hook runs the competing
  // invocation in place of the loser's suspended claim, then restores the
  // occupied sentinel exactly as an interrupted winner would leave behind.
  // That is the legitimate way to make the race deterministic: the race
  // between the existing-path guard/check and the atomic claim can only be
  // interleaved inside the claim itself.
  // ─────────────────────────────────────────────────────────────────────────
  group('Issue #31: atomic reservation and run isolation', () {
    /// Happy-path stub for the flutter subprocess and dart.getDartVersionSync.
    void stubHappyPathRunner(ProcessRunner runner, FileSystem fs) {
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.12.0',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create') && !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (args.contains('create') && args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });
    }

    test('RunReservation: a claimed sentinel is deleted on release '
        '(success path)', () {
      final mockFs = MockFileSystem();
      final sentinel = MockLink();
      var sentinelCreated = false;
      when(() => mockFs.link(any())).thenReturn(sentinel);
      when(() => sentinel.createSync(any())).thenAnswer((_) {
        sentinelCreated = true;
      });
      // existsSync is stateful: false before the claim, true once the
      // sentinel exists — exactly the lifecycle the real link presents.
      when(() => sentinel.existsSync()).thenAnswer((_) => sentinelCreated);

      final reservation = RunReservation.acquire(
        fs: mockFs,
        sentinelPath: '/work/.my_app_workspaces.reserved',
        contextLabel: 'the workspace directory "my_app_workspaces"',
      );
      expect(sentinelCreated, isTrue);

      // The release actually deletes the sentinel, not a silent no-op.
      expect(reservation.release(), isNull);
      verify(() => sentinel.deleteSync()).called(1);
    });

    // ---- synchronized overlaps: same name ----

    test(
      'setup: two invocations for the same name — only one claims the target '
      'and the loser leaves the winner\'s files intact',
      () {
        final logs = <String>[];
        final winnerLogs = <String>[];
        var hookFired = false;
        const sentinelPath = '/work/.my_app_workspaces.reserved';

        late MemoryFileSystem sharedFs;
        void interleave(String context, FileSystemOp operation) {
          if (hookFired) return;
          if (operation != FileSystemOp.create) return;
          if (context != sentinelPath) return;
          hookFired = true;

          // The competing invocation (the winner). It passes the same two
          // guards (nothing exists yet), claims the same sentinel, scaffolds,
          // and completes normally.
          final winnerRunner = MockProcessRunner();
          stubHappyPathRunner(winnerRunner, sharedFs);
          final winner = SetupRunner(
            fs: sharedFs,
            runner: winnerRunner,
            log: (m) => winnerLogs.add(m),
            errorLog: (m) => winnerLogs.add(m),
          );
          winner.run(['--name', 'my_app']);

          // The winner released its sentinel on the success path. Re-create
          // the stale sentinel exactly as an interrupted winner would leave
          // behind, so the loser's resumed atomic claim sees the reservation
          // as held.
          sharedFs.link(sentinelPath).createSync('reserved');
        }

        sharedFs = MemoryFileSystem(opHandle: interleave);
        sharedFs.directory('/work').createSync();
        sharedFs.currentDirectory = sharedFs.directory('/work');

        final loserRunner = MockProcessRunner();
        stubHappyPathRunner(loserRunner, sharedFs);
        final loser = SetupRunner(
          fs: sharedFs,
          runner: loserRunner,
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        );

        expect(
          () => loser.run(['--name', 'my_app']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // The loser failed at the atomic claim, before creating anything.
        expect(logs, contains(contains('already reserved or occupied')));
        expect(
          logs,
          isNot(contains('Flutter workspace setup completed successfully')),
        );

        // The winner's workspace was fully created and its success was logged.
        expect(
          winnerLogs,
          contains(contains('Flutter workspace setup completed successfully')),
        );
        expect(
          sharedFs.directory('/work/my_app_workspaces').existsSync(),
          isTrue,
        );
        expect(
          sharedFs.file('/work/my_app_workspaces/pubspec.yaml').existsSync(),
          isTrue,
        );
        expect(
          sharedFs.directory('/work/my_app_workspaces/my_app').existsSync(),
          isTrue,
        );

        // The loser did not delete the winner's files or the stale sentinel.
        expect(sharedFs.link(sentinelPath).existsSync(), isTrue);
        expect(sharedFs.currentDirectory.path, equals('/work'));
      },
    );

    test(
      'add-package: two invocations for the same name — only one claims the '
      'destination and the winner\'s files and manifest update stay intact',
      () {
        final logs = <String>[];
        final winnerLogs = <String>[];
        var hookFired = false;
        const lockPath = '/work/.flutter_workspaces_cli.lock';

        late MemoryFileSystem sharedFs;
        void interleave(String context, FileSystemOp operation) {
          if (hookFired) return;
          if (operation != FileSystemOp.create) return;
          if (context != lockPath) return;
          hookFired = true;

          final winnerRunner = MockProcessRunner();
          stubHappyPathRunner(winnerRunner, sharedFs);
          final winner = AddPackageRunner(
            fs: sharedFs,
            runner: winnerRunner,
            log: (m) => winnerLogs.add(m),
            errorLog: (m) => winnerLogs.add(m),
          );
          winner.run(['--name', 'new_pkg']);

          // The winner released its lock and destination sentinel on the
          // success path. Re-create the stale lock as an interrupted winner
          // would leave it, so the loser's resumed atomic claim sees the
          // workspace as held.
          sharedFs.link(lockPath).createSync('reserved');
        }

        sharedFs = MemoryFileSystem(opHandle: interleave);
        sharedFs.directory('/work').createSync();
        sharedFs
            .file('/work/pubspec.yaml')
            .writeAsStringSync('workspace:\n  - app\n');
        sharedFs.directory('/work/packages').createSync();
        sharedFs.currentDirectory = sharedFs.directory('/work');

        final loserRunner = MockProcessRunner();
        stubHappyPathRunner(loserRunner, sharedFs);
        final loser = AddPackageRunner(
          fs: sharedFs,
          runner: loserRunner,
          log: (m) => logs.add(m),
          errorLog: (m) => logs.add(m),
        );

        expect(
          () => loser.run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        // The loser exited at the workspace lock, before reading or writing
        // anything.
        expect(logs, contains(contains('workspace lock')));

        // The winner fully completed: its package exists, its pubspec is
        // written, and the manifest contains its member.
        expect(
          winnerLogs,
          contains(contains('Package "new_pkg" added successfully!')),
        );
        expect(
          sharedFs
              .file('/work/packages/new_pkg/pubspec.yaml')
              .readAsStringSync(),
          contains('name: new_pkg'),
        );
        expect(
          sharedFs.file('/work/pubspec.yaml').readAsStringSync(),
          contains('packages/new_pkg'),
        );

        // The loser left the winner's package directory intact.
        expect(
          sharedFs.directory('/work/packages/new_pkg').existsSync(),
          isTrue,
        );
        // The loser released nothing and left the stale lock behind.
        expect(sharedFs.link(lockPath).existsSync(), isTrue);
      },
    );

    // ---- synchronized overlaps: different names ----

    test('add-package: two invocations with different names — neither loses the '
        'other\'s manifest update', () {
      final logs = <String>[];
      final winnerLogs = <String>[];
      var hookFired = false;
      const lockPath = '/work/.flutter_workspaces_cli.lock';

      late MemoryFileSystem sharedFs;
      void interleave(String context, FileSystemOp operation) {
        if (hookFired) return;
        if (operation != FileSystemOp.create) return;
        if (context != lockPath) return;
        hookFired = true;

        final winnerRunner = MockProcessRunner();
        stubHappyPathRunner(winnerRunner, sharedFs);
        final winner = AddPackageRunner(
          fs: sharedFs,
          runner: winnerRunner,
          log: (m) => winnerLogs.add(m),
          errorLog: (m) => winnerLogs.add(m),
        );
        winner.run(['--name', 'feature_b']);

        // Re-create the stale lock exactly as an interrupted winner would.
        sharedFs.link(lockPath).createSync('reserved');
      }

      sharedFs = MemoryFileSystem(opHandle: interleave);
      sharedFs.directory('/work').createSync();
      sharedFs
          .file('/work/pubspec.yaml')
          .writeAsStringSync('workspace:\n  - app\n');
      sharedFs.directory('/work/packages').createSync();
      sharedFs.currentDirectory = sharedFs.directory('/work');

      final loserRunner = MockProcessRunner();
      stubHappyPathRunner(loserRunner, sharedFs);
      final loser = AddPackageRunner(
        fs: sharedFs,
        runner: loserRunner,
        log: (m) => logs.add(m),
        errorLog: (m) => logs.add(m),
      );

      expect(
        () => loser.run(['--name', 'feature_a']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The loser exited at the workspace lock — before touching anything.
      expect(logs, contains(contains('workspace lock')));
      expect(
        sharedFs.directory('/work/packages/feature_a').existsSync(),
        isFalse,
      );

      // The winner's manifest update stands: feature_b is present.
      expect(
        sharedFs.file('/work/pubspec.yaml').readAsStringSync(),
        contains('packages/feature_b'),
      );

      // Recover the documented way: remove the stale lock (a manual recovery),
      // then retry the loser — both membership updates are kept.
      sharedFs.link(lockPath).deleteSync();
      loser.run(['--name', 'feature_a']);

      expect(
        logs,
        contains(contains('Package "feature_a" added successfully!')),
      );
      final manifest = sharedFs.file('/work/pubspec.yaml').readAsStringSync();
      expect(manifest, contains('packages/feature_b'));
      expect(manifest, contains('packages/feature_a'));
    });

    // ---- reservation/lock release on every exit path ----

    test('setup: reservation is released on success', () {
      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;
      stubHappyPathRunner(runner, fs);

      SetupRunner(
        fs: fs,
        runner: runner,
        log: logger,
      ).run(['--name', 'my_app']);

      expect(
        fs.link('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );
      expect(
        logs,
        contains(contains('Flutter workspace setup completed successfully')),
      );
    });

    test('setup: reservation is released on failure — retried run completes', () {
      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      // Flutter fails at the scaffold step (create exits with code 2).
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.12.0',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          return ProcessRunnerResult(
            exitCode: 2,
            stdout: 'create failed',
            stderr: '',
          );
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      expect(
        () => SetupRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The rollback removed the reserved dir and the sentinel is released.
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isFalse);
      expect(
        fs.link('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );

      // Heal the scaffold (retry with a working create) and retry.
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create') && !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
          fs.directory('$appName/test').createSync(recursive: true);
        }
        if (args.contains('create') && args.contains('--template=package')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      expect(
        () => SetupRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'my_app']),
        returnsNormally,
      );
      expect(fs.directory('/work/my_app_workspaces').existsSync(), isTrue);
      expect(
        fs.link('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );
    });

    test('setup: reservation is released even when the cleanup also fails', () {
      // Engineer a cleanup failure through the memory-fs hook: the rollback
      // deleteSync of the reserved directory throws.
      var engineerDelete = true;
      void hook(String context, FileSystemOp operation) {
        if (engineerDelete &&
            operation == FileSystemOp.delete &&
            context == '/work/my_app_workspaces') {
          throw Exception('engineered cleanup failure');
        }
      }

      final failingFs = MemoryFileSystem(opHandle: hook);
      failingFs.directory('/work').createSync();
      failingFs.currentDirectory = failingFs.directory('/work');

      final runner2 = MockProcessRunner();
      stubHappyPathRunner(runner2, failingFs);
      // Make the scaffold step fail.
      when(
        () => runner2.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          return ProcessRunnerResult(
            exitCode: 2,
            stdout: 'create failed',
            stderr: '',
          );
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      final logsList = <String>[];
      expect(
        () => SetupRunner(
          fs: failingFs,
          runner: runner2,
          log: (m) => logsList.add(m),
          errorLog: (m) => logsList.add(m),
        ).run(['--name', 'my_app']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // The rollback failed and was surfaced, alongside the original failure.
      expect(logsList, contains(contains('Cleanup also failed')));

      // The sentinel was still released (best-effort) despite the cleanup failure.
      expect(
        failingFs.link('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );

      // The reserved directory is NOT removed (engineered failure).
      expect(
        failingFs.directory('/work/my_app_workspaces').existsSync(),
        isTrue,
      );
    });

    test('setup: reservation is never created on a usage error', () {
      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      expect(
        () => SetupRunner(fs: fs, runner: runner, log: logger).run(['--name']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 64)),
      );
      expect(logs, contains(contains('Usage')));
      expect(
        fs.link('/work/.my_app_workspaces.reserved').existsSync(),
        isFalse,
      );
    });

    test(
      'add-package: lock and destination sentinel are released on success',
      () {
        final initialDir = fs.directory('/work')..createSync();
        fs.currentDirectory = initialDir;
        fs
            .file('/work/pubspec.yaml')
            .writeAsStringSync('workspace:\n  - app\n');
        fs.directory('/work/packages').createSync();
        stubHappyPathRunner(runner, fs);

        AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']);

        expect(
          fs.file('/work/pubspec.yaml').readAsStringSync(),
          contains('packages/new_pkg'),
        );
        expect(fs.directory('/work/packages/new_pkg').existsSync(), isTrue);
        expect(
          fs.link('/work/.flutter_workspaces_cli.lock').existsSync(),
          isFalse,
        );
        expect(
          fs.link('/work/packages/.new_pkg.reserved').existsSync(),
          isFalse,
        );
      },
    );

    test('add-package: lock and sentinel are released on failure — retried run '
        'completes', () {
      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;
      fs.file('/work/pubspec.yaml').writeAsStringSync('workspace:\n  - app\n');
      fs.file('/work/pubspec.lock').writeAsStringSync('ORIGINAL-LOCK\n');
      fs.directory('/work/packages').createSync();

      // Flutter create fails — the rollback must restore the manifest and
      // lockfile, and the sentinel/lock must be released.
      when(
        () => runner.runSync('flutter', [
          '--version',
          '--machine',
        ], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync('flutter', ['--version'], runInShell: true),
      ).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.12.0',
          stderr: '',
        ),
      );
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          return ProcessRunnerResult(
            exitCode: 2,
            stdout: 'create failed',
            stderr: '',
          );
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
      );

      // Manifest and lockfile restored; the reserved directory removed; the
      // lock and destination sentinel both released.
      expect(
        fs.file('/work/pubspec.yaml').readAsStringSync(),
        equals('workspace:\n  - app\n'),
      );
      expect(
        fs.file('/work/pubspec.lock').readAsStringSync(),
        equals('ORIGINAL-LOCK\n'),
      );
      expect(fs.directory('/work/packages/new_pkg').existsSync(), isFalse);
      expect(
        fs.link('/work/.flutter_workspaces_cli.lock').existsSync(),
        isFalse,
      );
      expect(fs.link('/work/packages/.new_pkg.reserved').existsSync(), isFalse);

      // Clean retry succeeds.
      when(
        () => runner.runSync(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
          runInShell: any(named: 'runInShell'),
        ),
      ).thenAnswer((invocation) {
        final args = invocation.positionalArguments[1] as List<String>;
        if (args.join(' ') == '--version --machine') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout:
                '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
            stderr: '',
          );
        }
        if (args.join(' ') == '--version') {
          return ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.12.0',
            stderr: '',
          );
        }
        if (args.contains('create')) {
          final packageName = args.last;
          final workingDir =
              invocation.namedArguments[#workingDirectory] as String?;
          final path = workingDir != null
              ? '$workingDir/$packageName'
              : packageName;
          fs.directory(path).createSync(recursive: true);
        }
        return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
      });

      expect(
        () => AddPackageRunner(
          fs: fs,
          runner: runner,
          log: logger,
        ).run(['--name', 'new_pkg']),
        returnsNormally,
      );
      expect(fs.directory('/work/packages/new_pkg').existsSync(), isTrue);
      expect(
        fs.link('/work/.flutter_workspaces_cli.lock').existsSync(),
        isFalse,
      );
    });

    test(
      'add-package: lock and sentinel are released even when the cleanup also fails',
      () {
        // Engineer a rollback delete failure through the memory-fs hook.
        // Note: the rollback deletes the *relative* target path ("packages/new_pkg")
        // as passed to fs.directory(), so the hook matches that context.
        var engineerDelete = true;
        void hook(String context, FileSystemOp operation) {
          if (engineerDelete &&
              operation == FileSystemOp.delete &&
              context == 'packages/new_pkg') {
            throw Exception('engineered cleanup failure');
          }
        }

        final failingFs = MemoryFileSystem(opHandle: hook);
        failingFs.directory('/work').createSync();
        failingFs
            .file('/work/pubspec.yaml')
            .writeAsStringSync('workspace:\n  - app\n');
        failingFs
            .file('/work/pubspec.lock')
            .writeAsStringSync('ORIGINAL-LOCK\n');
        failingFs.directory('/work/packages').createSync();
        failingFs.currentDirectory = failingFs.directory('/work');

        final runner2 = MockProcessRunner();
        stubHappyPathRunner(runner2, failingFs);
        when(
          () => runner2.runSync(
            any(),
            any(),
            workingDirectory: any(named: 'workingDirectory'),
            runInShell: any(named: 'runInShell'),
          ),
        ).thenAnswer((invocation) {
          final args = invocation.positionalArguments[1] as List<String>;
          if (args.join(' ') == '--version --machine') {
            return ProcessRunnerResult(
              exitCode: 0,
              stdout:
                  '{"frameworkVersion": "3.27.0", "flutterRoot": "/opt/flutter", "channel": "stable", "dartSdkVersion": "3.12.0"}',
              stderr: '',
            );
          }
          if (args.join(' ') == '--version') {
            return ProcessRunnerResult(
              exitCode: 0,
              stdout: 'Dart SDK version: 3.12.0',
              stderr: '',
            );
          }
          if (args.contains('create')) {
            // Mirror flutter create's partial scaffold: the package directory is
            // created, then the create fails — so the rollback has something to
            // clean up and the engineered delete failure fires.
            final packageName = args.last;
            final workingDir =
                invocation.namedArguments[#workingDirectory] as String?;
            final path = workingDir != null
                ? '$workingDir/$packageName'
                : packageName;
            failingFs.directory(path).createSync(recursive: true);
            return ProcessRunnerResult(
              exitCode: 2,
              stdout: 'create failed',
              stderr: '',
            );
          }
          return ProcessRunnerResult(exitCode: 0, stdout: '', stderr: '');
        });

        final logsList = <String>[];
        expect(
          () => AddPackageRunner(
            fs: failingFs,
            runner: runner2,
            log: (m) => logsList.add(m),
            errorLog: (m) => logsList.add(m),
          ).run(['--name', 'new_pkg']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 1)),
        );

        expect(logsList, contains(contains('Cleanup also failed')));
        // The manifest and lockfile were restored...
        expect(
          failingFs.file('/work/pubspec.yaml').readAsStringSync(),
          equals('workspace:\n  - app\n'),
        );
        expect(
          failingFs.file('/work/pubspec.lock').readAsStringSync(),
          equals('ORIGINAL-LOCK\n'),
        );
        // ...the package directory was NOT removed (engineered failure)...
        expect(
          failingFs.directory('/work/packages/new_pkg').existsSync(),
          isTrue,
        );
        // ...but the lock and destination sentinel were still released.
        expect(
          failingFs.link('/work/.flutter_workspaces_cli.lock').existsSync(),
          isFalse,
        );
        expect(
          failingFs.link('/work/packages/.new_pkg.reserved').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'add-package: lock and sentinel are never created on a usage error',
      () {
        final initialDir = fs.directory('/work')..createSync();
        fs.currentDirectory = initialDir;

        expect(
          () => AddPackageRunner(
            fs: fs,
            runner: runner,
            log: logger,
          ).run(['--name']),
          throwsA(isA<ExitException>().having((e) => e.code, 'code', 64)),
        );
        expect(logs, contains(contains('Usage')));
        expect(
          fs.link('/work/.flutter_workspaces_cli.lock').existsSync(),
          isFalse,
        );
        expect(
          fs.link('/work/packages/.new_pkg.reserved').existsSync(),
          isFalse,
        );
      },
    );
  });
}
