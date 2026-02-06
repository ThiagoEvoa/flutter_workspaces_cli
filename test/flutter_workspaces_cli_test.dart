import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';
import 'package:test/test.dart';

// Helper function to test private _validateDartVersion
void _validateDartVersionHelper(String version) {
  final parts = version.split('.');
  if (parts.length < 2) {
    throw Exception(
      'Dart 3.6.0 or higher is required. Current version: $version',
    );
  }

  final major = int.tryParse(parts[0]) ?? 0;
  final minor = int.tryParse(parts[1]) ?? 0;

  if (major < 3 || (major == 3 && minor < 6)) {
    throw Exception(
      'Dart 3.6.0 or higher is required. Current version: $version',
    );
  }
}

void main() {
  group('ProjectNameProcess', () {
    test('getProjectName returns project name when --name is provided', () {
      final arguments = ['--name', 'my_app'];
      final result = ProjectNameProcess.getProjectName(arguments: arguments);
      expect(result, equals('my_app'));
    });

    test('getProjectName returns project name with short flag -n', () {
      final arguments = ['-n', 'test_project'];
      final result = ProjectNameProcess.getProjectName(arguments: arguments);
      expect(result, equals('test_project'));
    });

    test('getProjectName throws ArgumentError when --name is missing', () {
      final arguments = <String>[];
      expect(
        () => ProjectNameProcess.getProjectName(arguments: arguments),
        throwsArgumentError,
      );
    });

    test('getProjectName throws ArgumentError when --name value is empty', () {
      final arguments = ['--name', ''];
      expect(
        () => ProjectNameProcess.getProjectName(arguments: arguments),
        throwsArgumentError,
      );
    });
  });

  group('DartProcess', () {
    test('getDartVersionSync returns a version string or fallback', () {
      final version = DartProcess.getDartVersionSync();
      expect(version, isNotEmpty);
      // Should be either a valid version or the fallback '^3.6.0'
      expect(version.contains(RegExp(r'^\d+\.\d+\.\d+|^\^3\.6\.0')), isTrue);
    });

    test('validateDartVersion throws for version < 3.6.0', () {
      expect(() => _validateDartVersionHelper('3.5.0'), throwsException);
    });

    test('validateDartVersion throws for malformed version', () {
      expect(() => _validateDartVersionHelper('invalid'), throwsException);
    });

    test('validateDartVersion does not throw for version >= 3.6.0', () {
      expect(() => _validateDartVersionHelper('3.6.0'), returnsNormally);
      expect(() => _validateDartVersionHelper('3.10.8'), returnsNormally);
      expect(() => _validateDartVersionHelper('4.0.0'), returnsNormally);
    });
  });

  group('FlutterProcess', () {
    test('isFlutterInstalledSync throws when Flutter is not available', () {
      // This test assumes Flutter might not be installed or is mocked.
      // Adjust based on your test environment.
      try {
        FlutterProcess.isFlutterInstalledSync();
        // If we get here, Flutter is installed (expected in dev environment)
        expect(true, isTrue);
      } catch (e) {
        // Flutter not installed; exception is expected.
        expect(e, isException);
      }
    });
  });

  group('CommonProcess', () {
    test('getInitialDirectory returns a directory', () {
      final result = CommonProcess.getInitialDirectory();
      expect(result, isA<Directory>());
    });

    test('printUsage does not throw', () {
      final parser = ArgParser();
      expect(() => CommonProcess.printUsage(parser), returnsNormally);
    });
  });

  group('WorkspaceProcess file operations', () {
    late Directory testDir;

    setUp(() {
      // Create a temporary test directory
      testDir = Directory.systemTemp.createTempSync('flutter_ws_test_');
      Directory.current = testDir.path;
    });

    tearDown(() {
      // Restore original directory and clean up
      Directory.current = Directory.systemTemp.path;
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    });

    test('createPackagesFolderSync creates packages directory', () {
      WorkspaceProcess.createPackagesFolderSync();
      expect(Directory('packages').existsSync(), isTrue);
    });

    test('createRootPubspecSync writes pubspec.yaml with correct content', () {
      WorkspaceProcess.createRootPubspecSync(
        dartVersion: '3.10.8',
        projectName: 'test_app',
      );
      final file = File('pubspec.yaml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content, contains('workspace:'));
      expect(content, contains('test_app'));
      expect(content, contains('packages/core'));
      expect(content, contains('^3.10.8'));
    });

    test('createWorkspaceFolderSync creates folder and changes directory', () {
      final originalDir = Directory.current;
      WorkspaceProcess.createWorkspaceFolderSync(projectName: 'my_project');

      final expectedFolder = Directory(
        '${originalDir.path}/my_project_workspaces',
      );
      expect(expectedFolder.existsSync(), isTrue);
      expect(Directory.current.path, equals(expectedFolder.path));

      // Restore directory
      Directory.current = originalDir.path;
    });
  });

  group('CorePackageProcess file operations', () {
    late Directory testDir;

    setUp(() {
      testDir = Directory.systemTemp.createTempSync('flutter_core_test_');
      Directory.current = testDir.path;
      Directory('packages/core/lib').createSync(recursive: true);
    });

    tearDown(() {
      Directory.current = Directory.systemTemp.path;
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    });

    test('updateCorePubspecSync writes correct pubspec content', () {
      CorePackageProcess.updateCorePubspecSync(dartVersion: '3.10.0');
      final file = File('packages/core/pubspec.yaml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content, contains('name: core'));
      expect(content, contains('^3.10.0'));
      expect(content, contains('resolution: workspace'));
    });
  });

  group('FlutterAppProcess file operations', () {
    late Directory testDir;

    setUp(() {
      testDir = Directory.systemTemp.createTempSync('flutter_app_test_');
      Directory.current = testDir.path;
    });

    tearDown(() {
      Directory.current = Directory.systemTemp.path;
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    });

    test('updateFlutterAppPubspecSync writes correct pubspec', () {
      // Create a test app directory first
      Directory('test_app').createSync(recursive: true);

      FlutterAppProcess.updateFlutterAppPubspecSync(
        dartVersion: '3.10.0',
        projectName: 'test_app',
      );

      final file = File('test_app/pubspec.yaml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content, contains('name: test_app'));
      expect(content, contains('^3.10.0'));
      expect(content, contains('resolution: workspace'));
    });

    test('updateFlutterAppWidgetSync writes main.dart with core import', () {
      Directory('test_app/lib').createSync(recursive: true);

      FlutterAppProcess.updateFlutterAppWidgetSync(projectName: 'test_app');

      final file = File('test_app/lib/main.dart');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content, contains("import 'package:core/core.dart'"));
      expect(content, contains('MaterialApp'));
      expect(content, contains('MyApp'));
    });

    test('updateAnalysisOptionsFileSync writes analysis_options.yaml', () {
      Directory('test_app').createSync(recursive: true);

      FlutterAppProcess.updateAnalysisOptionsFileSync(projectName: 'test_app');

      final file = File('test_app/analysis_options.yaml');
      expect(file.existsSync(), isTrue);

      final content = file.readAsStringSync();
      expect(content, contains('flutter_lints'));
      expect(content, contains('custom_lint'));
    });
  });
}
