import 'dart:io';

import 'package:file/local.dart';
import 'package:flutter_workspaces_cli/flutter_workspaces_cli.dart';

void main(List<String> arguments) {
  final cli = Cli(
    fs: LocalFileSystem(),
    runner: RealProcessRunner(),
    log: print,
    errorLog: (message) => stderr.writeln(message),
  );
  exit(cli.run(arguments));
}
