import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

void main(List<String> arguments) {
  Directory? initialDirectory;
  String? projectName;
  bool didCreateWorkspace = false;

  try {
    initialDirectory = CommonProcess.getInitialDirectory();

    projectName = ProjectNameProcess.getProjectName(arguments: arguments);

    FlutterProcess.isFlutterInstalledSync();

    final dartVersion = DartProcess.getDartVersionSync();

    WorkspaceProcess.createWorkspaceFolderSync(projectName: projectName);
    didCreateWorkspace = true;

    FlutterAppProcess.createFlutterAppSync(projectName: projectName);

    FlutterAppProcess.updateAnalysisOptionsFileSync(projectName: projectName);

    FlutterAppProcess.updateFlutterAppWidgetSync(projectName: projectName);

    FlutterAppProcess.updateFlutterAppPubspecSync(
      dartVersion: dartVersion,
      projectName: projectName,
    );

    WorkspaceProcess.moveConfigsToWorkspaceRootSync(
      projectName: projectName,
      initialDirectory: initialDirectory,
    );

    WorkspaceProcess.createRootPubspecSync(
      dartVersion: dartVersion,
      projectName: projectName,
    );

    WorkspaceProcess.createPackagesFolderSync();

    CorePackageProcess.createCorePackageSync();

    CorePackageProcess.updateCorePubspecSync(dartVersion: dartVersion);

    CommonProcess.deleteFilesSync(filePath: 'packages/core/.gitignore');

    CommonProcess.deleteFilesSync(
      filePath: 'packages/core/analysis_options.yaml',
    );

    WorkspaceProcess.addingFlutterDependenciesSync();

    WorkspaceProcess.addingFlutterDevDependenciesSync();

    print('\n🎉 Flutter workspace setup completed successfully!');
  } on ArgumentError catch (e) {
    // Missing or invalid --name argument: print usage and exit without reverting.
    print('⚠️ Error: ${e.message}');
    final parser = ArgParser()
      ..addOption('name', abbr: 'n', help: 'The name of the project.');
    CommonProcess.printUsage(parser);
    exit(64);
  } catch (e) {
    // Other errors: revert if workspace was createds.
    print('⚠️ Error: ${e.toString()}');
    if (didCreateWorkspace) {
      CommonProcess.revertAllProcesses(
        initialDirectory: initialDirectory ?? Directory.current,
        projectName: projectName ?? 'unknown',
      );
    }
    exit(1);
  }
}
