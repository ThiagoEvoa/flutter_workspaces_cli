import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package_process.dart';
import 'process_runner.dart';
import 'dart_process.dart';
import 'setup_runner.dart';
import 'project_name_process.dart';
import 'common_process.dart';
import 'workspace_process.dart';

/// Runner that orchestrates adding a new package to an existing workspace.
class AddPackageRunner {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  AddPackageRunner({required this.fs, required this.runner, this.log = print});

  /// Runs the add-package workflow.
  void run(List<String> arguments) {
    final packageProcess = PackageProcess(fs: fs, runner: runner, log: log);
    final dart = DartProcess(runner: runner, log: log);
    final projectNameProcess = ProjectNameProcess(log: log);
    final common = CommonProcess(fs: fs, runner: runner, log: log);
    final workspaceProcess = WorkspaceProcess(fs: fs, runner: runner, log: log);

    String? packageName;
    bool didCaptureState = false;
    String? originalRootPubspec;
    String? originalLockfileContent;
    bool lockfileExistedBefore = false;
    Directory? reservedDirectory;

    try {
      packageName = projectNameProcess.getProjectName(arguments: arguments);

      // Validate the workspace root BEFORE any scaffolding command runs.
      // A missing manifest or a missing/invalid "workspace:" section leaves
      // every file untouched and reports where the command expected the root.
      final rootPubspec = fs.file('pubspec.yaml');
      if (!rootPubspec.existsSync()) {
        throw Exception(
          '⚠️ Workspace root not found: expected a "pubspec.yaml" with a '
          '"workspace:" section in ${fs.currentDirectory.path}. '
          'Are you in a workspace root?',
        );
      }
      String rootContent;
      try {
        rootContent = rootPubspec.readAsStringSync();
      } catch (_) {
        throw Exception(
          '⚠️ Workspace root not found: could not read "pubspec.yaml" in '
          '${fs.currentDirectory.path}. Are you in a workspace root?',
        );
      }
      final hasWorkspaceSection = rootContent
          .split('\n')
          .any((line) => line.trim() == 'workspace:');
      if (!hasWorkspaceSection) {
        throw Exception(
          '⚠️ Workspace root not found: "pubspec.yaml" in '
          '${fs.currentDirectory.path} has no "workspace:" section. '
          'Are you in a workspace root?',
        );
      }

      final packagesDir = fs.directory('packages');
      if (!packagesDir.existsSync()) {
        throw Exception(
          '⚠️ Directory "packages" not found in '
          '${fs.currentDirectory.path}. Are you in a workspace root?',
        );
      }

      // Reserve the target package directory EXCLUSIVELY before generating
      // any files. An occupied path — a directory, a file, or a link (including
      // a dangling link) — is refused. `package:file` 7.x has no `exclusive`
      // flag on `createSync`, so the `existsSync()` guard is the reservation
      // mechanism (same pattern as the setup workspace reservation).
      final targetPath = 'packages/$packageName';
      final targetDir = fs.directory(targetPath);
      final targetFile = packagesDir.childFile(packageName);
      final targetLink = packagesDir.childLink(packageName);
      if (targetDir.existsSync() ||
          targetFile.existsSync() ||
          targetLink.existsSync()) {
        throw Exception(
          '⚠️ Target directory "$targetPath" already exists. '
          'Refusing to overwrite it. Aborting.',
        );
      }

      // Capture state BEFORE mutating anything: the original root manifest
      // content and the pre-existing lockfile (content or absence). Rollback
      // restores exactly what this invocation changed.
      originalRootPubspec = rootContent;
      final lockfile = fs.file('pubspec.lock');
      lockfileExistedBefore = lockfile.existsSync();
      originalLockfileContent = lockfileExistedBefore
          ? lockfile.readAsStringSync()
          : null;
      reservedDirectory = targetDir;
      didCaptureState = true;

      final dartVersion = dart.getDartVersionSync();

      packageProcess.createPackageSync(packageName: packageName);
      packageProcess.updatePubspecSync(
        packageName: packageName,
        dartVersion: dartVersion,
      );

      workspaceProcess.updateRootPubspecSync(packageName: packageName);
      workspaceProcess.runningFlutterPubGetSync();

      log('\n🎉 Package "$packageName" added successfully!');
    } on ArgumentError catch (e) {
      log('⚠️ Error: ${e.message}');
      final parser = ArgParser()
        ..addOption('name', abbr: 'n', help: 'The name of the package.');
      common.printUsage(parser);
      throw ExitException(64);
    } catch (e) {
      // Record the original failure; it is rethrown below so a cleanup problem
      // can never hide it.
      log('⚠️ Error: ${e.toString()}');

      if (didCaptureState) {
        // Restore the root manifest to its original content.
        try {
          if (originalRootPubspec != null) {
            fs.file('pubspec.yaml').writeAsStringSync(originalRootPubspec);
          }
        } catch (restoreError) {
          log('⚠️ Failed to restore root pubspec.yaml: $restoreError');
        }

        // Restore the lockfile: its original content, or its absence if it was
        // created by this invocation's pub get.
        try {
          final lockfile = fs.file('pubspec.lock');
          if (lockfileExistedBefore && originalLockfileContent != null) {
            lockfile.writeAsStringSync(originalLockfileContent);
          } else if (lockfile.existsSync()) {
            lockfile.deleteSync();
          }
        } catch (restoreError) {
          log('⚠️ Failed to restore pubspec.lock: $restoreError');
        }

        // Remove ONLY the reserved package directory and everything under it.
        // Scoped to the exact reserved path; never by name. Report cleanup
        // failure alongside the original error instead of throwing from it.
        try {
          final reserved = reservedDirectory;
          if (reserved != null && reserved.existsSync()) {
            log(
              '🧹 Cleaning up reserved package directory: ${reserved.path}...',
            );
            reserved.deleteSync(recursive: true);
            log('✅ Reserved package directory removed');
          }
        } catch (cleanupError) {
          log('⚠️ Cleanup also failed: $cleanupError');
        }
      }
      throw ExitException(1);
    }
  }
}
