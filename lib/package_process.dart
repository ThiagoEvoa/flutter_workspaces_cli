import 'package:file/file.dart';
import 'process_runner.dart';

/// Helpers to create and configure a new package inside `packages/`.
class PackageProcess {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  PackageProcess({
    required this.fs,
    required this.runner,
    this.log = print,
  });

  /// Creates a package in `packages/` by running the Flutter package template.
  void createPackageSync({required String packageName}) {
    try {
      log('📦 Creating $packageName package...');
      runner.runSync(
        'flutter',
        ['create', '--template=package', packageName],
        workingDirectory: 'packages',
        runInShell: true,
      );
      log('✅ $packageName package created');
    } catch (_) {
      throw Exception('⚠️ Failed to create $packageName package');
    }
  }

  /// Writes `packages/[packageName]/pubspec.yaml` configured for workspace resolution.
  void updatePubspecSync({
    required String packageName,
    required String dartVersion,
  }) {
    log('📝 Updating $packageName pubspec.yaml...');
    final content = '''
name: $packageName
description: "A new Flutter package project."
version: 0.0.1

environment:
  sdk: ^$dartVersion
  flutter: ">=1.17.0"

resolution: workspace
''';

    final file = fs.file('packages/$packageName/pubspec.yaml');
    file.writeAsStringSync(content);
    log('✅ $packageName pubspec.yaml updated');
  }
}
