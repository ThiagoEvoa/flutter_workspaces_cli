import 'package:file/file.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

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

    try {
      // Remember where we were invoked so the working directory can be restored
      // on every exit path (success or failure).
      initialDirectory = common.getInitialDirectory();

      projectName = projectNameProcess.getProjectName(arguments: arguments);

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
      // Release the reservation sentinel on EVERY exit path, so the next run
      // (retry or a new invocation) is never blocked by a claim this run no
      // longer holds — whether the setup succeeded, failed, or was rolled back.
      // A release failure is logged, not thrown, so the original failure (and
      // the cleanup result, when relevant) is never hidden.
      final reservation = reservedReservation;
      if (reservation != null) {
        final releaseError = reservation.release();
        if (releaseError != null) {
          errorLog(
            '⚠️ Failed to release the workspace reservation: $releaseError',
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
