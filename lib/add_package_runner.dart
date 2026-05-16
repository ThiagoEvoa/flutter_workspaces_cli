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

  AddPackageRunner({
    required this.fs,
    required this.runner,
    this.log = print,
  });

  /// Runs the add-package workflow.
  void run(List<String> arguments) {
    final packageProcess = PackageProcess(fs: fs, runner: runner, log: log);
    final dart = DartProcess(runner: runner, log: log);
    final projectNameProcess = ProjectNameProcess(log: log);
    final common = CommonProcess(fs: fs, runner: runner, log: log);
    final workspaceProcess = WorkspaceProcess(fs: fs, runner: runner, log: log);

    try {
      final packageName = projectNameProcess.getProjectName(arguments: arguments);

      if (!fs.directory('packages').existsSync()) {
        throw Exception('⚠️ Directory "packages" not found. Are you in a workspace root?');
      }

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
      log('⚠️ Error: ${e.toString()}');
      throw ExitException(1);
    }
  }
}
