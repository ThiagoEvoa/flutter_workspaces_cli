import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';

/// The kind of a failed [ReservationBackend.claim].
///
/// Used to give callers *distinct* diagnostics: a path that is already claimed
/// (contention, or a stale leftover from an interrupted run) is reported very
/// differently from a genuine permission or file-system error that prevented
/// the sentinel from being created at all.
enum ReservationAcquisitionFailure {
  /// The path is already occupied by another run (or a stale reservation left
  /// behind by an interrupted run). The recovery is to remove the file, only
  /// when no other run is actually in progress.
  contended,

  /// The sentinel could not be created for a reason other than contention — a
  /// permission or file-system error. A standard, non-elevated account should
  /// be able to create the ordinary file the sentinel is, so this is a real
  /// failure, not a lock collision.
  ioError,
}

/// Thrown by [RunReservation.acquire] when the atomic claim fails.
///
/// It carries the [failure] kind, the affected [sentinelPath], the human
/// [contextLabel], and the [underlying] error so the affected path is always
/// named and the original error is never lost. Its [toString] renders the
/// distinct user-facing message for the two cases.
class ReservationAcquisitionException implements Exception {
  ReservationAcquisitionException({
    required this.failure,
    required this.sentinelPath,
    required this.contextLabel,
    required this.underlying,
  });

  /// Which kind of failure this was — [ReservationAcquisitionFailure].
  final ReservationAcquisitionFailure failure;

  /// The path of the sentinel that could not be claimed.
  final String sentinelPath;

  /// Human-readable label for what is being claimed (e.g. "the workspace lock").
  final String contextLabel;

  /// The original error the claim primitive threw; retained, never swallowed.
  final Object underlying;

  @override
  String toString() {
    final quotedPath = '"$sentinelPath"';
    if (failure == ReservationAcquisitionFailure.contended) {
      return '⚠️ $contextLabel is already reserved: another '
          'flutter_workspaces_cli run is in progress, or a previous run was '
          'interrupted and left a reservation behind at $quotedPath. If no '
          'other run is in progress, remove that file manually (see the README '
          '"Retries and stale locks" section) and retry. Details: $underlying';
    }
    return '⚠️ $contextLabel could not be reserved: a permission or '
        'file-system error prevented creating the reservation at $quotedPath. '
        'A standard, non-elevated account should be able to create this '
        'ordinary file — verify the path is writable and retry. '
        'Details: $underlying';
  }
}

/// The atomic sentinel primitive the reservation is built on.
///
/// A [RunReservation] claims a path by having its [ReservationBackend] create a
/// sentinel there atomically (a compare-and-set: exactly one invocation wins,
/// the others fail fast) and releases it by deleting the sentinel. The backend
/// is what carries the cross-platform semantics; the reservation is
/// primitive-agnostic.
abstract class ReservationBackend {
  /// Atomically creates the sentinel at [sentinelPath].
  ///
  /// Throws when the path is already occupied by another run (contention) or
  /// when a permission/file-system error prevents the creation. The thrown
  /// value is the underlying error; [RunReservation.acquire] classifies it.
  void claim(String sentinelPath);

  /// Deletes a previously claimed sentinel at [sentinelPath].
  ///
  /// Best-effort: returns `null` when the sentinel was deleted (or was already
  /// gone), or the [Error]/[Exception] that prevented the deletion. The caller
  /// surfaces the original error and never lets a release failure hide it.
  Object? release(String sentinelPath);

  /// Whether a sentinel currently exists at [sentinelPath].
  ///
  /// Used to *classify* a claim failure — a path that exists after a failed
  /// claim is contention; one that does not is a genuine permission/IO error.
  /// This is a post-failure diagnostic check, not the atomic claim itself.
  bool isClaimed(String sentinelPath);
}

/// The production backend: an atomic exclusive **file** creation via `dart:io`.
///
/// `File.createSync(path, exclusive: true)` is atomic on every platform — it
/// maps to `open(O_CREAT | O_EXCL | O_WRONLY)` on POSIX and `CreateFile` with
/// the `CREATE_NEW` flag on Windows — and it creates an **ordinary file**, so
/// it needs neither an elevated token nor Windows Developer Mode. This is what
/// lets a standard Windows account run the CLI: the previous implementation used
/// a sentinel *symlink* (`Link.createSync`), whose creation requires that
/// privilege on Windows and so failed for an ordinary user.
///
/// `package:file` cannot provide this: on 7.x its `File.createSync` deliberately
/// drops the `exclusive` parameter on every backend (a `LocalFile`/
/// `ForwardingFile`/`MemoryFile` no-op — see dartbug.com/49647), so the atomic
/// create is done through `dart:io` directly, on the resolved path.
class DartIoReservationBackend implements ReservationBackend {
  const DartIoReservationBackend();

  @override
  void claim(String sentinelPath) {
    // Always uses the real OS via `dart:io` and takes no [FileSystem] at all:
    // this backend is only ever selected for a real `LocalFileSystem` (see
    // `backendFor`), and [sentinelPath] is already an absolute OS path
    // (derived from `fs.currentDirectory.path`), so there is no base-rooted or
    // forwarded filesystem to honor. The latent coupling a reviewer flagged is
    // therefore inert today: it would matter only if a base-rooted/forwarded
    // `LocalFileSystem` were ever routed to this backend, which the current
    // selection never does. It is documented here so that coupling is a
    // deliberate, visible choice rather than a latent surprise.
    io.File(sentinelPath).createSync(exclusive: true);
  }

  @override
  Object? release(String sentinelPath) {
    try {
      final file = io.File(sentinelPath);
      if (file.existsSync()) {
        file.deleteSync();
      }
      return null;
    } catch (e) {
      return e;
    }
  }

  @override
  bool isClaimed(String sentinelPath) => io.File(sentinelPath).existsSync();
}

/// The in-memory backend, used only by the unit-test suite.
///
/// `package:file`'s `MemoryFileSystem` provides no atomic exclusive *file*
/// create, but its [Link.createSync] *is* atomic (it throws when the path is
/// already occupied), so the in-memory sentinel stays a link. This keeps the
/// large mocked suite deterministic; the real `LocalFileSystem` path uses
/// [DartIoReservationBackend] instead, which is what the real-filesystem tests
/// exercise and what proves the Windows-safe primitive.
class MemoryReservationBackend implements ReservationBackend {
  MemoryReservationBackend(this._fs);

  final FileSystem _fs;

  @override
  void claim(String sentinelPath) {
    _fs.link(sentinelPath).createSync('reserved');
  }

  @override
  Object? release(String sentinelPath) {
    try {
      final link = _fs.link(sentinelPath);
      if (link.existsSync()) {
        link.deleteSync();
      }
      return null;
    } catch (e) {
      return e;
    }
  }

  @override
  bool isClaimed(String sentinelPath) => _fs.link(sentinelPath).existsSync();
}

/// Selects the [ReservationBackend] for a [FileSystem].
///
/// A real [LocalFileSystem] gets [DartIoReservationBackend] (the atomic,
/// privilege-free exclusive file create). Anything else — the in-memory
/// filesystems used by the tests — gets [MemoryReservationBackend]. This is the
/// only place the two primitives are chosen; the rest of the reservation is
/// backend-agnostic.
ReservationBackend backendFor(FileSystem fs) => fs is LocalFileSystem
    ? const DartIoReservationBackend()
    : MemoryReservationBackend(fs);

/// An atomic path reservation used by the setup and add-package flows.
///
/// A [RunReservation] claims a path by creating a **sentinel** in the reserved
/// path's parent (e.g. `.<folderName>.reserved` next to a workspace dir, or the
/// `.flutter_workspaces_cli.lock` path itself for the workspace-wide lock). The
/// sentinel is a compare-and-set: exactly one invocation wins, the others fail
/// fast. On a real filesystem the sentinel is an ordinary file created
/// atomically with an exclusive create ([DartIoReservationBackend]); on the
/// in-memory test filesystem it is a link ([MemoryReservationBackend]).
///
/// The sentinel is deleted on release — on success, on rollback, and on every
/// exit path — so a clean run leaves no trace and a stale sentinel is a
/// recoverable leftover (see the README "Retries and stale locks" section).
class RunReservation {
  /// The path of the sentinel claimed by this instance.
  final String sentinelPath;

  /// Human-readable label for the error when acquisition fails, e.g.
  /// "the workspace directory" or "the workspace lock".
  final String contextLabel;

  /// The backend that performs the atomic claim and release.
  final ReservationBackend backend;

  RunReservation._({
    required this.sentinelPath,
    required this.contextLabel,
    required this.backend,
  });

  /// Acquires the atomic reservation at [sentinelPath].
  ///
  /// Parameters:
  /// - `fs`: the injected [FileSystem]; selects the [ReservationBackend] when
  ///   [backend] is not supplied ([backendFor]).
  /// - `sentinelPath`: the full path of the sentinel to create.
  /// - `contextLabel`: human-readable description of what is being claimed.
  /// - `backend`: the [ReservationBackend] to use; defaults to [backendFor] for
  ///   `fs`.
  ///
  /// Throws:
  /// - [ReservationAcquisitionException] when the claim fails. Its [failure]
  ///   distinguishes contention (the path is occupied — report the recovery
  ///   steps) from a permission/IO error (report it as such); both name the
  ///   affected [sentinelPath] and retain the underlying error.
  static RunReservation acquire({
    required FileSystem fs,
    required String sentinelPath,
    required String contextLabel,
    ReservationBackend? backend,
  }) {
    final effectiveBackend = backend ?? backendFor(fs);
    try {
      effectiveBackend.claim(sentinelPath);
    } catch (e) {
      // Classify the failure *after* the atomic attempt: a path that now
      // exists was occupied by another run (contention or a stale leftover);
      // a path that does not exist means the create itself failed for a
      // permission/IO reason. The existence check is best-effort — if it
      // cannot be determined, treat it as a genuine failure rather than a
      // collision.
      //
      // Known diagnostic-only edge: the classification is a single, point-in-
      // time existence probe run *after* the failed create. If a contending
      // run releases (deletes) its sentinel in the tiny window between this
      // loser's failed create and this probe, the probe sees "not claimed"
      // and the loser is labeled [ReservationAcquisitionFailure.ioError]
      // instead of [ReservationAcquisitionFailure.contended]. That
      // misclassification is harmless: the loser still throws and refuses
      // identically (one owner is preserved either way) — only the *wording*
      // of the diagnostic differs. The window is practically nil because the
      // winner holds the sentinel for the entire slow operation (scaffold /
      // dependency resolution), so it will not have finished and released by
      // the time the loser's microsecond-later probe runs. Closing it would
      // require a fundamentally different primitive (e.g. a re-check coupled
      // to the release), so it is documented rather than "fixed"; it never
      // changes the refusal outcome.
      final occupied = _tryIsClaimed(effectiveBackend, sentinelPath);
      throw ReservationAcquisitionException(
        failure: occupied
            ? ReservationAcquisitionFailure.contended
            : ReservationAcquisitionFailure.ioError,
        sentinelPath: sentinelPath,
        contextLabel: contextLabel,
        underlying: e,
      );
    }
    return RunReservation._(
      sentinelPath: sentinelPath,
      contextLabel: contextLabel,
      backend: effectiveBackend,
    );
  }

  /// Releases the reservation by deleting the sentinel.
  ///
  /// This is best-effort: a release failure is returned to the caller (not
  /// thrown) so the original failure can still be reported. A leftover
  /// sentinel is recovered manually per the README — the sentinel is never
  /// re-created implicitly.
  ///
  /// Returns:
  /// - `null` when the sentinel was deleted (or was already gone); otherwise
  ///   the [Error] or [Exception] that prevented the deletion.
  Object? release() => backend.release(sentinelPath);

  static bool _tryIsClaimed(ReservationBackend backend, String sentinelPath) {
    try {
      return backend.isClaimed(sentinelPath);
    } catch (_) {
      // A failure to even check existence is itself a sign of a genuine
      // problem, not a collision: fall back to the permission/IO diagnostic.
      return false;
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
