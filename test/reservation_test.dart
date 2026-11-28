// Reservation primitive and failure-classification tests for Issue #37.
//
// These exercise the atomic claim and the two distinct acquisition failures
// (contention vs. permission/IO) at the source — the RunReservation /
// ReservationBackend layer — independently of the runners, so they run on
// every platform. The contended *runner* message is additionally covered by
// the real-fs suite (a stale sentinel), and the permission/IO *runner* message
// by a real-fs test that forces a genuine write failure.
import 'dart:io' as io;

import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:flutter_workspaces_cli/run_reservation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DartIoReservationBackend (real exclusive-file claim)', () {
    late io.Directory dir;
    final backend = DartIoReservationBackend();

    setUp(() {
      dir = io.Directory.systemTemp.createTempSync('fws_res_');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('claim creates the sentinel and isClaimed reflects it', () {
      final path = p.join(dir.path, '.a_workspaces.reserved');
      backend.claim(path);
      expect(backend.isClaimed(path), isTrue);
      expect(backend.release(path), isNull);
      expect(backend.isClaimed(path), isFalse);
    });

    test(
      'a pre-existing sentinel is a contended failure (not an IO error)',
      () {
        final path = p.join(dir.path, '.a_workspaces.reserved');
        io.File(path).writeAsStringSync('left by a prior interrupted run');
        final ex = expectThrows(
          () => RunReservation.acquire(
            fs: LocalFileSystem(),
            sentinelPath: path,
            contextLabel: 'the workspace directory',
            backend: backend,
          ),
        );
        expect(ex.failure, ReservationAcquisitionFailure.contended);
        expect(ex.sentinelPath, path);
      },
    );

    test('a write that cannot complete is a distinct IO/permission failure', () {
      // The parent directory does not exist, so the exclusive create fails with
      // a filesystem error rather than a "path already exists" error. The
      // classifier must label this ioError, not contended.
      final missingParent = p.join(dir.path, 'does-not-exist');
      final path = p.join(missingParent, '.a_workspaces.reserved');
      final ex = expectThrows(
        () => RunReservation.acquire(
          fs: LocalFileSystem(),
          sentinelPath: path,
          contextLabel: 'the workspace lock',
          backend: backend,
        ),
      );
      expect(ex.failure, ReservationAcquisitionFailure.ioError);
      expect(ex.sentinelPath, path);
      // A failed IO claim never leaves a sentinel behind.
      expect(backend.isClaimed(path), isFalse);
    });

    test('contended and ioError render distinct user-facing messages', () {
      final contended = ReservationAcquisitionException(
        failure: ReservationAcquisitionFailure.contended,
        sentinelPath: '/a/.a.reserved',
        contextLabel: 'the workspace directory',
        underlying: 'boom',
      ).toString();
      final ioFailure = ReservationAcquisitionException(
        failure: ReservationAcquisitionFailure.ioError,
        sentinelPath: '/a/.a.reserved',
        contextLabel: 'the workspace directory',
        underlying: 'boom',
      ).toString();

      expect(contended, contains('already reserved'));
      expect(contended, contains('remove that file manually'));
      expect(ioFailure, contains('permission or file-system error'));
      expect(ioFailure, isNot(contains('already reserved')));
      // The two messages are genuinely distinct.
      expect(contended, isNot(equals(ioFailure)));
    });
  });

  group('MemoryReservationBackend (test filesystem)', () {
    test('a second claim on the same path is contended; release clears it', () {
      final fs = MemoryFileSystem();
      final backend = MemoryReservationBackend(fs);
      final path = p.join('a', '.a.reserved');
      fs.directory('a').createSync();
      RunReservation.acquire(
        fs: fs,
        sentinelPath: path,
        contextLabel: 'the workspace directory',
        backend: backend,
      );
      expect(backend.isClaimed(path), isTrue);
      final ex = expectThrows(
        () => RunReservation.acquire(
          fs: fs,
          sentinelPath: path,
          contextLabel: 'the workspace directory',
          backend: backend,
        ),
      );
      expect(ex.failure, ReservationAcquisitionFailure.contended);
      expect(backend.release(path), isNull);
      expect(backend.isClaimed(path), isFalse);
    });
  });

  group('backendFor routing', () {
    test('a real (local) filesystem uses the dart:io backend', () {
      expect(backendFor(LocalFileSystem()), isA<DartIoReservationBackend>());
    });

    test('an in-memory filesystem uses the in-memory backend', () {
      expect(backendFor(MemoryFileSystem()), isA<MemoryReservationBackend>());
    });
  });
}

ReservationAcquisitionException expectThrows(void Function() body) {
  try {
    body();
  } on ReservationAcquisitionException catch (e) {
    return e;
  }
  // A non-wrapped failure means the classification path was not exercised.
  throw StateError('expected a ReservationAcquisitionException');
}
