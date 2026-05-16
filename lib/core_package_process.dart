import 'package:file/file.dart';
import 'package_process.dart';
import 'process_runner.dart';

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
    _packageProcess.createPackageSync(packageName: 'core');
  }

  /// Writes `packages/core/pubspec.yaml` configured for workspace resolution.
  ///
  /// Parameters:
  /// - `dartVersion`: the Dart SDK constraint to use (e.g. `3.10.8`). The
  ///   generated file includes `sdk: ^$dartVersion` in the `environment`.
  void updateCorePubspecSync({required String dartVersion}) {
    _packageProcess.updatePubspecSync(
      packageName: 'core',
      dartVersion: dartVersion,
    );
  }
}
