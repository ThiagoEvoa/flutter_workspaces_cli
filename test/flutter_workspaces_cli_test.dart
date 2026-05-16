import 'package:file/memory.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockProcessRunner extends Mock implements ProcessRunner {}

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
}
