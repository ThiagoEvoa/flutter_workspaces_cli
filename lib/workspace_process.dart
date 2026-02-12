import 'dart:io';

/// Utilities for creating and configuring a Flutter workspace directory.
///
/// This class provides synchronous helpers used by the CLI to scaffold a
/// workspace, create package folders, add common dependencies, and resolve
/// workspace dependencies.
abstract class WorkspaceProcess {
  /// Creates `<name>_workspaces` and changes the current working directory.
  ///
  /// Parameters:
  /// - `name`: base name for the workspace (e.g. `my_app`). The folder created
  ///   will be `my_app_workspaces` and `Directory.current` will be set to it.
  static void createWorkspaceFolderSync({required String projectName}) {
    print('📁 Creating workspace folder...');
    final folderName = '${projectName}_workspaces';
    final dir = Directory(folderName);
    dir.createSync(recursive: true);
    Directory.current = dir.absolute.path;
    print('✅ Workspace folder created: $folderName');
  }

  /// Writes the workspace root `pubspec.yaml` with basic configuration.
  ///
  /// Parameters:
  /// - `sdkVersion`: Dart SDK version constraint (e.g. `3.10.8`).
  /// - `name`: the main application folder name included in the workspace.
  static void createRootPubspecSync({
    required String dartVersion,
    required String projectName,
  }) {
    print('📝 Creating root pubspec.yaml...');
    final content =
        '''
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

    final file = File('pubspec.yaml');
    file.writeAsStringSync(content);
    print('✅ Root pubspec.yaml created');
  }

  /// Creates the `packages` folder used for shared packages.
  static void createPackagesFolderSync() {
    print('📁 Creating packages folder...');
    final dir = Directory('packages');
    dir.createSync(recursive: true);
    print('✅ Packages folder created');
  }

  /// Adds common runtime Flutter dependencies to the workspace pubspec.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to add Flutter dependencies` on failure.
  static void addingFlutterDependenciesSync() {
    try {
      print('📦 Adding Flutter dependencies...');
      Process.runSync('flutter', [
        'pub',
        'add',
        'cupertino_icons',
      ], runInShell: true);
      print('✅ Flutter dependencies added');
    } catch (_) {
      throw Exception('⚠️ Failed to add Flutter dependencies');
    }
  }

  /// Adds development dependencies (linting) to the workspace pubspec.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to add Flutter dev dependencies` on failure.
  static void addingFlutterDevDependenciesSync() {
    try {
      print('📦 Adding Flutter dev dependencies...');
      Process.runSync('flutter', [
        'pub',
        'add',
        '--dev',
        'flutter_lints',
        'custom_lint',
      ], runInShell: true);
      print('✅ Flutter dev dependencies added');
    } catch (_) {
      throw Exception('⚠️ Failed to add Flutter dev dependencies');
    }
  }

  /// Runs `flutter pub get` at the current working directory to resolve dependencies.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to run Flutter pub get` on failure.
  static void runningFlutterPubGetSync() {
    try {
      Process.runSync('flutter', ['pub', 'get'], runInShell: true);
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
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to move configuration files` on failure.
  static void moveConfigsToWorkspaceRootSync({
    required String projectName,
    required Directory initialDirectory,
  }) {
    print('🚚 Moving configuration files to workspace root...');
    final files = ['.gitignore', 'analysis_options.yaml'];

    for (final fileName in files) {
      try {
        final source = File('$projectName/$fileName');
        if (source.existsSync()) {
          source.renameSync(fileName);
          print('✅ Moved $fileName to workspace root');
        }
      } catch (_) {
        throw Exception('⚠️ Failed to move $fileName');
      }
    }
  }
}
