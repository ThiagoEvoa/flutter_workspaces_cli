import 'package:args/args.dart';
import 'package:file/file.dart';

import 'process_runner.dart';

/// Common CLI helpers used across the package.
///
/// Shared utilities for printing usage, remembering the initial working
/// directory, and performing a simple revert operation when an error occurs.
class CommonProcess {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  CommonProcess({required this.fs, required this.runner, this.log = print});

  /// Prints a brief usage summary followed by the parser usage details.
  ///
  /// Parameters:
  /// - `parser`: the [ArgParser] configured with available options.
  void printUsage(ArgParser parser) {
    log('\nUsage: dart flutter_workspaces_cli.dart [arguments]');
    log(parser.usage);
  }

  /// Returns the directory where the CLI was initially invoked.
  Directory getInitialDirectory() {
    return fs.currentDirectory;
  }

  /// Attempts to remove the created workspace folder when reverting.
  ///
  /// Parameters:
  /// - `initialDirectory`: the directory that was current before scaffolding.
  /// - `projectName`: the base project name used to determine the workspace folder.
  ///
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to revert workspace processes` on failure.
  void revertAllProcesses({
    required Directory initialDirectory,
    required String projectName,
  }) {
    try {
      runner.runSync(
        'rm',
        ['-rf', '${projectName}_workspaces'],
        workingDirectory: initialDirectory.path,
        runInShell: true,
      );
    } catch (_) {
      throw Exception('⚠️ Failed to revert workspace processes');
    }
  }

  /// Deletes a file from the specified path.
  ///
  /// Parameters:
  /// - `filePath`: The path to the file.
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to delete file` on failure.
  void deleteFilesSync({required String filePath}) {
    try {
      log('🗑️ Deleting file $filePath...');
      final file = fs.file(filePath);
      if (file.existsSync()) {
        file.deleteSync();
        log('✅ File deleted successfully: $filePath');
      }
    } catch (_) {
      throw Exception('⚠️ Failed to delete: $filePath');
    }
  }
}
