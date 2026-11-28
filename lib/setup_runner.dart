import 'package:file/file.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';
import 'package:flutter_workspaces_cli/run_reservation.dart';

/// Runner that orchestrates the workspace setup workflow.
class SetupRunner {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;
  final void Function(String) errorLog;

  SetupRunner({
    required this.fs,
    required this.runner,
    this.log = print,
    void Function(String)? errorLog,
  }) : errorLog = errorLog ?? log;

  /// Runs the setup workflow.
  void run(List<String> arguments) {
    final common = CommonProcess(fs: fs, runner: runner, log: log);
    final projectNameProcess = ProjectNameProcess(log: log);
    final flutter = FlutterProcess(runner: runner, log: log);
    final dart = DartProcess(runner: runner, log: log);
    final workspace = WorkspaceProcess(fs: fs, runner: runner, log: log);
    final flutterApp = FlutterAppProcess(fs: fs, runner: runner, log: log);
    final corePackage = CorePackageProcess(fs: fs, runner: runner, log: log);

    Directory? initialDirectory;
    ReservedWorkspace? reservedWorkspace;
    String? projectName;
    bool didCreateWorkspace = false;
    RunReservation? reservedReservation;
    // The workspace-wide lock that add-package also takes (the same
    // `<workspace>/.flutter_workspaces_cli.lock` path). See the cross-command
    // coordination note where it is acquired, below.
    RunReservation? workspaceLock;

    try {
      // Remember where we were invoked so the working directory can be restored
      // on every exit path (success or failure).
      initialDirectory = common.getInitialDirectory();

      projectName = projectNameProcess.getProjectName(arguments: arguments);

      // Reject the built-in shared package name (Issue #39). Setup ALWAYS
      // generates `packages/<kCorePackageName>` (see [CorePackageProcess]); a
      // workspace app whose own name equals that member name collides with it,
      // so Flutter refuses to resolve the duplicate workspace members and the
      // CLI rolls back after the scaffolding work. Fail fast here instead: throw
      // an ArgumentError, which the `on ArgumentError` handler below routes to
      // exit 64 with the setup usage. This runs BEFORE the read-only
      // availability guard, BEFORE any Flutter/Dart subprocess, and BEFORE the
      // workspace reservation or any filesystem write, so a rejected name leaves
      // no workspace directory, no reservation sentinel, and no manifest behind.
      // The check is setup-specific: `add-package` keeps its own workspace and
      // destination checks and is deliberately not affected.
      if (projectName == kCorePackageName) {
        throw ArgumentError(
          'Invalid project name "$projectName": the name '
          '"$kCorePackageName" is reserved for the shared package that setup '
          'always generates under packages/$kCorePackageName. Choose a '
          'different app name.',
        );
      }

      // Exclusively reserve the workspace target path BEFORE any Flutter/Dart
      // process or filesystem write runs. An occupied path (an existing
      // directory, file, or link) is refused here, so an existing workspace
      // with user files is never touched and no `flutter` process is invoked
      // for a rejected attempt. This is a read-only guard; the folder itself
      // is created later (below) so detection runs before any filesystem
      // write. The exact directory is captured so rollback is scoped to it.
      workspace.assertWorkspaceFolderAvailableSync(projectName: projectName);

      flutter.isFlutterInstalledSync();

      // Detect the Flutter toolchain's Dart version BEFORE any filesystem
      // writes happen (the reservation and every scaffold step come after). A
      // detection failure is thrown here, before the workspace folder exists,
      // and the workspace is never created or rolled back.
      final dartVersion = dart.getDartVersionSync();

      reservedWorkspace = workspace.createWorkspaceFolderSync(
        projectName: projectName,
      );
      reservedReservation = reservedWorkspace.reservation;
      didCreateWorkspace = true;

      // Cross-command coordination (Issue #38): the workspace directory now
      // exists and this run is about to perform the shared writes — the root
      // manifest, the `packages/` folder, the core package, and dependency
      // resolution — and may roll them back. Hold the workspace-wide lock that
      // `add-package` also takes (the *same* `<workspace>/.flutter_workspaces_cli.lock`
      // path it acquires first thing) for the entire remaining workflow, through
      // every shared write and any rollback, so an `add-package` started against
      // this same workspace *while setup is still active* contends on the lock
      // and refuses before it can snapshot or mutate the half-built workspace.
      //
      // The lock lives inside the just-reserved directory (created exclusively by
      // the sentinel claim above), so no other run can be inside it: the claim is
      // uncontended in production and is an ordinary exclusive *file* create — the
      // same standard-Windows-safe primitive as #37 (no symlink, no elevated
      // token). It is released on every exit path in `finally`, after rollback,
      // so a completed or failed setup never blocks a later retry or a different
      // workspace.
      try {
        workspaceLock = RunReservation.acquire(
          fs: fs,
          sentinelPath:
              '${fs.currentDirectory.path}/.flutter_workspaces_cli.lock',
          contextLabel: 'the workspace lock',
        );
      } on ReservationAcquisitionException catch (e) {
        // Uncontended in production (the directory was just reserved
        // exclusively), but if another run is in progress or a stale lock was
        // left behind, refuse with a clear busy/retry message and let the outer
        // handler roll back this run's own output.
        throw Exception(
          '⚠️ The workspace lock is already reserved: another '
          'flutter_workspaces_cli run is in progress on this workspace, or a '
          'previous run was interrupted and left a reservation behind at '
          '"${e.sentinelPath}". If no other run is in progress, remove that '
          'file manually and retry. Aborting setup. Details: ${e.underlying}',
        );
      }

      flutterApp.createFlutterAppSync(projectName: projectName);

      flutterApp.updateAnalysisOptionsFileSync(projectName: projectName);

      flutterApp.updateFlutterAppWidgetSync(projectName: projectName);

      flutterApp.updateFlutterAppWidgetTestSync(projectName: projectName);

      flutterApp.updateFlutterAppPubspecSync(
        dartVersion: dartVersion,
        projectName: projectName,
      );

      workspace.moveConfigsToWorkspaceRootSync(
        projectName: projectName,
        initialDirectory: initialDirectory,
      );

      workspace.createRootPubspecSync(
        dartVersion: dartVersion,
        projectName: projectName,
      );

      workspace.createPackagesFolderSync();

      corePackage.createCorePackageSync();

      corePackage.updateCorePubspecSync(dartVersion: dartVersion);

      common.deleteFilesSync(filePath: 'packages/core/.gitignore');

      common.deleteFilesSync(filePath: 'packages/core/analysis_options.yaml');

      workspace.addingFlutterDependenciesSync();

      workspace.addingFlutterDevDependenciesSync();

      log('\n🎉 Flutter workspace setup completed successfully!');
    } on ArgumentError catch (e) {
      errorLog('⚠️ Error: ${e.message}');
      final parser = buildNameParser();
      common.printUsage(parser, sink: errorLog, usageLine: kSetupUsageLine);
      throw ExitException(64);
    } catch (e) {
      // Record the original failure; it is rethrown below so a cleanup problem
      // can never hide it.
      errorLog('⚠️ Error: ${e.toString()}');

      // Restore the process working directory on EVERY exit path, *before*
      // cleanup, so the reserved folder (never the invocation directory) is the
      // only thing that may be removed.
      try {
        if (initialDirectory != null) {
          fs.currentDirectory = initialDirectory;
        }
      } catch (restoreError) {
        errorLog('⚠️ Failed to restore the working directory: $restoreError');
      }

      // Clean up ONLY the reserved directory. Surface any cleanup error alongside
      // the original failure instead of letting it replace the original.
      if (didCreateWorkspace && reservedWorkspace != null) {
        final cleanupError = common.revertAllProcesses(
          reservedDirectory: reservedWorkspace.directory,
        );
        if (cleanupError != null) {
          errorLog('⚠️ Cleanup also failed: $cleanupError');
        }
      }
      throw ExitException(1);
    } finally {
      // Release the reservation sentinels on EVERY exit path, so the next run
      // (retry or a new invocation) is never blocked by a claim this run no
      // longer holds — whether the setup succeeded, failed, or was rolled back.
      // A release failure is logged, not thrown, so the original failure (and
      // the cleanup result, when relevant) is never hidden.
      final reservation = reservedReservation;
      if (reservation != null) {
        final releaseError = reservation.release();
        if (releaseError != null) {
          errorLog(
            '⚠️ Failed to release the workspace reservation at '
            '"${reservation.sentinelPath}": $releaseError',
          );
        }
      }
      final lock = workspaceLock;
      if (lock != null) {
        final releaseError = lock.release();
        if (releaseError != null) {
          errorLog(
            '⚠️ Failed to release the workspace lock at '
            '"${lock.sentinelPath}": $releaseError',
          );
        }
      }
      // Guarantee the working directory is restored on the success path as well
      // (belt and suspenders around the restore performed above).
      if (initialDirectory != null) {
        fs.currentDirectory = initialDirectory;
      }
    }
  }
}

class ExitException implements Exception {
  final int code;
  ExitException(this.code);

  @override
  String toString() => 'ExitException(code: $code)';
}
