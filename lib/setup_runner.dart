import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

/// Runner that orchestrates the workspace setup workflow.
class SetupRunner {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  SetupRunner({required this.fs, required this.runner, this.log = print});

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
    Directory? reservedDirectory;
    String? projectName;
    bool didCreateWorkspace = false;

    try {
      // Remember where we were invoked so the working directory can be restored
      // on every exit path (success or failure).
      initialDirectory = common.getInitialDirectory();

      projectName = projectNameProcess.getProjectName(arguments: arguments);

      // Reserve the workspace directory EXCLUSIVELY before any Flutter/Dart
      // scaffolding command runs. An occupied path (an existing directory, file,
      // or link) is refused here, so an existing workspace with user files is
      // never touched and no `flutter`/`dart` process is invoked for a rejected
      // attempt. The exact directory is captured so rollback is scoped to it.
      reservedDirectory = workspace.createWorkspaceFolderSync(
        projectName: projectName,
      );
      didCreateWorkspace = true;

      flutter.isFlutterInstalledSync();

      final dartVersion = dart.getDartVersionSync();

      flutterApp.createFlutterAppSync(projectName: projectName);

      flutterApp.updateAnalysisOptionsFileSync(projectName: projectName);

      flutterApp.updateFlutterAppWidgetSync(projectName: projectName);

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
      log('⚠️ Error: ${e.message}');
      final parser = ArgParser()
        ..addOption('name', abbr: 'n', help: 'The name of the project.');
      common.printUsage(parser);
      throw ExitException(64);
    } catch (e) {
      // Record the original failure; it is rethrown below so a cleanup problem
      // can never hide it.
      log('⚠️ Error: ${e.toString()}');

      // Restore the process working directory on EVERY exit path, *before*
      // cleanup, so the reserved folder (never the invocation directory) is the
      // only thing that may be removed.
      try {
        if (initialDirectory != null) {
          fs.currentDirectory = initialDirectory;
        }
      } catch (restoreError) {
        log('⚠️ Failed to restore the working directory: $restoreError');
      }

      // Clean up ONLY the reserved directory. Surface any cleanup error alongside
      // the original failure instead of letting it replace the original.
      if (didCreateWorkspace && reservedDirectory != null) {
        final cleanupError = common.revertAllProcesses(
          reservedDirectory: reservedDirectory,
        );
        if (cleanupError != null) {
          log('⚠️ Cleanup also failed: $cleanupError');
        }
      }
      throw ExitException(1);
    } finally {
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
