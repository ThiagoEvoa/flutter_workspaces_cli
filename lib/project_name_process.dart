import 'package:args/args.dart';

/// Reserved Dart words rejected by Flutter's package-name validation.
///
/// This set is exactly the `_keywords` list in the Flutter tool's
/// `create_base.dart` (`isValidPackageName`), which is what
/// `flutter create --template=package` enforces before creating the package.
/// The rule set is deliberately identical to Flutter's — not pub's own
/// reserved-words list — because this CLI creates new packages through
/// `flutter create`, so the CLI must never accept a name the scaffolding it
/// invokes would reject. Because the validator already requires an all-lowercase
/// `[a-z0-9_]` name, the check is a direct lowercase-set lookup.
///
/// Source of truth (verified against the locally installed Flutter 3.50.1):
/// `<flutter>/packages/flutter_tools/lib/src/commands/create_base.dart`
/// (`const _keywords = <String>{...}` and the `[a-z_][a-z0-9_]*` identifier
/// regex). Flutter also rejects the dependency-conflicting package names
/// `collection`, `flutter`, `flutter_test`, and `meta`, but that is a separate
/// rule from the reserved-word axis covered by this issue and is not enforced
/// here.
///
/// Note on scope: `int` is NOT a reserved word — it is a built-in type, and
/// Flutter's validation does not reject it, so `int` is intentionally allowed.
const kReservedDartWords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'inout',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'native',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'out',
  'part',
  'patch',
  'required',
  'rethrow',
  'return',
  'set',
  'show',
  'source',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

/// Canonical Dart package naming rule shared by every command path.
///
/// Rule set (verified against the official Dart pub documentation at
/// https://dart.dev/tools/pub/pubspec.md ("Name" section), which requires an
/// all-lowercase name of `[a-z0-9_]` that is a valid Dart identifier — not a
/// leading digit, not a reserved word — and against the bundled Flutter tool's
/// package-name validation in `create_base.dart` (`isValidPackageName`), which
/// requires the name to match `[a-z_][a-z0-9_]*` and not be a reserved word):
///
/// - starts with a lowercase letter (`[a-z]`)
/// - contains only lowercase letters, digits, and underscores (`[a-z0-9_]`)
/// - is not a reserved Dart word ([kReservedDartWords])
/// - at most 64 characters (a length guard added by the issue design; neither
///   the official docs nor Flutter's validation states one)
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
  if (kReservedDartWords.contains(name)) {
    throw ArgumentError(
      'Invalid project name "$name": must not be a reserved Dart word.',
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
