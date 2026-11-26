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

  WorkspaceProcess({required this.fs, required this.runner, this.log = print});

  /// Creates `<name>_workspaces` and changes the current working directory to it.
  ///
  /// The target path is resolved from the current (invocation) directory and is
  /// reserved **exclusively**: an occupied path — an existing directory, file, or
  /// link — is refused *before* any Flutter scaffolding command runs. This means
  /// an existing workspace with user files is never overwritten, and two
  /// overlapping setup runs cannot both claim the same name.
  ///
  /// Returns the exact [Directory] reserved by this invocation. The caller must
  /// use it to restore the working directory and to perform scoped cleanup.
  ///
  /// Parameters:
  /// - `projectName`: base name for the workspace (e.g. `my_app`). The folder
  ///   created will be `my_app_workspaces` and `Directory.current` will be set to
  ///   it.
  ///
  /// Throws:
  /// - [Exception] when the target path is already occupied.
  Directory createWorkspaceFolderSync({required String projectName}) {
    log('📁 Creating workspace folder...');
    final folderName = '${projectName}_workspaces';
    final base = fs.currentDirectory;
    final dir = base.childDirectory(folderName);

    // Refuse an occupied path before scaffolding. `existsSync()` is checked for
    // a directory, a file, and a link (including a dangling link) so any
    // pre-existing entry at the target is detected. This is the exclusive
    // reservation: the path is only created when it is free, and the check uses
    // the injected [FileSystem] so it is cross-platform (no platform-specific
    // commands). Note: `package:file` 7.x does not expose an `exclusive` flag on
    // `Directory.createSync`, so the guard is the reservation mechanism. For
    // truly concurrent processes a small TOCTOU window remains; sequential
    // invocations (the testable case) are fully protected.
    if (dir.existsSync() ||
        base.childFile(folderName).existsSync() ||
        base.childLink(folderName).existsSync()) {
      throw Exception(
        '⚠️ Target path "$folderName" already exists. '
        'Refusing to overwrite it. Aborting setup.',
      );
    }

    dir.createSync();
    fs.currentDirectory = dir;
    log('✅ Workspace folder created: $folderName');
    return dir.absolute;
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

    final workspaceSection = isDart311OrHigher
        ? '  - $projectName\n  - packages/*'
        : '  - $projectName\n  - packages/core';

    final content =
        '''
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
  /// - [SubprocessException] when the `flutter pub add` command exits with a
  ///   non-zero status (message includes the operation, exit status, and
  ///   Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void addingFlutterDependenciesSync() {
    try {
      log('📦 Adding Flutter dependencies...');
      final result = runner.runSync('flutter', [
        'pub',
        'add',
        'cupertino_icons',
      ], runInShell: true);
      checkProcessResult(
        result: result,
        operation: 'flutter pub add cupertino_icons',
      );
      log('✅ Flutter dependencies added');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to add Flutter dependencies: '
        'flutter pub add cupertino_icons could not be started '
        '(missing executable?)',
      );
    }
  }

  /// Adds development dependencies (linting) to the workspace pubspec.
  ///
  /// Throws:
  /// - [SubprocessException] when the `flutter pub add` command exits with a
  ///   non-zero status (message includes the operation, exit status, and
  ///   Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void addingFlutterDevDependenciesSync() {
    try {
      log('📦 Adding Flutter dev dependencies...');
      final result = runner.runSync('flutter', [
        'pub',
        'add',
        '--dev',
        'flutter_lints',
        'custom_lint',
      ], runInShell: true);
      checkProcessResult(
        result: result,
        operation: 'flutter pub add --dev flutter_lints custom_lint',
      );
      log('✅ Flutter dev dependencies added');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to add Flutter dev dependencies: '
        'flutter pub add --dev flutter_lints custom_lint could not be started '
        '(missing executable?)',
      );
    }
  }

  /// Runs `flutter pub get` at the current working directory to resolve dependencies.
  ///
  /// Throws:
  /// - [SubprocessException] when `flutter pub get` exits with a non-zero
  ///   status (message includes the operation, exit status, and Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void runningFlutterPubGetSync() {
    try {
      final result = runner.runSync('flutter', [
        'pub',
        'get',
      ], runInShell: true);
      checkProcessResult(result: result, operation: 'flutter pub get');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to run Flutter pub get: '
        'flutter pub get could not be started (missing executable?)',
      );
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
      log(
        'ℹ️ Wildcard "packages/*" detected. Skipping manual addition of "$packageName".',
      );
      return;
    }

    final packagePath = 'packages/$packageName';

    if (content.contains('- $packagePath')) {
      log('ℹ️ Package "$packageName" is already in the workspace.');
      return;
    }

    final lines = content.split('\n');
    final workspaceIndex = lines.indexWhere(
      (line) => line.trim() == 'workspace:',
    );

    if (workspaceIndex == -1) {
      throw Exception(
        '⚠️ "workspace:" section not found in root pubspec.yaml.',
      );
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
    final cleanVersion = version.startsWith('^')
        ? version.substring(1)
        : version;
    final parts = cleanVersion.split('.');
    if (parts.isEmpty) return false;

    final major = int.tryParse(parts[0]) ?? 0;
    final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    if (major > majorThreshold) return true;
    if (major == majorThreshold && minor >= minorThreshold) return true;
    return false;
  }
}
