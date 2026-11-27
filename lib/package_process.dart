import 'package:file/file.dart';
import 'dart_process.dart';
import 'process_runner.dart';

/// Helpers to create and configure a new package inside `packages/`.
class PackageProcess {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  PackageProcess({required this.fs, required this.runner, this.log = print});

  /// Creates a package in `packages/` by running the Flutter package template.
  ///
  /// Throws:
  /// - [SubprocessException] when the `flutter create` command exits with a
  ///   non-zero status (message includes the operation, exit status, and
  ///   Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void createPackageSync({required String packageName}) {
    try {
      log('📦 Creating $packageName package...');
      final result = runner.runSync(
        'flutter',
        ['create', '--template=package', packageName],
        workingDirectory: 'packages',
        runInShell: true,
      );
      checkProcessResult(
        result: result,
        operation: 'flutter create --template=package $packageName',
      );
      log('✅ $packageName package created');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to create $packageName package: '
        'flutter create --template=package $packageName could not be started '
        '(missing executable?): $e',
      );
    }
  }

  /// Writes `packages/[packageName]/pubspec.yaml` configured for workspace resolution.
  ///
  /// Parameters:
  /// - `dartVersion`: the bare Dart SDK version (e.g. `3.10.8`) reported by
  ///   the Flutter toolchain used by the CLI. The generated `environment.sdk`
  ///   constraint is serialized exactly once as `sdk: ^<dartVersion>`.
  void updatePubspecSync({
    required String packageName,
    required String dartVersion,
  }) {
    log('📝 Updating $packageName pubspec.yaml...');
    final content =
        '''
name: $packageName
description: "A new Flutter package project."
version: 0.0.1
homepage:

environment:
  sdk: ^$dartVersion
  flutter: ">=${DartProcess.supportedMinimumFlutterVersion}"

resolution: workspace

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
''';

    final file = fs.file('packages/$packageName/pubspec.yaml');
    file.writeAsStringSync(content);
    log('✅ $packageName pubspec.yaml updated');
  }
}
