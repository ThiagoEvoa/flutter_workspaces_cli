import 'package:file/file.dart';
import 'process_runner.dart';

/// Utilities for creating and configuring a Flutter workspace directory.
///
/// This class provides synchronous helpers used by the CLI to scaffold a
/// workspace, create package folders, add common dependencies, and resolve
/// workspace dependencies.
class WorkspaceProcess {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  WorkspaceProcess({
    required this.fs,
    required this.runner,
    this.log = print,
  });

  /// Creates `<name>_workspaces` and changes the current working directory.
  ///
  /// Parameters:
  /// - `projectName`: base name for the workspace (e.g. `my_app`). The folder created
  ///   will be `my_app_workspaces` and `Directory.current` will be set to it.
  void createWorkspaceFolderSync({required String projectName}) {
    log('📁 Creating workspace folder...');
    final folderName = '${projectName}_workspaces';
    final dir = fs.directory(folderName);
    dir.createSync(recursive: true);
    fs.currentDirectory = dir;
    log('✅ Workspace folder created: $folderName');
  }

  /// Writes the workspace root `pubspec.yaml` with basic configuration.
  ///
  /// Parameters:
  /// - `dartVersion`: Dart SDK version constraint (e.g. `3.10.8`).
  /// - `projectName`: the main application folder name included in the workspace.
  void createRootPubspecSync({
    required String dartVersion,
    required String projectName,
  }) {
    log('📝 Creating root pubspec.yaml...');
    final content = '''
name: _
version: 0.1.0
description: A Dart workspace example
publish_to: none

environment:
  sdk: ^$dartVersion

workspace:
  - $projectName
  - packages/core
  # If using dart 3.11+ with the new workspace syntax, uncomment the line below and remove the `workspace` section above. # - packages/*
  # - packages/*

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
''';

    final file = fs.file('pubspec.yaml');
    file.writeAsStringSync(content);
    log('✅ Root pubspec.yaml created');
  }

  /// Creates the `packages` folder used for shared packages.
  void createPackagesFolderSync() {
    log('📁 Creating packages folder...');
    final dir = fs.directory('packages');
    dir.createSync(recursive: true);
    log('✅ Packages folder created');
  }

  /// Adds common runtime Flutter dependencies to the workspace pubspec.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to add Flutter dependencies` on failure.
  void addingFlutterDependenciesSync() {
    try {
      log('📦 Adding Flutter dependencies...');
      runner.runSync('flutter', [
        'pub',
        'add',
        'cupertino_icons',
      ], runInShell: true);
      log('✅ Flutter dependencies added');
    } catch (_) {
      throw Exception('⚠️ Failed to add Flutter dependencies');
    }
  }

  /// Adds development dependencies (linting) to the workspace pubspec.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to add Flutter dev dependencies` on failure.
  void addingFlutterDevDependenciesSync() {
    try {
      log('📦 Adding Flutter dev dependencies...');
      runner.runSync('flutter', [
        'pub',
        'add',
        '--dev',
        'flutter_lints',
        'custom_lint',
      ], runInShell: true);
      log('✅ Flutter dev dependencies added');
    } catch (_) {
      throw Exception('⚠️ Failed to add Flutter dev dependencies');
    }
  }

  /// Runs `flutter pub get` at the current working directory to resolve dependencies.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to run Flutter pub get` on failure.
  void runningFlutterPubGetSync() {
    try {
      runner.runSync('flutter', ['pub', 'get'], runInShell: true);
    } catch (_) {
      throw Exception('⚠️ Failed to run Flutter pub get');
    }
  }

  /// Moves configuration files from the Flutter app folder to the workspace root.
  ///
  /// Moves `.gitignore` and `analysis_options.yaml` so they apply globally.
  ///
  /// Parameters:
  /// - `projectName`: the name of the Flutter app folder.
  /// - `initialDirectory`: the directory that was current before scaffolding.
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to move configuration files` on failure.
  void moveConfigsToWorkspaceRootSync({
    required String projectName,
    required Directory initialDirectory,
  }) {
    log('🚚 Moving configuration files to workspace root...');
    final files = ['.gitignore', 'analysis_options.yaml'];

    for (final fileName in files) {
      try {
        final source = fs.file('$projectName/$fileName');
        if (source.existsSync()) {
          source.renameSync(fileName);
          log('✅ Moved $fileName to workspace root');
        }
      } catch (_) {
        throw Exception('⚠️ Failed to move $fileName');
      }
    }
  }
}
