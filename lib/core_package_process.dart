import 'dart:io';

/// Helpers to create and configure the shared `core` package inside `packages/`.
///
/// Contains synchronous helpers that scaffold a package and write a
/// workspace-oriented `pubspec.yaml` for the core package.
abstract class CorePackageProcess {
  /// Creates `packages/core` by running the Flutter package template.
  ///
  /// Runs `flutter create --template=package core` with `workingDirectory`
  /// set to `packages`. The `packages` directory must exist before calling
  /// this method.
  ///
  /// Throws:
  /// - [Exception] when the creation command fails.
  static void createCorePackageSync() {
    try {
      print('📦 Creating core package...');
      Process.runSync(
        'flutter',
        ['create', '--template=package', 'core'],
        workingDirectory: 'packages',
        runInShell: true,
      );
      print('✅ Core package created');
    } catch (_) {
      throw Exception('⚠️ Failed to create core package');
    }
  }

  /// Writes `packages/core/pubspec.yaml` configured for workspace resolution.
  ///
  /// Parameters:
  /// - `dartVersion`: the Dart SDK constraint to use (e.g. `3.10.8`). The
  ///   generated file includes `sdk: ^$dartVersion` in the `environment`.
  static void updateCorePubspecSync({required String dartVersion}) {
    print('📝 Updating core pubspec.yaml...');
    final content =
        '''
name: core
description: "A new Flutter package project."
version: 0.0.1

environment:
  sdk: ^$dartVersion
  flutter: ">=1.17.0"

resolution: workspace
''';

    final file = File('packages/core/pubspec.yaml');
    file.writeAsStringSync(content);
    print('✅ Core pubspec.yaml updated');
  }
}
