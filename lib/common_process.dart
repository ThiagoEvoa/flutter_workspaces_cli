import 'dart:io';

import 'package:args/args.dart';

/// Common CLI helpers used across the package.
///
/// Shared utilities for printing usage, remembering the initial working
/// directory, and performing a simple revert operation when an error occurs.
abstract class CommonProcess {
  /// Prints a brief usage summary followed by the parser usage details.
  ///
  /// Parameters:
  /// - `parser`: the [ArgParser] configured with available options.
  static void printUsage(ArgParser parser) {
    print('\nUsage: dart flutter_workspaces_cli.dart [arguments]');
    print(parser.usage);
  }

  /// Returns the directory where the CLI was initially invoked.
  static Directory getInitialDirectory() {
    return Directory.current;
  }

  /// Attempts to remove the created workspace folder when reverting.
  ///
  /// Parameters:
  /// - `initialDirectory`: the directory that was current before scaffolding.
  /// - `projectName`: the base project name used to determine the workspace folder.
  ///
  /// Throws:
  /// - [Exception] when the revert (remove) command fails.
  static void revertAllProcesses({
    required Directory initialDirectory,
    required String projectName,
  }) {
    try {
      Process.runSync(
        'rm',
        ['-rf', '${projectName}_workspaces'],
        workingDirectory: initialDirectory.path,
        runInShell: true,
      );
    } catch (_) {
      throw Exception('⚠️ Failed to revert workspace processes');
    }
  }
}
