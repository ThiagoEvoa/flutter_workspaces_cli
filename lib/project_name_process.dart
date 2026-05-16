import 'package:args/args.dart';

/// Helpers for extracting and validating the `--name` CLI argument.
///
/// The CLI expects a required `--name` (`-n`) option that specifies the
/// project/workspace base name used throughout the scaffolding process.
class ProjectNameProcess {
  final void Function(String) log;

  ProjectNameProcess({this.log = print});

  /// Parses [arguments] for the required `--name` option and returns it.
  ///
  /// Parameters:
  /// - `arguments`: the command-line arguments passed to `main`.
  ///
  /// Returns:
  /// - [String]: the non-empty project name.
  ///
  /// Throws:
  /// - [ArgumentError] when the `--name` option is missing or empty.
  String getProjectName({required List<String> arguments}) {
    log('📝 Getting project name...');
    final parser = ArgParser()
      ..addOption(
        'name',
        abbr: 'n',
        help: 'The name of the project. eg: "my_app"',
      );

    final argResults = parser.parse(arguments);
    final name = argResults['name'] as String?;

    if (name == null || name.isEmpty) {
      throw ArgumentError('The --name parameter is required.');
    }
    log('✅ Project name: $name');
    return name;
  }
}
