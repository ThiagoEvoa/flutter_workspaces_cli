import 'dart:io';

/// Helpers to create and configure a Flutter application inside the workspace.
///
/// Provides synchronous operations to scaffold a Flutter app, update its
/// `main.dart`, write a workspace-aware `pubspec.yaml`, and create analysis
/// options for linting.
abstract class FlutterAppProcess {
  /// Scaffolds a new Flutter app by running `flutter create <projectName>`.
  ///
  /// Parameters:
  /// - `projectName`: the folder/name of the Flutter application to create.
  ///
  /// Throws:
  /// - [Exception] when the `flutter create` command fails.
  static void createFlutterAppSync({required String projectName}) {
    try {
      print('📱 Creating Flutter app...');
      Process.runSync('flutter', ['create', projectName], runInShell: true);
      print('✅ Flutter app created: $projectName');
    } catch (_) {
      throw Exception('Failed to create Flutter app');
    }
  }

  /// Writes a customized `lib/main.dart` that imports the `core` package and
  /// provides a simple Material app scaffold.
  ///
  /// Parameters:
  /// - `projectName`: the application folder where `lib/main.dart` will be written.
  static void updateFlutterAppWidgetSync({required String projectName}) {
    print('📝 Updating Flutter app main.dart...');
    final content = '''import 'package:core/core.dart';
    import 'package:flutter/material.dart';

    void main() {
      runApp(const MyApp());
    }

    class MyApp extends StatelessWidget {
      const MyApp({super.key});

      @override
      Widget build(BuildContext context) {
        return MaterialApp(
          title: 'Flutter Demo',
          theme: ThemeData(colorScheme: .dark()),
          home: const MyHomePage(title: 'Flutter Workspaces CLI'),
        );
      }
    }

    class MyHomePage extends StatefulWidget {
      const MyHomePage({super.key, required this.title});

      final String title;

      @override
      State<MyHomePage> createState() => _MyHomePageState();
    }

    class _MyHomePageState extends State<MyHomePage> {
      @override
      Widget build(BuildContext context) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            title: Text(widget.title),
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: const Text(
                'This is the flutter_workspaces_cli developed by ThiagoEvoa, if you enjoyed it, please consider giving it a star on GitHub!',
                textAlign: .justify,
              ),
            ),
          ),
        );
      }
    }
    ''';

    final file = File('$projectName/lib/main.dart');
    file.writeAsStringSync(content);
    print('✅ Flutter app main.dart updated');
  }

  /// Writes a workspace-aware `pubspec.yaml` for the Flutter app.
  ///
  /// Parameters:
  /// - `dartVersion`: the Dart SDK constraint (e.g. `3.10.8`).
  /// - `projectName`: the application name used as the package name in pubspec.
  static void updateFlutterAppPubspecSync({
    required String dartVersion,
    required String projectName,
  }) {
    print('📝 Updating Flutter app pubspec.yaml...');
    final content =
        '''name: $projectName
        description: "A new Flutter project."
        publish_to: 'none'
        version: 1.0.0+1

        environment:
          sdk: ^$dartVersion

        resolution: workspace

        dependencies:
          flutter:
            sdk: flutter

        dev_dependencies:
          flutter_test:
            sdk: flutter

        flutter:
          uses-material-design: true
        ''';

    final file = File('$projectName/pubspec.yaml');
    file.writeAsStringSync(content);
    print('✅ Flutter app pubspec.yaml updated');
  }

  /// Writes an `analysis_options.yaml` that enables Flutter lints and plugin support.
  ///
  /// Parameters:
  /// - `projectName`: the application folder where the file will be written.
  static void updateAnalysisOptionsFileSync({required String projectName}) {
    print('📝 Updating analysis options file...');
    final content =
        '''# This file configures the analyzer, which statically analyzes Dart code to
    # check for errors, warnings, and lints.
    include: package:flutter_lints/flutter.yaml

    analyzer:
      plugins:
        - custom_lint

    linter:
      rules:
        package_names: false
        depend_on_referenced_packages: false
    ''';

    final file = File('$projectName/analysis_options.yaml');
    file.writeAsStringSync(content);
    print('✅ Analysis options file updated');
  }
}
