import 'dart:io';

import 'package:file/local.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

void main(List<String> arguments) {
  final fs = const LocalFileSystem();
  final processRunner = const RealProcessRunner();

  if (arguments.isNotEmpty && arguments.first == 'add-package') {
    final addPackageRunner = AddPackageRunner(
      fs: fs,
      runner: processRunner,
    );
    try {
      addPackageRunner.run(arguments.sublist(1));
    } on ExitException catch (e) {
      exit(e.code);
    } catch (e) {
      print('Unexpected error: $e');
      exit(1);
    }
    return;
  }

  final runner = SetupRunner(
    fs: fs,
    runner: processRunner,
  );

  try {
    runner.run(arguments);
  } on ExitException catch (e) {
    exit(e.code);
  } catch (e) {
    print('Unexpected error: $e');
    exit(1);
  }
}
