import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The package root, resolved from this test file's own location
/// (`test/publish_workflow_test.dart`), so the assertions are independent of
/// the process working directory (the real-filesystem test group mutates
/// `Directory.current`). `Platform.script` points at the compiled kernel
/// dump under `dart test`, so the source URI is taken from the JIT stack
/// trace's first frame instead — that frame is this file.
String get packageRoot {
  final st = StackTrace.current.toString();
  final match = RegExp(r'\(file://([^)]+)\)').firstMatch(st);
  if (match == null) {
    throw StateError('could not resolve the package root from the stack trace');
  }
  // The frame keeps a `:line:column` suffix; strip it before converting.
  final uriPath = match.group(1)!.replaceFirst(RegExp(r':(\d+):(\d+)$'), '');
  final file = File(Uri.parse('file://$uriPath').toFilePath());
  return file.parent.parent.absolute.path;
}

/// Offline structural assertions for the two publish workflows.
///
/// `.github/workflows/publish.yml` (tag-driven, live) and
/// `.github/workflows/publish-test.yml` (manual `workflow_dispatch` test mode,
/// never publishes). The files are parsed with package:yaml; GitHub
/// expressions such as `${{ github.ref_name }}` are plain strings, so no
/// raw-string regexes are used. The two files must be kept in sync with these
/// assertions.
void main() {
  final publish = _loadWorkflow('publish.yml');
  final testMode = _loadWorkflow('publish-test.yml');

  group('workflow fixtures', () {
    test('both workflow files exist and parse as YAML maps', () {
      expect(
        File('$packageRoot/.github/workflows/publish.yml').existsSync(),
        isTrue,
      );
      expect(
        File('$packageRoot/.github/workflows/publish-test.yml').existsSync(),
        isTrue,
      );
      expect(publish, isA<Map>());
      expect(testMode, isA<Map>());
    });
  });

  group('publish.yml', () {
    test('triggers only on tag pushes with the v-prefixed semver pattern', () {
      final on = _onClause(publish);
      expect(on.keys.toList(), ['push']);
      final push = on['push'];
      expect(push, isA<Map>());
      expect(push.keys.toList(), ['tags']);
      expect(push.containsKey('branches'), isFalse);
      // No workflow_dispatch / pull_request / branch-push triggers.
      expect(on.containsKey('workflow_dispatch'), isFalse);
      expect(on.containsKey('pull_request'), isFalse);
      final tags = push['tags'];
      expect(tags, isA<List>());
      expect(tags.map((t) => t.toString()), contains('v[0-9]+.[0-9]+.[0-9]+*'));
    });

    test('permissions grant id-token write and contents read', () {
      final perms = _permissions(publish);
      expect(perms['id-token'], equals('write'));
      expect(perms['contents'], equals('read'));
    });

    test(
      'runs the gates in order, ending in a single non-interactive publish step',
      () {
        final steps = _stepsOfJob(publish, 'publish');
        expect(steps, isNotEmpty);

        final extractionIndex = steps.indexWhere((step) {
          final run = _run(step);
          // Reads the pushed tag, the pubspec version, and the first changelog line.
          return run.contains('github.ref_name') &&
              run.contains('pubspec.yaml') &&
              run.contains('CHANGELOG.md') &&
              run.contains('GITHUB_OUTPUT');
        });
        expect(
          extractionIndex,
          greaterThanOrEqualTo(0),
          reason: 'expected a tag/pubspec/changelog extraction step',
        );

        final verifyIndex = steps.indexWhere((step) {
          final run = _run(step);
          // Consumes the extraction outputs for tag, pubspec, and changelog.
          return run.contains('steps.versions.outputs.tag') &&
              run.contains('steps.versions.outputs.pubspec') &&
              run.contains('steps.versions.outputs.changelog');
        });
        expect(
          verifyIndex,
          greaterThanOrEqualTo(0),
          reason: 'expected a tag/pubspec/changelog verify step',
        );

        final getIndex = _indexOfRun(steps, 'dart pub get --enforce-lockfile');
        final formatIndex = _indexOfRun(
          steps,
          'dart format --set-exit-if-changed .',
        );
        final analyzeIndex = _indexOfRun(steps, 'dart analyze');
        final testIndex = _indexOfRun(steps, 'dart test');
        final dryRunIndex = _indexOfRun(steps, 'dart pub publish --dry-run');
        final forceIndex = _indexOfRun(steps, 'dart pub publish --force');

        expect(getIndex, greaterThanOrEqualTo(0));
        expect(formatIndex, greaterThanOrEqualTo(0));
        expect(analyzeIndex, greaterThanOrEqualTo(0));
        expect(testIndex, greaterThanOrEqualTo(0));
        expect(dryRunIndex, greaterThanOrEqualTo(0));
        expect(forceIndex, greaterThanOrEqualTo(0));

        // Exactly one final publish step, and it is the last step.
        expect(
          steps.indexWhere((step) => _run(step) == 'dart pub publish --force'),
          equals(forceIndex),
        );
        expect(
          forceIndex,
          equals(steps.length - 1),
          reason: 'no steps may follow the --force publish step',
        );

        // Ordering: extraction -> verify -> get -> format -> analyze -> test ->
        // dry run -> final publish.
        expect(extractionIndex, lessThan(verifyIndex));
        expect(verifyIndex, lessThan(getIndex));
        expect(getIndex, lessThan(formatIndex));
        expect(formatIndex, lessThan(analyzeIndex));
        expect(analyzeIndex, lessThan(testIndex));
        expect(testIndex, lessThan(dryRunIndex));
        expect(dryRunIndex, lessThan(forceIndex));

        // --force appears ONLY in the final step.
        for (var i = 0; i < steps.length; i++) {
          final hasForce = _run(steps[i]).contains('--force');
          if (i == forceIndex) {
            expect(
              hasForce,
              isTrue,
              reason: 'final publish step must use --force',
            );
          } else {
            expect(
              hasForce,
              isFalse,
              reason: 'step ${steps[i]['name']} must not use --force',
            );
          }
        }

        // Plain `dart pub publish` (no flags) must never appear.
        for (var i = 0; i < steps.length; i++) {
          expect(
            _run(steps[i]).trim(),
            isNot(equals('dart pub publish')),
            reason:
                'step ${steps[i]['name']} must not run plain `dart pub publish`',
          );
        }
      },
    );
  });

  group('publish-test.yml', () {
    test('triggers only on manual workflow_dispatch', () {
      final on = _onClause(testMode);
      expect(on.keys.toList(), ['workflow_dispatch']);
      expect(on.containsKey('push'), isFalse);
      expect(on.containsKey('pull_request'), isFalse);
    });

    test('grants contents read and never id-token', () {
      final perms = _permissions(testMode);
      expect(perms.containsKey('id-token'), isFalse);
      expect(perms['contents'], equals('read'));
    });

    test('never runs any dart pub publish variant other than the dry run', () {
      for (final jobId in (testMode['jobs'] as Map).keys) {
        for (final step in _stepsOfJob(testMode, jobId.toString())) {
          final run = _run(step);
          if (run.contains('dart pub publish')) {
            expect(
              run,
              equals('dart pub publish --dry-run'),
              reason:
                  'job $jobId step ${step['name']} may only run the dry run',
            );
            expect(run.contains('--force'), isFalse);
          }
        }
      }
    });

    test('runs the five gates in the same relative order as publish.yml', () {
      final expected = _gateSequence(_stepsOfJob(publish, 'publish'));
      expect(
        expected,
        equals([
          'dart pub get --enforce-lockfile',
          'dart format --set-exit-if-changed .',
          'dart analyze',
          'dart test',
          'dart pub publish --dry-run',
        ]),
      );

      final actual = _gateSequence(_allJobSteps(testMode));
      expect(actual, equals(expected));
    });
  });
}

Map<String, dynamic> _loadWorkflow(String filename) {
  final file = File('$packageRoot/.github/workflows/$filename');
  final doc = loadYaml(file.readAsStringSync());
  if (doc is! Map) {
    throw StateError(
      'expected .github/workflows/$filename to parse as a YAML map',
    );
  }
  final normalized = _normalize(doc);
  return Map<String, dynamic>.from(normalized as Map);
}

/// Deep-converts a package:yaml tree (YamlMap/YamlList) into plain maps and
/// lists with String keys, so assertions can use ordinary Dart collections.
dynamic _normalize(dynamic value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _normalize(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _normalize(item)];
  return value;
}

Map<String, dynamic> _onClause(Map<String, dynamic> workflow) {
  // package:yaml parses the GitHub `on:` key as a plain string here; fall back
  // to a boolean key just in case of a schema difference.
  final on = workflow.entries
      .firstWhere(
        (e) => e.key.toString() == 'on',
        orElse: () => MapEntry('on', null),
      )
      .value;
  expect(on, isA<Map>(), reason: 'expected a top-level `on:` clause');
  return Map<String, dynamic>.from(on as Map);
}

Map<String, dynamic> _permissions(Map<String, dynamic> workflow) {
  final perms = workflow['permissions'];
  expect(
    perms,
    isA<Map>(),
    reason: 'expected a top-level `permissions:` block',
  );
  return Map<String, dynamic>.from(perms as Map);
}

List<Map<String, dynamic>> _stepsOfJob(
  Map<String, dynamic> workflow,
  String jobId,
) {
  final jobs = workflow['jobs'] as Map;
  final job = jobs[jobId];
  expect(job, isNotNull, reason: 'expected a job named `$jobId`');
  final steps = (job as Map)['steps'] as List;
  return steps.cast<Map<String, dynamic>>().toList();
}

List<Map<String, dynamic>> _allJobSteps(Map<String, dynamic> workflow) {
  final jobs = workflow['jobs'] as Map;
  return [
    for (final job in jobs.values)
      ...(job as Map)['steps'].cast<Map<String, dynamic>>(),
  ];
}

String _run(Map<String, dynamic> step) => (step['run'] ?? '').toString().trim();

int _indexOfRun(List<Map<String, dynamic>> steps, String run) =>
    steps.indexWhere((step) => _run(step) == run);

/// The five gate commands recognized in a workflow, in publish order.
const _gateCommands = [
  'dart pub get --enforce-lockfile',
  'dart format --set-exit-if-changed .',
  'dart analyze',
  'dart test',
  'dart pub publish --dry-run',
];

/// Returns the recognized gates in the relative order they appear in `steps`.
List<String> _gateSequence(List<Map<String, dynamic>> steps) => [
  for (final step in steps)
    if (_gateCommands.contains(_run(step))) _run(step),
];
