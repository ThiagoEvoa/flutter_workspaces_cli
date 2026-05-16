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
    final isDart311OrHigher = _isVersionAtLeast(dartVersion, 3, 11);

    final workspaceSection =
        isDart311OrHigher
            ? '  - $projectName\n  - packages/*'
            : '  - $projectName\n  - packages/core';

    final content = '''
name: _
version: 0.1.0
description: A Dart workspace example
publish_to: none

environment:
  sdk: ^$dartVersion

workspace:
$workspaceSection

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

  /// Updates the root `pubspec.yaml` to include a new package in the workspace.
  ///
  /// Parameters:
  /// - `packageName`: the name of the new package to add.
  void updateRootPubspecSync({required String packageName}) {
    log('📝 Updating root pubspec.yaml to include "$packageName"...');
    final file = fs.file('pubspec.yaml');

    if (!file.existsSync()) {
      throw Exception('⚠️ Root pubspec.yaml not found.');
    }

    final content = file.readAsStringSync();

    if (content.contains('- packages/*')) {
      log('ℹ️ Wildcard "packages/*" detected. Skipping manual addition of "$packageName".');
      return;
    }

    final packagePath = 'packages/$packageName';

    if (content.contains('- $packagePath')) {
      log('ℹ️ Package "$packageName" is already in the workspace.');
      return;
    }

    final lines = content.split('\n');
    final workspaceIndex = lines.indexWhere((line) => line.trim() == 'workspace:');

    if (workspaceIndex == -1) {
      throw Exception('⚠️ "workspace:" section not found in root pubspec.yaml.');
    }

    // Find the end of the workspace list
    int insertIndex = workspaceIndex + 1;
    while (insertIndex < lines.length &&
        (lines[insertIndex].trim().startsWith('-') ||
            lines[insertIndex].trim().isEmpty ||
            lines[insertIndex].trim().startsWith('#'))) {
      insertIndex++;
    }

    lines.insert(insertIndex, '  - $packagePath');
    file.writeAsStringSync(lines.join('\n'));
    log('✅ Root pubspec.yaml updated');
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

  bool _isVersionAtLeast(
    String version,
    int majorThreshold,
    int minorThreshold,
  ) {
    final cleanVersion =
        version.startsWith('^') ? version.substring(1) : version;
    final parts = cleanVersion.split('.');
    if (parts.isEmpty) return false;

    final major = int.tryParse(parts[0]) ?? 0;
    final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    if (major > majorThreshold) return true;
    if (major == majorThreshold && minor >= minorThreshold) return true;
    return false;
  }
}
