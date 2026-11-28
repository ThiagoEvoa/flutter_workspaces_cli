import 'package:file/file.dart';
import 'package_process.dart';
import 'process_runner.dart';

/// The name of the built-in shared package that `setup` always generates under
/// `packages/`.
///
/// This is the single source of truth for that package name: both the scaffolding
/// ([CorePackageProcess.createCorePackageSync] / [CorePackageProcess.updateCorePubspecSync])
/// and the setup-time name validation (which rejects a workspace app named after
/// it, since Flutter cannot resolve two workspace members with the same name) read
/// this constant rather than each hard-coding the literal, so the two stay in sync.
const String kCorePackageName = 'core';

/// Helpers to create and configure the shared `core` package inside `packages/`.
///
/// Contains synchronous helpers that scaffold a package and write a
/// workspace-oriented `pubspec.yaml` for the core package.
class CorePackageProcess {
  final PackageProcess _packageProcess;

  CorePackageProcess({
    required FileSystem fs,
    required ProcessRunner runner,
    void Function(String) log = print,
  }) : _packageProcess = PackageProcess(fs: fs, runner: runner, log: log);

  /// Creates `packages/core` by running the Flutter package template.
  ///
  /// Runs `flutter create --template=package core` with `workingDirectory`
  /// set to `packages`. The `packages` directory must exist before calling
  /// this method.
  ///
  /// Throws:
  /// - [Exception] when the creation command fails.
  void createCorePackageSync() {
    _packageProcess.createPackageSync(packageName: kCorePackageName);
  }

  /// Writes `packages/core/pubspec.yaml` configured for workspace resolution.
  ///
  /// Parameters:
  /// - `dartVersion`: the bare Dart SDK version (e.g. `3.10.8`) reported by
  ///   the Flutter toolchain used by the CLI. The generated file includes
  ///   `sdk: ^<dartVersion>` in the `environment`.
  void updateCorePubspecSync({required String dartVersion}) {
    _packageProcess.updatePubspecSync(
      packageName: kCorePackageName,
      dartVersion: dartVersion,
    );
  }
}
