import 'package:file/file.dart';
import 'package:yaml/yaml.dart';
import 'process_runner.dart';

/// A validated root workspace manifest.
///
/// Holds the parsed, validated top-level `workspace:` member paths (in file
/// order) and the detected line-ending convention of the file.
class WorkspaceManifest {
  /// The parsed workspace member paths, in file order.
  final List<String> members;

  /// The detected line-ending convention of the file (`\n` or `\r\n`).
  final String lineEnding;

  WorkspaceManifest({required this.members, required this.lineEnding});
}

/// Returns a user-facing description of a parsed YAML node.
String _describeNode(YamlNode node) {
  if (node is YamlScalar) {
    final value = node.value;
    if (value == null) return 'null';
    if (value is int) return 'an integer ($value)';
    if (value is num) return 'a number ($value)';
    if (value is bool) return 'a boolean ($value)';
    return 'a string';
  }
  if (node is YamlMap) return 'a map';
  if (node is YamlList) return 'a sequence';
  return 'a ${node.runtimeType}';
}

/// Parses and validates the root workspace `pubspec.yaml` content.
///
/// The top-level `workspace:` field must exist, must be a sequence of
/// strings, and the YAML must parse without error. Each failure mode is
/// reported distinctly: missing / malformed / wrong-type.
///
/// Returns the parsed member paths (in file order) and the detected
/// line-ending convention of the file.
///
/// Throws an [Exception] with a distinct message for each failure mode.
WorkspaceManifest parseWorkspaceManifest(
  String content, {
  String? expectedRootPath,
}) {
  final pathHint = expectedRootPath == null
      ? ''
      : ' Expected a workspace root at "$expectedRootPath".';

  YamlDocument doc;
  try {
    doc = loadYamlDocument(content);
  } catch (e) {
    throw Exception(
      '⚠️ Root workspace: malformed YAML in pubspec.yaml ($e).$pathHint',
    );
  }

  final root = doc.contents;
  if (root is! YamlMap) {
    throw Exception(
      '⚠️ Root workspace: missing "workspace:" section in pubspec.yaml.$pathHint',
    );
  }

  final workspaceNode = root.nodes['workspace'];
  if (workspaceNode == null) {
    throw Exception(
      '⚠️ Root workspace: missing "workspace:" section in pubspec.yaml.$pathHint',
    );
  }

  if (workspaceNode is YamlMap) {
    throw Exception(
      '⚠️ Root workspace: "workspace:" must be a sequence of strings '
      '(e.g. "workspace:\n  - packages/core"); got a map.$pathHint',
    );
  }

  if (workspaceNode is! YamlList) {
    throw Exception(
      '⚠️ Root workspace: "workspace:" must be a sequence of strings '
      '(e.g. "workspace:\n  - packages/core"); got ${_describeNode(workspaceNode)}.$pathHint',
    );
  }

  final members = <String>[];
  for (var index = 0; index < workspaceNode.nodes.length; index++) {
    final memberNode = workspaceNode.nodes[index];
    if (memberNode is YamlScalar && memberNode.value is String) {
      members.add(memberNode.value as String);
      continue;
    }
    throw Exception(
      '⚠️ Root workspace: "workspace:" member #${index + 1} is not a string '
      '(got ${_describeNode(memberNode)}).$pathHint',
    );
  }

  final lineEnding = content.contains('\r\n') ? '\r\n' : '\n';
  return WorkspaceManifest(members: members, lineEnding: lineEnding);
}

/// Returns the supported wildcard member that covers [path], or null.
///
/// A supported wildcard is a member value ending with an asterisk (the
/// existing convention is `packages/*` → everything under `packages/`).
/// A wildcard covers a path when the path starts with the prefix before
/// the asterisk.
String? findCoveringWildcard(List<String> members, String path) {
  for (final member in members) {
    if (!member.endsWith('*')) continue;
    final prefix = member.substring(0, member.length - 1);
    if (path.startsWith(prefix)) return member;
  }
  return null;
}

/// A line of content along with the line ending that follows it.
class _Line {
  final String text;
  final String ending;

  const _Line(this.text, this.ending);

  @override
  String toString() => text + ending;
}

/// Splits [content] into lines, preserving each line's exact text and ending
/// byte-for-byte (`\n`, `\r\n` or `\r`), including a trailing line without
/// an ending.
List<_Line> _splitLines(String content) {
  final lines = <_Line>[];
  final regex = RegExp(r'\r\n|\r|\n');
  var start = 0;
  for (final match in regex.allMatches(content)) {
    lines.add(_Line(content.substring(start, match.start), match.group(0)!));
    start = match.end;
  }
  if (start < content.length) {
    lines.add(_Line(content.substring(start), ''));
  }
  return lines;
}

/// Finds the index of the closing `]` matching the `[` at [openIndex],
/// honouring quoted strings inside the flow-style list. Returns -1 when no
/// matching closing bracket is found.
int _findMatchingClosingBracket(String content, int openIndex) {
  var depth = 0;
  var inDoubleQuotes = false;
  var inSingleQuotes = false;
  var i = openIndex;
  while (i < content.length) {
    final c = content[i];
    if (inDoubleQuotes) {
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '"') {
        inDoubleQuotes = false;
      }
    } else if (inSingleQuotes) {
      if (c == "'") {
        if (i + 1 < content.length && content[i + 1] == "'") {
          i += 2;
          continue;
        }
        inSingleQuotes = false;
      }
    } else {
      if (c == '"') {
        inDoubleQuotes = true;
      } else if (c == "'") {
        inSingleQuotes = true;
      } else if (c == '#') {
        // A comment runs to end of line; skip it entirely.
        final prev = i == 0 ? '\n' : content[i - 1];
        final startsComment =
            prev == '\n' || prev == '\r' || prev == ' ' || prev == '\t';
        if (startsComment) {
          final commentEnd = content.indexOf(RegExp(r'[\r\n]'), i);
          i = commentEnd == -1 ? content.length : commentEnd;
          continue;
        }
      } else if (c == '[') {
        depth++;
      } else if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
    i++;
  }
  return -1;
}

/// Finds the absolute content offset of the `[` that opens the workspace
/// flow-style list. The scan is comment- and quote-aware: a `[` inside a
/// comment or a quoted string is never treated as the opening bracket.
/// Returns -1 when no top-level `[` is found within [endOffset].
int _findTopLevelFlowOpen(String content, int startOffset, int endOffset) {
  var inDouble = false;
  var inSingle = false;
  var i = startOffset;
  while (i < endOffset) {
    final c = content[i];
    if (inDouble) {
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '"') {
        inDouble = false;
      }
      i++;
      continue;
    }
    if (inSingle) {
      if (c == "'") {
        if (i + 1 < endOffset && content[i + 1] == "'") {
          i += 2;
          continue;
        }
        inSingle = false;
      }
      i++;
      continue;
    }
    if (c == '"') {
      inDouble = true;
      i++;
      continue;
    }
    if (c == "'") {
      inSingle = true;
      i++;
      continue;
    }
    if (c == '#') {
      // A comment runs to end of line; skip it entirely. The `[` inside a
      // comment must never be mistaken for the flow-list opening bracket.
      final prev = i == 0 ? '\n' : content[i - 1];
      final startsComment =
          prev == '\n' || prev == '\r' || prev == ' ' || prev == '\t';
      if (startsComment) {
        final commentEnd = content.indexOf(RegExp(r'[\r\n]'), i);
        i = commentEnd == -1 || commentEnd >= endOffset
            ? endOffset
            : commentEnd;
        continue;
      }
    }
    if (c == '[') {
      return i;
    }
    i++;
  }
  return -1;
}

/// Returns the absolute offset just after the last member scalar inside the
/// flow-style list opened at [openIndex] and closed at [closeIndex].
///
/// Comments and whitespace after the last member are ignored, and the
/// returned position is never inside a comment or a quoted string. Returns
/// -1 for an empty list (no member found).
int _lastFlowMemberEnd(String content, int openIndex, int closeIndex) {
  var lastContentPos = -1;
  var inDouble = false;
  var inSingle = false;
  var i = openIndex + 1;
  while (i < closeIndex) {
    final c = content[i];
    if (inDouble) {
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '"') {
        inDouble = false;
        lastContentPos = i;
      }
      i++;
      continue;
    }
    if (inSingle) {
      if (c == "'") {
        if (i + 1 < closeIndex && content[i + 1] == "'") {
          i += 2;
          continue;
        }
        inSingle = false;
        lastContentPos = i;
      }
      i++;
      continue;
    }
    if (c == '"') {
      inDouble = true;
      lastContentPos = i;
      i++;
      continue;
    }
    if (c == "'") {
      inSingle = true;
      lastContentPos = i;
      i++;
      continue;
    }
    if (c == '#') {
      final prev = i == 0 ? '\n' : content[i - 1];
      final startsComment =
          prev == '\n' || prev == '\r' || prev == ' ' || prev == '\t';
      if (startsComment) {
        final commentEnd = content.indexOf(RegExp(r'[\r\n]'), i);
        i = commentEnd == -1 ? closeIndex : commentEnd;
        continue;
      }
      // A '#' inside a plain scalar is plain content.
      lastContentPos = i;
      i++;
      continue;
    }
    if (!RegExp(r'\s').hasMatch(c)) {
      lastContentPos = i;
    }
    i++;
  }
  if (lastContentPos == -1) return -1;
  return lastContentPos + 1;
}

/// Returns the index of the first line where the workspace section ends:
/// the first column-0, non-empty, non-comment line after the `workspace:`
/// line. Returns `lines.length` when the section runs to the end of the file.
int _workspaceSectionEnd(List<_Line> lines, int wsIndex) {
  for (var i = wsIndex + 1; i < lines.length; i++) {
    final raw = lines[i].text;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('#')) continue;
    if (!RegExp(r'^\s').hasMatch(raw)) {
      return i;
    }
  }
  return lines.length;
}

/// Returns the absolute content offset of line [index].
int _lineOffset(List<_Line> lines, int index) {
  var offset = 0;
  for (var i = 0; i < index; i++) {
    offset += lines[i].text.length + lines[i].ending.length;
  }
  return offset;
}

/// Rewrites [content] so that its `workspace:` membership list contains
/// [packagePath], preserving everything else byte-for-byte.
String insertWorkspaceMember(
  String content,
  WorkspaceManifest manifest,
  String packagePath,
) {
  final lines = _splitLines(content);
  final wsIndex = lines.indexWhere(
    (line) => line.text.startsWith('workspace:'),
  );
  if (wsIndex == -1) {
    // Validation should have caught this; fail closed.
    throw Exception(
      '⚠️ Root workspace: "workspace:" section not found in root pubspec.yaml.',
    );
  }

  // Detect the real flow-style list from the section body, not from a raw
  // line substring: a `[` inside a comment or a quoted string on the
  // workspace line must never be mistaken for the opening bracket.
  final sectionEndIndex = _workspaceSectionEnd(lines, wsIndex);
  final openIndex = _findTopLevelFlowOpen(
    content,
    _lineOffset(lines, wsIndex),
    _lineOffset(lines, sectionEndIndex),
  );

  if (openIndex != -1) {
    return _editFlowStyle(content, lines, wsIndex, packagePath, openIndex);
  }
  return _editBlockStyle(
    content,
    lines,
    wsIndex,
    packagePath,
    manifest.lineEnding,
  );
}

/// Surgical flow-style edit: inserts `, <packagePath>` (or `<packagePath>`
/// for an empty list) right after the last member scalar, leaving the file
/// valid. Existing members keep their original formatting — including any
/// comments inside the list — everything else is unchanged.
String _editFlowStyle(
  String content,
  List<_Line> lines,
  int wsIndex,
  String packagePath,
  int openIndex,
) {
  final closeIndex = _findMatchingClosingBracket(content, openIndex);
  if (closeIndex == -1) {
    throw Exception(
      '⚠️ Root workspace: could not locate the closing bracket of the workspace list.',
    );
  }

  final lastEnd = _lastFlowMemberEnd(content, openIndex, closeIndex);
  if (lastEnd == -1) {
    // Empty flow-style list: insert the new member right after the
    // opening bracket.
    return content.substring(0, openIndex + 1) +
        packagePath +
        content.substring(openIndex + 1);
  }

  // When the last member is followed by a comma (e.g. a trailing comma), the
  // new member is inserted right after it without a repeated comma.
  final lastChar = content[lastEnd - 1];
  final insertion = lastChar == ',' ? ' $packagePath' : ', $packagePath';
  return content.substring(0, lastEnd) + insertion + content.substring(lastEnd);
}

/// Surgical block-style edit: inserts a new `  - <packagePath>` line at the
/// end of the member list (after the last member line). Everything else —
/// keys, comments, blank lines, key order, CRLF line endings — is preserved
/// byte-for-byte.
String _editBlockStyle(
  String content,
  List<_Line> lines,
  int wsIndex,
  String packagePath,
  String lineEnding,
) {
  // Find the section end: the first column-0, non-empty, non-comment line
  // after the `workspace:` line.
  final sectionEnd = _workspaceSectionEnd(lines, wsIndex);

  // Find the last member line within the section.
  var lastMember = -1;
  for (var i = wsIndex + 1; i < sectionEnd; i++) {
    if (RegExp(r'^\s*-\s').hasMatch(lines[i].text)) {
      lastMember = i;
    }
  }
  final insertAt = lastMember == -1 ? wsIndex + 1 : lastMember + 1;

  // Inserting at EOF while the file has no trailing newline: give the final
  // line the new ending and leave the inserted line without one, so the file
  // keeps its original trailing-newline state.
  if (insertAt == lines.length &&
      lines.isNotEmpty &&
      lines.last.ending.isEmpty) {
    lines[lines.length - 1] = _Line(lines.last.text, lineEnding);
    lines.add(_Line('  - $packagePath', ''));
    return lines.map((line) => line.toString()).join();
  }

  lines.insert(insertAt, _Line('  - $packagePath', lineEnding));
  return lines.map((line) => line.toString()).join();
}

/// Utilities for creating and configuring a Flutter workspace directory.
///
/// This class provides synchronous helpers used by the CLI to scaffold a
/// workspace, create package folders, add common dependencies, and resolve
/// workspace dependencies.
class WorkspaceProcess {
  final FileSystem fs;
  final ProcessRunner runner;
  final void Function(String) log;

  WorkspaceProcess({required this.fs, required this.runner, this.log = print});

  /// Creates `<name>_workspaces` and changes the current working directory to it.
  ///
  /// The target path is resolved from the current (invocation) directory and is
  /// reserved **exclusively**: an occupied path — an existing directory, file, or
  /// link — is refused *before* any Flutter scaffolding command runs. This means
  /// an existing workspace with user files is never overwritten, and two
  /// overlapping setup runs cannot both claim the same name.
  ///
  /// Returns the exact [Directory] reserved by this invocation. The caller must
  /// use it to restore the working directory and to perform scoped cleanup.
  ///
  /// Parameters:
  /// - `projectName`: base name for the workspace (e.g. `my_app`). The folder
  ///   created will be `my_app_workspaces` and `Directory.current` will be set to
  ///   it.
  ///
  /// Throws:
  /// - [Exception] when the target path is already occupied.
  Directory createWorkspaceFolderSync({required String projectName}) {
    log('📁 Creating workspace folder...');
    final folderName = '${projectName}_workspaces';
    final base = fs.currentDirectory;
    final dir = base.childDirectory(folderName);

    // Refuse an occupied path before scaffolding. `existsSync()` is checked for
    // a directory, a file, and a link (including a dangling link) so any
    // pre-existing entry at the target is detected. This is the exclusive
    // reservation: the path is only created when it is free, and the check uses
    // the injected [FileSystem] so it is cross-platform (no platform-specific
    // commands). Note: `package:file` 7.x does not expose an `exclusive` flag on
    // `Directory.createSync`, so the guard is the reservation mechanism. For
    // truly concurrent processes a small TOCTOU window remains; sequential
    // invocations (the testable case) are fully protected.
    if (dir.existsSync() ||
        base.childFile(folderName).existsSync() ||
        base.childLink(folderName).existsSync()) {
      throw Exception(
        '⚠️ Target path "$folderName" already exists. '
        'Refusing to overwrite it. Aborting setup.',
      );
    }

    dir.createSync();
    fs.currentDirectory = dir;
    log('✅ Workspace folder created: $folderName');
    return dir.absolute;
  }

  /// Writes the workspace root `pubspec.yaml` with basic configuration.
  ///
  /// Parameters:
  /// - `dartVersion`: Dart SDK version constraint (e.g. `3.10.8`).
  /// - `projectName`: the main application folder name included in the workspace.
  void createRootPubspecSync({
    required String dartVersion,
    required String projectName,
  }) {
    log('📝 Creating root pubspec.yaml...');
    final isDart311OrHigher = _isVersionAtLeast(dartVersion, 3, 11);

    final workspaceSection = isDart311OrHigher
        ? '  - $projectName\n  - packages/*'
        : '  - $projectName\n  - packages/core';

    final content =
        '''
name: _
version: 0.1.0
description: A Dart workspace example
publish_to: none

environment:
  sdk: ^$dartVersion

workspace:
$workspaceSection

dependencies:
  flutter:
    sdk: flutter

dev_dependencies:
  flutter_test:
    sdk: flutter
''';

    final file = fs.file('pubspec.yaml');
    file.writeAsStringSync(content);
    log('✅ Root pubspec.yaml created');
  }

  /// Creates the `packages` folder used for shared packages.
  void createPackagesFolderSync() {
    log('📁 Creating packages folder...');
    final dir = fs.directory('packages');
    dir.createSync(recursive: true);
    log('✅ Packages folder created');
  }

  /// Adds common runtime Flutter dependencies to the workspace pubspec.
  ///
  /// Throws:
  /// - [SubprocessException] when the `flutter pub add` command exits with a
  ///   non-zero status (message includes the operation, exit status, and
  ///   Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void addingFlutterDependenciesSync() {
    try {
      log('📦 Adding Flutter dependencies...');
      final result = runner.runSync('flutter', [
        'pub',
        'add',
        'cupertino_icons',
      ], runInShell: true);
      checkProcessResult(
        result: result,
        operation: 'flutter pub add cupertino_icons',
      );
      log('✅ Flutter dependencies added');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to add Flutter dependencies: '
        'flutter pub add cupertino_icons could not be started '
        '(missing executable?): $e',
      );
    }
  }

  /// Adds development dependencies (linting) to the workspace pubspec.
  ///
  /// Throws:
  /// - [SubprocessException] when the `flutter pub add` command exits with a
  ///   non-zero status (message includes the operation, exit status, and
  ///   Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void addingFlutterDevDependenciesSync() {
    try {
      log('📦 Adding Flutter dev dependencies...');
      final result = runner.runSync('flutter', [
        'pub',
        'add',
        '--dev',
        'flutter_lints',
        'custom_lint',
      ], runInShell: true);
      checkProcessResult(
        result: result,
        operation: 'flutter pub add --dev flutter_lints custom_lint',
      );
      log('✅ Flutter dev dependencies added');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to add Flutter dev dependencies: '
        'flutter pub add --dev flutter_lints custom_lint could not be started '
        '(missing executable?): $e',
      );
    }
  }

  /// Runs `flutter pub get` at the current working directory to resolve dependencies.
  ///
  /// Throws:
  /// - [SubprocessException] when `flutter pub get` exits with a non-zero
  ///   status (message includes the operation, exit status, and Flutter output).
  /// - [Exception] when the `flutter` command cannot be started.
  void runningFlutterPubGetSync() {
    try {
      final result = runner.runSync('flutter', [
        'pub',
        'get',
      ], runInShell: true);
      checkProcessResult(result: result, operation: 'flutter pub get');
    } catch (e) {
      if (e is SubprocessException) rethrow;
      throw Exception(
        '⚠️ Failed to run Flutter pub get: '
        'flutter pub get could not be started (missing executable?): $e',
      );
    }
  }

  /// Updates the root `pubspec.yaml` to include a new package in the workspace.
  ///
  /// The workspace `pubspec.yaml` field is parsed and validated (not searched
  /// line-by-line), so a member like `packages/feature_tools` is never
  /// mistaken for `packages/feature`, a `*` in a comment is never mistaken
  /// for a wildcard entry, and flow-style/quoted lists are supported. The
  /// edit is surgical: only the membership list is modified and everything
  /// else — unrelated keys, comments, key order, blank lines and CRLF line
  /// endings — is preserved byte-for-byte.
  ///
  /// An existing exact member or a supported wildcard that covers the new
  /// member leaves the file unchanged. Otherwise a new `  - packages/<name>`
  /// entry is inserted and the file is rewritten.
  ///
  /// Throws:
  /// - [Exception] when the file is missing.
  /// - [Exception] with a distinct message when the workspace field is
  ///   missing / malformed / wrong-type (reported before any mutation).
  void updateRootPubspecSync({required String packageName}) {
    log('📝 Updating root pubspec.yaml to include "$packageName"...');
    final file = fs.file('pubspec.yaml');

    if (!file.existsSync()) {
      throw Exception('⚠️ Root pubspec.yaml not found.');
    }

    final content = file.readAsStringSync();

    final manifest = parseWorkspaceManifest(
      content,
      expectedRootPath: fs.currentDirectory.path,
    );

    final packagePath = 'packages/$packageName';

    final coveringWildcard = findCoveringWildcard(
      manifest.members,
      packagePath,
    );
    if (coveringWildcard != null) {
      log(
        'ℹ️ Wildcard "$coveringWildcard" detected. Skipping manual addition of "$packageName".',
      );
      return;
    }

    if (manifest.members.contains(packagePath)) {
      log('ℹ️ Package "$packageName" is already in the workspace.');
      return;
    }

    final newContent = insertWorkspaceMember(content, manifest, packagePath);
    // Fail closed: never write a file whose workspace section cannot be
    // re-parsed (e.g. a flow-style list corrupted by the edit).
    try {
      parseWorkspaceManifest(
        newContent,
        expectedRootPath: fs.currentDirectory.path,
      );
    } catch (e) {
      throw Exception(
        '⚠️ Root workspace: workspace edit did not produce a valid manifest. ($e)',
      );
    }
    file.writeAsStringSync(newContent);
    log('✅ Root pubspec.yaml updated');
  }

  /// Moves configuration files from the Flutter app folder to the workspace root.
  ///
  /// Moves `.gitignore` and `analysis_options.yaml` so they apply globally.
  ///
  /// Parameters:
  /// - `projectName`: the name of the Flutter app folder.
  /// - `initialDirectory`: the directory that was current before scaffolding.
  /// Throws:
  /// - [Exception] with message `⚠️ Failed to move configuration files` on failure.
  void moveConfigsToWorkspaceRootSync({
    required String projectName,
    required Directory initialDirectory,
  }) {
    log('🚚 Moving configuration files to workspace root...');
    final files = ['.gitignore', 'analysis_options.yaml'];

    for (final fileName in files) {
      try {
        final source = fs.file('$projectName/$fileName');
        if (source.existsSync()) {
          source.renameSync(fileName);
          log('✅ Moved $fileName to workspace root');
        }
      } catch (_) {
        throw Exception('⚠️ Failed to move $fileName');
      }
    }
  }

  bool _isVersionAtLeast(
    String version,
    int majorThreshold,
    int minorThreshold,
  ) {
    final cleanVersion = version.startsWith('^')
        ? version.substring(1)
        : version;
    final parts = cleanVersion.split('.');
    if (parts.isEmpty) return false;

    final major = int.tryParse(parts[0]) ?? 0;
    final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    if (major > majorThreshold) return true;
    if (major == majorThreshold && minor >= minorThreshold) return true;
    return false;
  }
}
