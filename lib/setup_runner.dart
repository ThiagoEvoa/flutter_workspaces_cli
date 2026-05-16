import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

/// Runner that orchestrates the workspace setup workflow.
class SetupRunner {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  SetupRunner({
    required this.fs,
    required this.runner,
    this.log = print,
  });

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
    String? projectName;
    bool didCreateWorkspace = false;

    try {
      initialDirectory = common.getInitialDirectory();

      projectName = projectNameProcess.getProjectName(arguments: arguments);

      flutter.isFlutterInstalledSync();

      final dartVersion = dart.getDartVersionSync();

      workspace.createWorkspaceFolderSync(projectName: projectName);
      didCreateWorkspace = true;

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

      common.deleteFilesSync(
        filePath: 'packages/core/analysis_options.yaml',
      );

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
      log('⚠️ Error: ${e.toString()}');
      if (didCreateWorkspace) {
        common.revertAllProcesses(
          initialDirectory: initialDirectory ?? fs.currentDirectory,
          projectName: projectName ?? 'unknown',
        );
      }
      throw ExitException(1);
    }
  }
}

class ExitException implements Exception {
  final int code;
  ExitException(this.code);

  @override
  String toString() => 'ExitException(code: $code)';
}
