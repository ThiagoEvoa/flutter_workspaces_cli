import 'package:file/file.dart';
import 'run_reservation.dart';
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
  final void Function(String) errorLog;

  AddPackageRunner({
    required this.fs,
    required this.runner,
    this.log = print,
    void Function(String)? errorLog,
  }) : errorLog = errorLog ?? log;

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
    RunReservation? workspaceLock;
    RunReservation? destinationReservation;

    try {
      packageName = projectNameProcess.getProjectName(arguments: arguments);

      // Acquire the workspace-level lock atomically BEFORE any state capture
      // or filesystem effect. The lock is the mutual-exclusion guard for every
      // workspace-wide resource the run touches: the root manifest, the lockfile,
      // and the packages directory. Acquiring it before validation means a run
      // that would otherwise fail fast never races a concurrent run's commit.
      // A stale lock from an interrupted run is a documented, recoverable
      // leftover (see README "Retries and stale locks").
      workspaceLock = RunReservation.acquire(
        fs: fs,
        sentinelPath:
            '${fs.currentDirectory.path}/.flutter_workspaces_cli.lock',
        contextLabel: 'the workspace lock',
      );

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
      // Use the same shared validator as updateRootPubspecSync so both the
      // add-package flow and the workspace update flow fail identically on
      // missing/malformed/wrong-type workspace fields.
      try {
        parseWorkspaceManifest(
          rootContent,
          expectedRootPath: fs.currentDirectory.path,
        );
      } catch (e) {
        final reason = e.toString().replaceFirst('⚠️ ', '');
        throw Exception(
          '⚠️ Workspace root not found: "pubspec.yaml" in '
          '${fs.currentDirectory.path} $reason '
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

      // Reserve the target package directory EXCLUSIVELY before generating any
      // files. An occupied path — a directory, a file, or a link (including a
      // dangling link) — is refused with the friendly error below. The atomic
      // claim is a sentinel link created in the `packages` directory: creating
      // the link is compare-and-set, so two concurrent invocations cannot both
      // claim the same destination. `package:file` 7.x has no `exclusive` flag
      // on `createSync` (both `Directory.createSync` and `File.createSync` are
      // silent on an existing path), so the sentinel is the reservation
      // mechanism; the friendly error below still fires for an occupied target.
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

      final sentinelPath =
          '${fs.currentDirectory.path}/packages/.$packageName.reserved';
      try {
        destinationReservation = RunReservation.acquire(
          fs: fs,
          sentinelPath: sentinelPath,
          contextLabel: 'the destination package directory "$targetPath"',
        );
      } catch (e) {
        throw Exception(
          '⚠️ Target directory "$targetPath" is already reserved: another '
          'flutter_workspaces_cli run is in progress, or a previous run was '
          'interrupted and left a reservation behind. Refusing to overwrite it. '
          'Aborting. Details: $e',
        );
      }

      // Detect the Flutter toolchain's Dart version BEFORE any mutation or
      // filesystem effect: a below-floor toolchain is rejected here, before
      // the reserved directory exists and before the root manifest or
      // lockfile is read or rewritten. A read-only manifest validation and
      // target reservation (above) deliberately run first, so an occupied or
      // missing target never triggers a Flutter/Dart process.
      final dartVersion = dart.getDartVersionSync();

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

      packageProcess.createPackageSync(packageName: packageName);
      packageProcess.updatePubspecSync(
        packageName: packageName,
        dartVersion: dartVersion,
      );

      workspaceProcess.updateRootPubspecSync(packageName: packageName);
      workspaceProcess.runningFlutterPubGetSync();

      log('\n🎉 Package "$packageName" added successfully!');
    } on ArgumentError catch (e) {
      errorLog('⚠️ Error: ${e.message}');
      final parser = buildNameParser(
        helpText: 'The name of the package. eg: "my_feature"',
      );
      common.printUsage(
        parser,
        sink: errorLog,
        usageLine: kAddPackageUsageLine,
      );
      throw ExitException(64);
    } catch (e) {
      // Record the original failure; it is rethrown below so a cleanup problem
      // can never hide it.
      errorLog('⚠️ Error: ${e.toString()}');

      if (didCaptureState) {
        // Restore the root manifest to its original content.
        try {
          if (originalRootPubspec != null) {
            fs.file('pubspec.yaml').writeAsStringSync(originalRootPubspec);
          }
        } catch (restoreError) {
          errorLog('⚠️ Failed to restore root pubspec.yaml: $restoreError');
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
          errorLog('⚠️ Failed to restore pubspec.lock: $restoreError');
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
          errorLog('⚠️ Cleanup also failed: $cleanupError');
        }
      }
      throw ExitException(1);
    } finally {
      // Release the destination reservation and the workspace lock on EVERY
      // exit path — success, failure, rollback, and usage error — so the next
      // run is never blocked by a claim this run no longer holds. Releases are
      // best-effort (logged, not thrown): the original failure is never hidden.
      final destination = destinationReservation;
      if (destination != null) {
        final releaseError = destination.release();
        if (releaseError != null) {
          errorLog(
            '⚠️ Failed to release the destination package reservation: $releaseError',
          );
        }
      }
      final lock = workspaceLock;
      if (lock != null) {
        final releaseError = lock.release();
        if (releaseError != null) {
          errorLog('⚠️ Failed to release the workspace lock: $releaseError');
        }
      }
    }
  }
}
