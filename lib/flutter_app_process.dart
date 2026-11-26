import 'package:file/file.dart';
import 'process_runner.dart';

/// Helpers to create and configure a Flutter application inside the workspace.
///
/// Provides synchronous operations to scaffold a Flutter app, update its
/// `main.dart`, write a workspace-aware `pubspec.yaml`, and create analysis
/// options for linting.
class FlutterAppProcess {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  FlutterAppProcess({required this.fs, required this.runner, this.log = print});

  /// Scaffolds a new Flutter app by running `flutter create <projectName>`.
  ///
  /// Parameters:
  /// - `projectName`: the folder/name of the Flutter application to create.
  ///
  /// Throws:
  /// - [SubprocessException] when the `flutter create` command exits with a
  ///   non-zero status (message includes the operation, exit status, and Flutter
  ///   output).
  /// - [Exception] when the `flutter` command cannot be started.
  void createFlutterAppSync({required String projectName}) {
    try {
      log('📱 Creating Flutter app...');
      final result = runner.runSync(
        'flutter',
        ['create', projectName],
        workingDirectory: fs.currentDirectory.path,
        runInShell: true,
      );
      checkProcessResult(
        result: result,
        operation: 'flutter create $projectName',
      );
      log('✅ Flutter app created: $projectName');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        'Failed to create Flutter app: flutter create $projectName could not be '
        'started (missing executable?): $e',
      );
    }
  }

  /// Writes a customized `lib/main.dart` that imports and uses the `core`
  /// package alongside the Material UI package.
  ///
  /// The generated app is a small, self-contained counter: `material_ui`
  /// provides the widgets (`MaterialApp`, `Scaffold`, `AppBar`, ...) and
  /// `core` is used to compute the counter increment via
  /// `Calculator().addOne(count)`.
  ///
  /// Parameters:
  /// - `projectName`: the application folder where `lib/main.dart` will be written.
  void updateFlutterAppWidgetSync({required String projectName}) {
    log('📝 Updating Flutter app main.dart...');
    final content = '''
import 'package:core/core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: const ColorScheme.dark()),
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
  final Calculator _calculator = Calculator();
  int _count = 0;

  void _incrementCounter() {
    setState(() {
      _count = _calculator.addOne(_count);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8.0),
          child: Column(
            mainAxisAlignment: .center,
            children: [
              const Text(
                'This is the flutter_workspaces_cli developed by ThiagoEvoa, if you enjoyed it, please consider giving it a star on GitHub!',
                textAlign: TextAlign.justify,
              ),
              const SizedBox(height: 16),
              Text('\$_count'),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
''';

    final file = fs.file('$projectName/lib/main.dart');
    file.writeAsStringSync(content);
    log('✅ Flutter app main.dart updated');
  }

  /// Writes the `test/widget_test.dart` that exercises the generated starter UI.
  ///
  /// The test pumps the real `MyApp`, asserts the counter starts at 0, taps the
  /// floating action button, and asserts the counter increments to 1.
  ///
  /// Parameters:
  /// - `projectName`: the application folder where `test/widget_test.dart` will
  ///   be written.
  void updateFlutterAppWidgetTestSync({required String projectName}) {
    log('📝 Updating Flutter app widget test...');
    final content =
        '''
// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:$projectName/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify that our counter starts at 0.
    expect(find.text('0'), findsOneWidget);

    // Tap the '+' icon and trigger a frame.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    // Verify that our counter has incremented.
    expect(find.text('1'), findsOneWidget);
  });
}
''';

    fs.directory('$projectName/test').createSync(recursive: true);
    final file = fs.file('$projectName/test/widget_test.dart');
    file.writeAsStringSync(content);
    log('✅ Flutter app widget test updated');
  }

  /// Writes a workspace-aware `pubspec.yaml` for the Flutter app.
  ///
  /// Parameters:
  /// - `dartVersion`: the bare Dart SDK version (e.g. `3.10.8`) reported by
  ///   the Flutter toolchain used by the CLI. The generated `environment.sdk`
  ///   constraint is serialized exactly once as `sdk: ^<dartVersion>`.
  /// - `projectName`: the application name used as the package name in pubspec.
  void updateFlutterAppPubspecSync({
    required String dartVersion,
    required String projectName,
  }) {
    log('📝 Updating Flutter app pubspec.yaml...');
    final content =
        '''
name: $projectName
description: "A new Flutter project."
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^$dartVersion

resolution: workspace

dependencies:
  flutter:
    sdk: flutter
  material_ui: ^1.1.0
  core:
    path: ../packages/core

dev_dependencies:
  flutter_test:
    sdk: flutter

flutter:
  uses-material-design: true
''';

    final file = fs.file('$projectName/pubspec.yaml');
    file.writeAsStringSync(content);
    log('✅ Flutter app pubspec.yaml updated');
  }

  /// Writes an `analysis_options.yaml` that enables Flutter lints.
  ///
  /// Parameters:
  /// - `projectName`: the application folder where the file will be written.
  void updateAnalysisOptionsFileSync({required String projectName}) {
    log('📝 Updating analysis options file...');
    final content = '''
# This file configures the analyzer, which statically analyzes Dart code to
# check for errors, warnings, and lints.
include: package:flutter_lints/flutter.yaml

analyzer:
  exclude:
    - build/**

linter:
  rules:
    package_names: false
''';

    final file = fs.file('$projectName/analysis_options.yaml');
    file.writeAsStringSync(content);
    log('✅ Analysis options file updated');
  }
}
