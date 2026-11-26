import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';
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
  });

  group('DartProcess', () {
    test('getDartVersionSync returns a version string on success', () {
      final process = DartProcess(runner: runner, log: logger);
      when(() => runner.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0 (stable)',
          stderr: '',
        ),
      );

      final version = process.getDartVersionSync();
      expect(version, equals('3.6.0'));
    });

    test('getDartVersionSync returns fallback on failure', () {
      final process = DartProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('dart', ['--version']),
      ).thenReturn(ProcessRunnerResult(exitCode: 1, stdout: '', stderr: ''));

      final version = process.getDartVersionSync();
      expect(version, equals('^3.6.0'));
    });
  });

  group('FlutterProcess', () {
    test('isFlutterInstalledSync does not throw when Flutter is available', () {
      final process = FlutterProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', ['--version']),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));

      expect(() => process.isFlutterInstalledSync(), returnsNormally);
    });

    test('isFlutterInstalledSync throws when Flutter is not available', () {
      final process = FlutterProcess(runner: runner, log: logger);
      when(
        () => runner.runSync('flutter', ['--version']),
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
      process.createRootPubspecSync(dartVersion: '3.10.8', projectName: 'app');
      final file = fs.file('pubspec.yaml');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('name: _'));
    });

    test('createRootPubspecSync uses packages/* for Dart 3.11+', () {
      final process = WorkspaceProcess(fs: fs, runner: runner, log: logger);
      process.createRootPubspecSync(dartVersion: '3.11.0', projectName: 'app');
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

      process.updatePubspecSync(packageName: 'my_pkg', dartVersion: '3.6.0');

      final file = fs.file('packages/my_pkg/pubspec.yaml');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('name: my_pkg'));
      expect(content, contains('resolution: workspace'));
      expect(content, contains('sdk: ^3.6.0'));
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

      when(() => runner.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0',
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

      expect(
        () => addPackageRunner.run(['--name', 'new_pkg']),
        throwsA(isA<ExitException>()),
      );
      expect(logs, contains(contains('Directory "packages" not found')));
    });
  });

  group('SetupRunner', () {
    test('run successfully completes simple workflow', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      // Setup initial directory
      final initialDir = fs.directory('/test')..createSync();
      fs.currentDirectory = initialDir;

      // Mock dart version
      when(() => runner.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0',
          stderr: '',
        ),
      );

      // Mock flutter version check
      when(
        () => runner.runSync('flutter', ['--version']),
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
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
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
      verifyNever(() => runner.runSync('dart', any()));
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
        () => runner.runSync('flutter', ['--version']),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(() => runner.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0',
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
        () => runner2.runSync('flutter', ['--version']),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(() => runner2.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0',
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
    });

    test('(d) two attempts for the same name: exactly one succeeds, the '
        'other is rejected', () {
      // Attempt 1 succeeds and populates the workspace.
      final runner1 = MockProcessRunner();
      final logs1 = <String>[];

      when(
        () => runner1.runSync('flutter', ['--version']),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(() => runner1.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0',
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
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
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
      verifyNever(() => runner2.runSync('dart', any()));
    });

    test('(e) a successful setup restores the working directory to the '
        'invocation directory (success path)', () {
      final setupRunner = SetupRunner(fs: fs, runner: runner, log: logger);

      final initialDir = fs.directory('/work')..createSync();
      fs.currentDirectory = initialDir;

      when(
        () => runner.runSync('flutter', ['--version']),
      ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
      when(() => runner.runSync('dart', ['--version'])).thenReturn(
        ProcessRunnerResult(
          exitCode: 0,
          stdout: 'Dart SDK version: 3.6.0',
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
        if (executable == 'flutter' &&
            args.contains('create') &&
            !args.contains('--template=package')) {
          final appName = args.last;
          fs.directory('$appName/lib').createSync(recursive: true);
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
      verifyNever(() => runner.runSync('dart', any()));
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
      verifyNever(() => runner.runSync('dart', any()));
      expect(logs, contains(contains('already exists')));
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

        when(() => runner.runSync('flutter', ['--version'])).thenReturn(
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
        verifyNever(() => runner.runSync('dart', any()));
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
          () => runner.runSync('flutter', ['--version']),
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
          () => runner.runSync('flutter', ['--version']),
        ).thenReturn(ProcessRunnerResult(exitCode: 0, stdout: '', stderr: ''));
        when(() => runner.runSync('dart', ['--version'])).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.6.0',
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
            'custom_lint',
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
          expect(
            e.toString(),
            contains('flutter pub add --dev flutter_lints custom_lint'),
          );
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

        when(() => runner.runSync('dart', ['--version'])).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.6.0',
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

        when(() => runner.runSync('dart', ['--version'])).thenReturn(
          ProcessRunnerResult(
            exitCode: 0,
            stdout: 'Dart SDK version: 3.6.0',
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
  });
}
