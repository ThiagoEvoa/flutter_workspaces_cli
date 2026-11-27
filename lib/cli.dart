import 'package:file/file.dart';

import 'add_package_runner.dart';
import 'common_process.dart';
import 'process_runner.dart';
import 'project_name_process.dart';
import 'setup_runner.dart';

/// Top-level CLI dispatcher and exit-code routing.
///
/// Grammar (see [Cli.run]):
/// - Default command `setup`: `flutter_workspaces_cli [setup] --name <name>`
/// - `add-package` command: `flutter_workspaces_cli add-package --name <name>`
/// - Global help: `--help`, `-h` (optionally after the default/`setup` token),
///   bare `help`, `help setup`, and `help <help-token>` — usage to stdout,
///   exit 0.
/// - Add-package help: `add-package --help`, `add-package -h`,
///   `add-package help`, `help add-package` — usage to stdout, exit 0.
/// - Usage errors (missing/invalid `--name`, unknown flags, stray arguments,
///   missing option values): error message + contextual usage to stderr,
///   exit 64.
/// - Execution errors (runner failure): error to stderr, exit 1.
///
/// Help paths never create files, start Flutter commands, or invoke a runner.
class Cli {
  /// The global help text printed for `--help`, `-h`, bare `help`, and
  /// `help setup`.
  static const String _globalHelpText = '''
Usage: flutter_workspaces_cli [setup] --name <name>
       flutter_workspaces_cli add-package --name <name>

Commands:
  setup         Create a new workspace (default command)
  add-package   Add a new package to an existing workspace

Global options:
  -h, --help    Show this help message and exit
''';

  static const String _globalOptionsLine = '''
Global options:
  -h, --help    Show this help message and exit
''';

  final FileSystem fs;
  final ProcessRunner runner;

  /// Output sink for normal (stdout) messages.
  final void Function(String) log;

  /// Output sink for error messages and usage text for usage errors
  /// (stderr in normal use). Defaults to [log] for backwards compatibility.
  final void Function(String) errorLog;

  Cli({
    required this.fs,
    required this.runner,
    this.log = print,
    void Function(String)? errorLog,
  }) : errorLog = errorLog ?? log;

  /// Runs the CLI and returns the process exit code (0 success/help, 1
  /// execution error, 64 usage error).
  int run(List<String> arguments) {
    const helpTokens = {'--help', '-h', 'help'};

    // The `help` command is handled before command classification so that
    // bare `help` and `help <global-command>` work regardless of placement.
    if (arguments.isNotEmpty && arguments.first == 'help') {
      final remainder = arguments.sublist(1);
      if (_isGlobalHelpTarget(remainder, helpTokens)) {
        log(_globalHelpText);
        return 0;
      }
      if (remainder.length == 1 && remainder.first == 'add-package') {
        log(
          _commandHelpText(
            kAddPackageUsageLine,
            'The name of the package. eg: "my_feature"',
          ),
        );
        return 0;
      }
      errorLog('Unknown command "${remainder.join(' ')}".');
      errorLog(_globalHelpText);
      return 64;
    }

    // Command classification. A bare `setup` token selects the explicit
    // setup command; `add-package` selects that command; anything else is
    // the default setup command, whose stray positional tokens are rejected
    // by the runner with the setup usage (exit 64).
    var command = 'setup';
    var rest = arguments;
    if (arguments.isNotEmpty && arguments.first == 'setup') {
      command = 'setup';
      rest = arguments.sublist(1);
    } else if (arguments.isNotEmpty && arguments.first == 'add-package') {
      command = 'add-package';
      rest = arguments.sublist(1);
    }

    // An explicit help request anywhere in the command wins and is answered
    // with the matching usage text on stdout. The scan is positional-aware:
    // the value token immediately following `--name`/`-n` is the option's
    // value, never a help token — a valid name such as "help" must reach the
    // runner rather than being swallowed by the help path. (Embedded forms
    // such as `--name=value` and `-n<value>` need no special case: the token
    // is not exactly a help token and cannot false-match.)
    var helpRequested = false;
    for (var i = 0; i < rest.length; i++) {
      final token = rest[i];
      if (token == '--name' || token == '-n') {
        i++; // Skip the token in the option-value position.
        continue;
      }
      if (helpTokens.contains(token)) {
        helpRequested = true;
        break;
      }
    }
    if (helpRequested) {
      if (command == 'add-package') {
        log(
          _commandHelpText(
            kAddPackageUsageLine,
            'The name of the package. eg: "my_feature"',
          ),
        );
      } else {
        log(_globalHelpText);
      }
      return 0;
    }

    try {
      if (command == 'add-package') {
        AddPackageRunner(
          fs: fs,
          runner: runner,
          log: log,
          errorLog: errorLog,
        ).run(rest);
      } else {
        SetupRunner(
          fs: fs,
          runner: runner,
          log: log,
          errorLog: errorLog,
        ).run(rest);
      }
      return 0;
    } on ExitException catch (e) {
      return e.code;
    } catch (e) {
      errorLog('Unexpected error: $e');
      return 1;
    }
  }

  /// Whether [remainder] is a help request that maps to the global usage
  /// text: bare `help`, `help setup`, `help --help`, `help -h`, `help help`.
  static bool _isGlobalHelpTarget(
    List<String> remainder,
    Set<String> helpTokens,
  ) {
    if (remainder.isEmpty) return true;
    if (remainder.first == 'setup') {
      if (remainder.length == 1) return true;
      return remainder.length == 2 && helpTokens.contains(remainder[1]);
    }
    return remainder.length == 1 && helpTokens.contains(remainder.first);
  }

  /// Builds the per-command help text: the canonical usage line followed by
  /// the shared `--name` option table and the global options line.
  static String _commandHelpText(String usageLine, String helpText) {
    final parser = buildNameParser(helpText: helpText);
    return '\n$usageLine\n\nOptions:\n${parser.usage}\n$_globalOptionsLine';
  }
}
