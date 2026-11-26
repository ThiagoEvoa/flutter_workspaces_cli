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

  /// Removes the exact [reservedDirectory] reserved for this invocation when a
  /// setup is rolled back.
  ///
  /// The deletion is **scoped** to the single directory that
  /// [WorkspaceProcess.createWorkspaceFolderSync] reserved for this run: it
  /// never deletes by project name and never touches the invocation directory or
  /// any sibling. Deletion goes through the injected [FileSystem] (cross-platform)
  /// rather than a platform-specific `rm -rf` command, so rollback behaves the
  /// same on macOS, Linux, and Windows.
  ///
  /// Parameters:
  /// - `reservedDirectory`: the absolute [Directory] reserved for this run. This
  ///   is the *only* path that may be removed.
  ///
  /// Returns:
  /// - The cleanup error that occurred, or `null` when the directory was removed
  ///   successfully (or was already gone). The caller surfaces the returned error
  ///   *alongside* the original failure so that neither error hides the other.
  Object? revertAllProcesses({required Directory reservedDirectory}) {
    try {
      log(
        '🧹 Cleaning up reserved workspace folder: ${reservedDirectory.path}...',
      );
      if (reservedDirectory.existsSync()) {
        reservedDirectory.deleteSync(recursive: true);
        log('✅ Reserved workspace folder removed');
        return null;
      }
      log(
        'ℹ️ Reserved workspace folder no longer present; nothing to clean up',
      );
      return null;
    } catch (e) {
      // Do not hide the original failure: surface the cleanup error to the
      // caller instead of throwing, so both errors can be reported together.
      log('⚠️ Failed to clean up the reserved workspace folder: $e');
      return e;
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
