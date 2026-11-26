import 'dart:convert';

import 'process_runner.dart';

/// Utilities for querying and validating the Dart SDK version bundled with
/// the Flutter toolchain used by the CLI.
///
/// The CLI scaffolds and resolves workspaces with `flutter`, so the Dart SDK
/// version that matters is the one bundled with the `flutter` executable it
/// invokes — not a `dart` binary on the PATH. [DartProcess] reads that version
/// once (preferring machine-readable Flutter output) and passes the bare
/// semantic version to the manifest generators, so everything the CLI writes
/// is consistent with the toolchain that will resolve the manifests.
class DartProcess {
  final ProcessRunner runner;
  final void Function(String) log;

  DartProcess({required this.runner, this.log = print});

  /// Minimum Dart SDK version bundled with the Flutter toolchain that this
  /// CLI supports.
  static const String supportedMinimumVersion = '3.6.0';

  /// Returns the bare semantic Dart version string (e.g. `3.10.8`) bundled
  /// with the Flutter toolchain used by the CLI.
  ///
  /// Prefers the machine-readable output of `flutter --version --machine`
  /// (field `dartSdkVersion`, the field real Flutter emits; tolerates
  /// `dart_version`, `dart`, `dartVersion` and `dartSDK`), and falls back to
  /// parsing the text output of `flutter --version` when the machine-readable
  /// output is missing or unusable.
  ///
  /// Returns:
  /// - [String]: bare semantic version (e.g. `3.10.8`) — never a
  ///   caret-bearing constraint.
  ///
  /// Throws:
  /// - [Exception] when the version cannot be determined (machine output
  ///   unusable and text output unparseable), when the version is malformed
  ///   or prerelease, or when the version is below the supported minimum
  ///   (3.6.0). The message states what failed and that the version comes
  ///   from the Flutter toolchain, not a PATH `dart`.
  String getDartVersionSync() {
    log('🔍 Checking Flutter toolchain Dart version...');

    final version = _machineVersion() ?? _textVersion();

    if (version == null) {
      throw Exception(
        '⚠️ Could not determine the Dart version bundled with the Flutter toolchain. '
        'Expected `flutter --version --machine` (or `flutter --version`) to report the '
        'bundled Dart version as a semantic version of $supportedMinimumVersion or higher. '
        'The Dart version is detected from the Flutter toolchain (the `flutter` executable '
        'used by the CLI), not a `dart` binary on PATH.',
      );
    }

    return _validateSupported(version);
  }

  /// Reads the Dart version from `flutter --version --machine` (machine-
  /// readable JSON output). Returns null when the process cannot be started
  /// or the JSON output has no usable version field, so the caller falls back
  /// to the text output.
  ///
  /// Exit-status failures propagate as [SubprocessException] (the shared
  /// subprocess contract).
  String? _machineVersion() {
    final Object? raw;
    try {
      final result = runner.runSync('flutter', [
        '--version',
        '--machine',
      ], runInShell: true);
      checkProcessResult(
        result: result,
        operation: 'flutter --version --machine',
      );
      raw = result.stdout;
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Could not run `flutter --version --machine` (${e.toString()}). '
        'The Flutter toolchain must be available and executable on PATH. '
        'The Dart version is detected from the Flutter toolchain (the `flutter` executable '
        'used by the CLI), not a `dart` binary on PATH.',
      );
    }

    return _parseMachineOutput(raw);
  }

  /// Reads the Dart version from the text output of `flutter --version`.
  /// Returns null when the output cannot be parsed, so the caller throws an
  /// actionable error.
  ///
  /// Exit-status failures propagate as [SubprocessException] (the shared
  /// subprocess contract).
  String? _textVersion() {
    final String out;
    try {
      final result = runner.runSync('flutter', ['--version'], runInShell: true);
      checkProcessResult(result: result, operation: 'flutter --version');
      out = '${result.stdout}\n${result.stderr}';
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Could not run `flutter --version` (${e.toString()}). '
        'The Flutter toolchain must be available and executable on PATH. '
        'The Dart version is detected from the Flutter toolchain (the `flutter` executable '
        'used by the CLI), not a `dart` binary on PATH.',
      );
    }

    return _parseTextOutput(out);
  }

  /// Parses the machine-readable Flutter version output for a Dart version.
  ///
  /// The JSON must be an object, and one of the candidate fields
  /// (`dartSdkVersion`, `dart_version`, `dart`, `dartVersion`, `dartSDK`) must
  /// hold a strict semantic version string. The first candidate field whose
  /// value parses wins. Returns null when no candidate field parses.
  String? _parseMachineOutput(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null; // malformed JSON — fall back to the text output
    }
    if (decoded is! Map) return null;

    // Tolerate plausible field names; pick the first that parses. The real
    // Flutter machine output (e.g. Flutter 3.50.1) reports `dartSdkVersion`.
    const candidates = [
      'dartSdkVersion',
      'dart_version',
      'dart',
      'dartVersion',
      'dartSDK',
    ];
    for (final key in candidates) {
      final value = decoded[key];
      if (value is String) {
        final trimmed = value.trim();
        if (_strictVersion.hasMatch(trimmed)) return trimmed;
      }
    }
    return null;
  }

  /// Parses the text `flutter --version` output for a strict semantic Dart
  /// version. Accepts the `Dart SDK version: X.Y.Z` and `Dart X.Y.Z` forms and
  /// requires the version token to be the full matched token — any suffix
  /// (prerelease, dev, pre-release...) is rejected. Returns null when no
  /// version can be parsed.
  String? _parseTextOutput(String out) {
    final match =
        RegExp(
          r'Dart\s+SDK\s+version:\s*'
          r'(0|[1-9][0-9]*(?:\.(?:0|[1-9][0-9]*)){2})'
          r'(?![0-9A-Za-z.+-])',
          caseSensitive: false,
        ).firstMatch(out) ??
        RegExp(
          r'Dart\s+'
          r'(0|[1-9][0-9]*(?:\.(?:0|[1-9][0-9]*)){2})'
          r'(?![0-9A-Za-z.+-])',
          caseSensitive: false,
        ).firstMatch(out);
    return match?.group(1);
  }

  /// Validates that [version] meets the supported toolchain floor and returns
  /// it unchanged (bare semantic version string).
  ///
  /// Throws:
  /// - [Exception] when the version is below $supportedMinimumVersion.
  String _validateSupported(String version) {
    final parts = version.split('.');
    if (parts.length != 3) {
      throw _invalidVersionException(version);
    }

    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = int.tryParse(parts[2]);
    if (major == null || minor == null || patch == null) {
      throw _invalidVersionException(version);
    }

    if (major < 3 || (major == 3 && minor < 6)) {
      throw Exception(
        '⚠️ The Flutter toolchain bundles Dart $version, which is below the supported '
        'minimum of $supportedMinimumVersion. '
        'Update the Flutter toolchain (e.g. `flutter upgrade`) so the bundled Dart SDK '
        'is $supportedMinimumVersion or higher. '
        'The Dart version is detected from the Flutter toolchain (the `flutter` executable '
        'used by the CLI), not a `dart` binary on PATH.',
      );
    }

    log('✅ Flutter toolchain Dart version: $version');
    return version;
  }

  Exception _invalidVersionException(String version) {
    return Exception(
      '⚠️ Could not determine the Dart version bundled with the Flutter toolchain. '
      'Expected a strict semantic version (major.minor.patch) of $supportedMinimumVersion '
      'or higher; found "$version". '
      'The Dart version is detected from the Flutter toolchain (the `flutter` executable '
      'used by the CLI), not a `dart` binary on PATH.',
    );
  }

  static final RegExp _strictVersion = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );
}
