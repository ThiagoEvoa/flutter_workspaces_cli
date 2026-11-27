import 'package:file/file.dart';

/// Atomic path reservation used by the setup and add-package flows.
///
/// `package:file` 7.0.1 exposes no atomic exclusive-create for directories or
/// files: `Directory.createSync` is silent on an existing directory (both
/// backends) and `File.createSync(exclusive: true)` is dropped — the
/// parameter is deliberately ignored — so neither can be relied on to reject
/// an occupied path. No file lock is available through the abstraction either
/// (the memory backend throws `UnimplementedError`). The one creation
/// primitive through the abstraction that is atomic on both backends is
/// [Link.createSync]: it throws [FileSystemException] when the path is
/// occupied.
///
/// A [RunReservation] claims a path by creating a **sentinel link** in the
/// reserved path's parent directory (e.g. `.<folderName>.reserved` next to a
/// workspace dir, or the `.flutter_workspaces_cli.lock` path itself for the
/// workspace-wide lock). Creating the link is an atomic compare-and-set:
/// exactly one invocation wins, the others fail fast. The sentinel is a
/// dangling link (its target is a fixed arbitrary string) and is deleted on
/// release — on success, on rollback, and on every exit path — so a clean
/// run leaves no trace and a stale sentinel is a recoverable leftover (see
/// the README "Retries and stale locks" section).
class RunReservation {
  /// Sentinel link claimed by this instance.
  final Link sentinel;

  /// Human-readable label for the error when acquisition fails, e.g.
  /// "the workspace directory" or "the workspace lock".
  final String contextLabel;

  RunReservation._({required this.sentinel, required this.contextLabel});

  /// Acquires the atomic reservation at [sentinelPath].
  ///
  /// Parameters:
  /// - `fs`: the injected [FileSystem] used for the sentinel link.
  /// - `sentinelPath`: the full path of the sentinel link to create.
  /// - `contextLabel`: human-readable description of what is being claimed.
  ///
  /// Throws:
  /// - [Exception] with a message naming the occupied path and the recovery
  ///   steps when another invocation already holds the reservation.
  static RunReservation acquire({
    required FileSystem fs,
    required String sentinelPath,
    required String contextLabel,
  }) {
    final link = fs.link(sentinelPath);
    try {
      link.createSync('reserved');
    } catch (e) {
      throw Exception(
        '⚠️ $contextLabel is already reserved: another flutter_workspaces_cli '
        'run is in progress, or a previous run was interrupted and left a '
        'reservation sentinel behind at "$sentinelPath". If no other run is '
        'in progress, remove the sentinel file manually (see the README '
        '"Retries and stale locks" section) and retry. Details: $e',
      );
    }
    return RunReservation._(sentinel: link, contextLabel: contextLabel);
  }

  /// Releases the reservation by deleting the sentinel link.
  ///
  /// This is best-effort: a release failure is returned to the caller (not
  /// thrown) so the original failure can still be reported. A leftover
  /// sentinel is recovered manually per the README — the link is never
  /// re-created implicitly.
  ///
  /// Returns:
  /// - `null` when the sentinel was deleted (or was already gone); otherwise
  ///   the [Error] or [Exception] that prevented the deletion.
  Object? release() {
    try {
      if (sentinel.existsSync()) {
        sentinel.deleteSync();
      }
      return null;
    } catch (e) {
      return e;
    }
  }
}

/// A workspace directory reserved by a [WorkspaceProcess.createWorkspaceFolderSync]
/// invocation, together with the [RunReservation] sentinel that proved the claim.
///
/// The caller must release the reservation on success and on every rollback
/// path, and must use the directory for working-directory restore and scoped
/// cleanup.
class ReservedWorkspace {
  /// The absolute [Directory] reserved for this invocation.
  final Directory directory;

  /// The sentinel [RunReservation] guarding the workspace directory.
  final RunReservation reservation;

  ReservedWorkspace({required this.directory, required this.reservation});
}
