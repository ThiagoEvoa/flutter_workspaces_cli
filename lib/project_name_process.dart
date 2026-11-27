import 'package:args/args.dart';

/// Canonical Dart package naming rule shared by every command path.
///
/// Rule set (verified against the official Dart pub documentation at
/// https://dart.dev/tools/pub/pubspec.md ("Name" section), which requires an
/// all-lowercase name of `[a-z0-9_]` that is a valid Dart identifier — not a
/// leading digit, not a reserved word — and against the bundled pub
/// implementation's `NameValidator` (non-empty, only letters/digits/underscores
/// with letter-or-underscore start, not a reserved word, lowercase emitted as a
/// warning):
///
/// - starts with a lowercase letter (`[a-z]`)
/// - contains only lowercase letters, digits, and underscores (`[a-z0-9_]`)
/// - at most 64 characters (a length guard added by the issue design; neither
///   the official docs nor the bundled pub validator states one)
///
/// The official identifier rules (must not start with a digit, must not be a
/// reserved word) are satisfied by the stricter rules above, except reserved
/// words that match `^[a-z][a-z0-9_]*$` exactly (e.g. `class`, `int`): those are
/// not excluded here, because the issue design does not exercise that axis, so
/// the helper enforces exactly the three rules listed above.
///
/// Throws:
/// - [ArgumentError] with a contextual message naming the failing rule.
void validateProjectName(String name) {
  if (!RegExp(r'^[a-z]').hasMatch(name)) {
    throw ArgumentError(
      'Invalid project name "$name": must start with a lowercase letter.',
    );
  }
  if (!RegExp(r'^[a-z0-9_]*$').hasMatch(name)) {
    throw ArgumentError(
      'Invalid project name "$name": may only contain lowercase letters, digits, and underscores (a-z, 0-9, _).',
    );
  }
  if (name.length > 64) {
    throw ArgumentError(
      'Invalid project name "$name": names may be at most 64 characters long (${name.length} given).',
    );
  }
}

/// Builds the `-n/--name` option table shared by the runners and the CLI
/// dispatcher's help/usage paths.
ArgParser buildNameParser({
  String helpText = 'The name of the project. eg: "my_app"',
}) => ArgParser()..addOption('name', abbr: 'n', help: helpText);

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
  /// - [ArgumentError] when the `--name` option is missing or empty, when the
  ///   name violates the naming rule ([validateProjectName]), when the parser
  ///   rejects the arguments (unknown flags, missing option values), or when
  ///   unexpected positional arguments are present. All of these are usage
  ///   errors that the caller reports as exit code 64.
  String getProjectName({required List<String> arguments}) {
    log('📝 Getting project name...');
    final parser = buildNameParser();

    final ArgResults argResults;
    try {
      argResults = parser.parse(arguments);
    } catch (e) {
      // A parse failure is a usage error (unknown flag, missing option value,
      // etc.), surfaced to the caller as an ArgumentError so it can be routed
      // to exit code 64 with the contextual usage.
      if (e is ArgumentError) rethrow;
      throw ArgumentError(e is FormatException ? e.message : '$e');
    }

    // Reject stray positional arguments (e.g. an unknown top-level command).
    if (argResults.rest.isNotEmpty) {
      throw ArgumentError(
        'Unexpected argument(s): ${argResults.rest.join(', ')}.',
      );
    }

    final name = argResults['name'] as String?;

    if (name == null || name.isEmpty) {
      throw ArgumentError('The --name parameter is required.');
    }
    validateProjectName(name);
    log('✅ Project name: $name');
    return name;
  }
}
