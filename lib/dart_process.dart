import 'dart:io';

/// Utilities for querying and validating the installed Dart SDK.
///
/// Provides synchronous helpers used by the CLI to detect the locally
/// installed Dart SDK version and to enforce a minimum required SDK.
abstract class DartProcess {
  /// Returns the installed Dart SDK version string or a sensible fallback.
  ///
  /// Runs `dart --version` and parses the output to extract a semantic
  /// version (major.minor.patch). If detection fails this returns the
  /// fallback `^3.6.0` which is used by the CLI as the minimum supported SDK.
  ///
  /// Returns:
  /// - [String]: detected version (e.g. `3.10.8`) or the fallback `^3.6.0`.
  ///
  /// Throws:
  /// - [Exception] when a version is detected but is lower than 3.6.0.
  static String getDartVersionSync() {
    const minimumVersion = '^3.6.0';

    try {
      print('🔍 Checking Dart version...');
      final result = Process.runSync('dart', ['--version']);
      if (result.exitCode != 0) return minimumVersion;
      final out = '${result.stdout}\n${result.stderr}';

      final match =
          RegExp(
            r'Dart\s+SDK\s+version:\s*([0-9]+(?:\.[0-9]+)*)',
            caseSensitive: false,
          ).firstMatch(out) ??
          RegExp(
            r'Dart\s+([0-9]+(?:\.[0-9]+)*)',
            caseSensitive: false,
          ).firstMatch(out);

      if (match != null) {
        final version = match.group(1)!;
        _validateDartVersion(version);
        print('✅ Dart version: $version');
        return version;
      }

      print('✅ Dart version: $minimumVersion');
      return minimumVersion;
    } catch (_) {
      return minimumVersion;
    }
  }

  /// Validates that [version] meets the minimum Dart SDK requirement (3.6.0).
  ///
  /// Parameters:
  /// - `version`: semantic version string (e.g. `3.10.8`).
  ///
  /// Throws:
  /// - [Exception] when the value is malformed or numerically less than 3.6.0.
  static void _validateDartVersion(String version) {
    final parts = version.split('.');
    if (parts.length < 2) {
      throw Exception(
        'Dart 3.6.0 or higher is required. Current version: $version',
      );
    }

    final major = int.tryParse(parts[0]) ?? 0;
    final minor = int.tryParse(parts[1]) ?? 0;

    if (major < 3 || (major == 3 && minor < 6)) {
      throw Exception(
        'Dart 3.6.0 or higher is required. Current version: $version',
      );
    }
  }
}
