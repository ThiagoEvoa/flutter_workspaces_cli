# Flutter Workspaces CLI

A command-line tool for scaffolding and managing monorepo-style Flutter workspace structures. This CLI automates the creation of a complete Flutter workspace with a core shared package, main application, and proper dependency configuration.

## Features

- ✅ **Workspace Creation**: Automatically creates a `<name>_workspaces` folder and sets up the workspace structure.
- 📦 **Core Package Scaffolding**: Creates a reusable `packages/core` package for shared code.
- ➕ **Add Package**: Easily add new packages to your existing workspace with a single command.
- 📱 **Flutter App Scaffolding**: Generates a main Flutter application that imports and uses the core package.
- 🎯 **Workspace Resolution**: Configures `pubspec.yaml` files with workspace resolution for monorepo support.
- 🔍 **Environment Validation**: Verifies that the Flutter toolchain on PATH bundles a supported Dart SDK (>= 3.12.0 for Flutter >= 3.44.0) and uses that same version for every generated manifest.
- 📋 **Dependency Management**: Automatically adds common Flutter dependencies (cupertino_icons, flutter_lints).
- 🧹 **Error Handling**: Reverts workspace creation on failure for clean error states.
- 🏗️ **SOLID Architecture**: Refactored to use Dependency Injection with `FileSystem` and `ProcessRunner` abstractions for better testability and maintainability.

## Requirements

Two different Dart requirements apply, and they are not the same:

- **CLI installation** (the `flutter_workspaces_cli` package itself): [Dart SDK](https://dart.dev/get-dart) `^3.11.5` (per this package's own `pubspec.yaml` `environment.sdk`) plus the [Flutter SDK](https://docs.flutter.dev/get-started/install) required to use the CLI.
- **Flutter toolchain used for generation** (the `flutter` executable on PATH that scaffolds and resolves the workspaces): must bundle a Dart SDK `>= 3.12.0` (Flutter `>= 3.44.0`, the oldest stable toolchain bundling that Dart). The CLI detects that version (machine-readable `flutter --version --machine`, with a text-parse fallback) and serializes it into every generated manifest. Every generated workspace pins both `environment.sdk: ^<detected>` (e.g. `^3.12.0`) and `flutter: ">=3.44.0"`, and emits the workspace glob layout (`packages/*`) — the floor toolchain bundles Dart 3.12.0, which supports the glob syntax, so no older explicit-member-list layout is generated.
- **System**: macOS, Linux, or Windows with shell support

A toolchain below the floor is rejected with an error that names both the detected Dart version and the required minimum (3.12.0 / Flutter 3.44.0), before any filesystem writes happen — no `my_app_workspaces` directory is created, no manifest is written or rewritten, and no lockfile is changed (the same rejection applies to `setup` and `add-package`; `add-package` still performs its read-only manifest validation and target-reservation check first).

## Installation

```bash
dart pub global activate flutter_workspaces_cli
```

## Usage

### Create a New Workspace

Run the CLI with the required `--name` argument to create a new workspace:

```bash
flutter_workspaces_cli --name my_app
```

Or use the short flag:

```bash
flutter_workspaces_cli -n my_app
```

### Add a New Package

To add a new package to an existing workspace, use the `add-package` command from the workspace root:

```bash
flutter_workspaces_cli add-package --name my_feature
```

`setup` is an explicit alias for the default setup command: `flutter_workspaces_cli setup --name my_app` is equivalent to `flutter_workspaces_cli --name my_app`.

### Help

The CLI prints usage and exits `0` for help requests. No workspace folder is created and no Flutter command is run.

Global help (usage + all commands + global options):

```bash
flutter_workspaces_cli --help      # also: -h, help, help setup
flutter_workspaces_cli setup --help  # the default setup command
```

Add-package help (add-package usage + global options):

```bash
flutter_workspaces_cli add-package --help   # also: add-package -h, add-package help, help add-package
```

## Project Structure

The project follows a modular service-based structure in `lib/`:

- `bin/`: CLI entry point.
- `lib/`:
    - `setup_runner.dart`: Orchestrates the initial workspace setup.
    - `add_package_runner.dart`: Orchestrates adding new packages.
    - `process_runner.dart`: Abstraction for executing system processes.
    - `*_process.dart`: Modular services handling specific parts of the workflow (Dart, Flutter, Workspace, Packages, etc.).

### Generated Workspace Structure

After running the setup command, the following structure is created:

```
my_app_workspaces/
├── pubspec.yaml              # Root workspace pubspec
├── analysis_options.yaml     # Root workspace analysis options
├── my_app/                   # Main Flutter application
│   ├── lib/
│   │   └── main.dart        # Main entry point (imports core)
│   ├── test/
│   │   └── widget_test.dart # Smoke test exercising the starter UI
│   ├── pubspec.yaml         # App manifest (workspace resolution)
└── packages/
    └── core/                 # Shared core package
        ├── lib/
        │   └── core.dart
        ├── test/
        │   └── core_test.dart
        └── pubspec.yaml
```

## Command-Line Arguments

### Setup (Default)

| Argument | Short | Required | Description |
|----------|-------|----------|-------------|
| `--name` | `-n` | Yes | The base name for your workspace and app (e.g., `my_app`) |

### Add Package (`add-package`)

| Argument | Short | Required | Description |
|----------|-------|----------|-------------|
| `--name` | `-n` | Yes | The name of the new package to create in `packages/` |

## Exit Codes

- `0`: Success and help
- `1`: Execution error (execution failed)
- `64`: Usage error (missing/invalid name, unknown flag, stray argument)

## Concurrency and parallel runs

Every CLI invocation guards the paths it would otherwise touch with an **atomic reservation sentinel**, so two overlapping runs cannot both create the same workspace, both add the same package, or both rewrite the same workspace-wide files.

### How the reservation works

`package:file` 7.x cannot supply the atomic primitive the reservation needs: `Directory.createSync` is silent on an existing path, and its `File.createSync(exclusive: true)` drops the `exclusive` parameter (the parameter is deliberately ignored — dartbug.com/49647), so neither can reject an occupied path. The atomic claim therefore goes through `dart:io` directly: `File.createSync(path, exclusive: true)` is a compare-and-set — `open(O_CREAT | O_EXCL | O_WRONLY)` on POSIX and `CreateFile` with `CREATE_NEW` on Windows — so exactly one invocation wins and the rest fail fast. Because the sentinel is an **ordinary file**, it needs neither an elevated token nor Windows Developer Mode. The reservations are therefore sentinel **files** with the same name as the path they guard, created next to the real target:

- **`setup`** — one sentinel next to the workspace folder it will create: `.<folderName>.reserved` in the invocation directory (e.g. `.my_app_workspaces.reserved` for `--name my_app`). The directory is created after the sentinel claim; an occupied target refuses before any Flutter/Dart subprocess runs. The directory is created only after the sentinel claim succeeds.
- **`add-package`** — two sentinels, both released on every exit path:
  - **Workspace-level lock**: `.flutter_workspaces_cli.lock` in the workspace root — serializes every workspace-wide write (root `pubspec.yaml`, `pubspec.lock`, the `packages/` directory) so concurrent add-package runs cannot race each other's writes.
  - **Destination lock**: `packages/.<packageName>.reserved` in the workspace root — the per-package claim for the package being added (e.g. `packages/.my_feature.reserved` for `--name my_feature`).

Acquiring the sentinel is compare-and-set: exactly one invocation can claim it. The loser fails fast — before scaffolding, manifest rewrites, or any filesystem effect — with a friendly error naming the path and the recovery steps. A successful run releases the sentinel before returning (and on rollback too), so a clean run leaves no trace. Release is best-effort: if deletion fails, the run is unaffected (the original error still surfaces) and the message is logged.

### Fail-fast behavior

A run that would start after another run already holds the claim stops immediately with an `⚠️` message naming what it would have done. Examples:

```
⚠️ Target path "my_app_workspaces" already exists. Refusing to overwrite it. Aborting setup.
⚠️ Target path "my_app_workspaces" is already reserved or occupied. Refusing to overwrite it. Aborting setup. Details: ...
⚠️ the workspace lock is already reserved: another flutter_workspaces_cli run is in progress, or a previous run was interrupted and left a reservation behind at "<workspace>/.flutter_workspaces_cli.lock". If no other run is in progress, remove that file manually (see the README "Retries and stale locks" section) and retry. Details: ...
⚠️ Target directory "packages/my_feature" is already reserved: another flutter_workspaces_cli run is in progress, or a previous run was interrupted and left a reservation behind at "packages/.my_feature.reserved". Refusing to overwrite it. Aborting. Details: ...
⚠️ Target directory "packages/my_feature" could not be reserved: a permission or file-system error prevented creating the reservation at "packages/.my_feature.reserved". Refusing to proceed. Aborting. Details: ...
```

The read-only guard and the atomic claim produce distinct, friendly messages — the guard fires before any subprocess runs, the claim closes the TOCTOU window between two concurrent runs. The two claim failures are reported separately: an occupied path reports **contention** (with the recovery steps), while a permission or file-system error that prevented the sentinel from being created is reported **as such**. Both name the affected path and retain the underlying error.

### Retries and stale locks

The sentinel is deleted on success, on rollback, and on every exit path — but a crash or force-kill can leave it behind. A leftover sentinel does **not** block a different name: `.my_app_workspaces.reserved` blocks only `setup --name my_app`; a stale `.flutter_workspaces_cli.lock` blocks all add-package runs until removed.

To clear a stale lock — **only when no other run is actually in progress** — delete the exact file:

- `setup`: `.<folderName>.reserved` next to the target folder in the invocation directory (e.g. `.my_app_workspaces.reserved`).
- `add-package`: `.flutter_workspaces_cli.lock` in the workspace root (workspace-wide), and/or `packages/.<packageName>.reserved` in the workspace root (per package).

After removing the file, retry the command. If deletion is refused (e.g. another run is genuinely in progress, or files are missing), the release is skipped and the original error is still reported.

### Windows compatibility

The sentinel is an **ordinary file** created with `dart:io`'s exclusive create (`File.createSync(exclusive: true)` → `CreateFile` with `CREATE_NEW` on Windows, `open(O_CREAT | O_EXCL | O_WRONLY)` on POSIX). It needs **no elevated token and no Windows Developer Mode**: a standard, non-elevated Windows account can create it in a writable directory, so both `setup` and `add-package` run for an ordinary user. This replaces the previous sentinel *symlink* (`Link.createSync`), whose creation required `SeCreateSymbolicLinkPrivilege` and failed for a standard user without Developer Mode. The CI `Real-FS` job runs the real-filesystem suite — including the two-process race and stale-reservation recovery, on both `ubuntu-latest` and `windows-latest` — and is how the non-elevated Windows behavior is verified; macOS and Linux likewise need no extra privilege.

### Workspace-level serialization

- `add-package` is serialized workspace-wide by `.flutter_workspaces_cli.lock`: the workspace root can only have one add-package run in progress, and two concurrent invocations for the same `--name` also fail fast against the per-destination sentinel.
- `setup` is independent per folder name (no workspace-wide lock): two concurrent setups with different `--name` values never contend; same-name concurrent setups collide on the sentinel and exactly one wins.

### Best-effort cleanup

On normal completion both sentinels are deleted before the command returns; on failure the reserved directory is removed (scoped to the reservation this run made) and the sentinels are still released best-effort. A release failure is logged but never hides the run's original error. If a sentinel is left behind (crash, force-kill), it is a documented, recoverable leftover — remove the exact file above and retry.

## Releases

Releases are published to [pub.dev](https://pub.dev/packages/flutter_workspaces_cli) by the maintainer, using a verified, tag-driven flow. Ordinary branch and PR checks are read-only: they validate that `pubspec.yaml` and the first line of `CHANGELOG.md` agree, and never create a tag or publish.

### Tagging path

1. Bump the version in `pubspec.yaml` to the intended semver (e.g. `1.3.0`).
2. Update the first line of `CHANGELOG.md` to match the new version.
3. Confirm the PR's checks are green, then merge to `master`.
4. From a clean `master` checkout, the maintainer pushes the tag:

   ```bash
   git tag v1.3.0
   git push origin v1.3.0
   ```

   (use the actual version, e.g. `v1.3.0`)

### Expected Actions run

Pushing the tag triggers the `Publish to pub.dev` workflow (`.github/workflows/publish.yml`). It:

1. Reads the pushed tag, the `pubspec.yaml` version, and the first `CHANGELOG.md` version.
2. Verifies that the tag equals `v<pubspec version>` and that the pubspec version matches the changelog version — any mismatch fails the run before anything is published.
3. Runs the standard checks (`dart pub get --enforce-lockfile`, `dart format --set-exit-if-changed .`, `dart analyze`, `dart test`).
4. Runs `dart pub publish --dry-run` to confirm the package is publishable (no publication happens).
5. Publishes with `dart pub publish --force` — a non-interactive command, so it runs on the GitHub Actions runner with no stdin or terminal. The final step runs only after the tag/version verification, dependency resolution, formatting, analysis, tests, and the dry run all pass.

The workflow only runs when the maintainer pushes the tag — nothing is published before that push. The maintainer owns the release; this page documents the path.

### Retry behavior

- An existing tag does **not** re-trigger the workflow — do not silently re-push or delete an existing tag.
- If a run fails mid-way, re-run the failed job from the Actions UI (or `gh run rerun <run-id>`). Never silently re-push or force-push the tag.
- If the version in `pubspec.yaml` was wrong, fix it forward on a new commit and a new tag — do not reuse a pushed tag.

### Verification

There are two offline verification paths, both of which never publish a live version:

- **Dry run in the publish workflow.** `dart pub publish --dry-run` runs locally or in CI and confirms the package is publishable without publishing anything. Nothing is published before the maintainer pushes the tag — do not publish a live version as part of implementation.
- **Test-mode workflow.** `.github/workflows/publish-test.yml` is a manual, offline companion to the publish workflow (`workflow_dispatch`, contents-read only, no OIDC, never uploads). It runs the same gates in the same order as the publish workflow: dependency resolution, formatting, analysis, tests, and the dry run. To trigger it, open the repository's Actions tab → `Publish (offline test mode)` → Run workflow.

## Development

### Running Tests

Run the full local verification suite before opening a PR (the same commands CI runs):

```bash
dart pub get --enforce-lockfile   # or: dart pub get
dart format --set-exit-if-changed .
dart analyze
dart test
```

The test suite leverages the `FileSystem` and `ProcessRunner` abstractions to exercise the CLI without side effects on your local machine. Tests run against mocked filesystem and process runners — no coverage metric is claimed.

#### Dependency resolution

The package supports Dart `>= 3.11.5` (per `pubspec.yaml` `environment.sdk`). The committed `pubspec.lock` is the resolution contract: CI installs both the floor SDK (`3.11.5`) and the current stable (`3.14.0`) and resolves the CLI's own dependencies with `dart pub get --enforce-lockfile` (in both the check and smoke jobs), so the committed lockfile is expected to resolve at the floor — CI enforces it. The generated workspace does not share this lockfile: it is resolved with a plain `flutter pub get` against its own generated `pubspec.lock`. If `--enforce-lockfile` fails locally, run `dart pub get`, review the change, and commit the updated lockfile along with your PR.

#### Local smoke replication

The CI `smoke` job scaffolds a workspace with the real CLI, then analyzes and tests the generated app, core package, and an added package. The matrix runs the floor toolchain and the current stable on both Ubuntu and Windows: Flutter `3.44.0` (Dart 3.12.0, the minimum supported) and Flutter `3.50.1` (Dart 3.14.0, current stable). To replicate it locally in a clean directory:

```bash
rm -rf /tmp/issue17-smoke && mkdir -p /tmp/issue17-smoke && cd /tmp/issue17-smoke
dart /path/to/flutter_workspaces_cli/bin/flutter_workspaces_cli.dart setup --name smoke_app
cd /tmp/issue17-smoke/smoke_app_workspaces
flutter pub get
flutter analyze
cd smoke_app && flutter test && cd ..   # generated app
cd packages/core && flutter test && cd ../..   # core package
dart /path/to/flutter_workspaces_cli/bin/flutter_workspaces_cli.dart add-package --name smoke_feature
flutter pub get
cd packages/smoke_feature && flutter test
```

> `flutter test` must run from the app directory or the package directory — running it from the workspace root fails with `Test directory "test" not found`.

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Commit your changes (`git commit -am 'Add your feature'`)
4. Push to the branch (`git push origin feature/your-feature`)
5. Open a Pull Request

## License

This project is provided as-is. See [LICENSE](LICENSE) for details.

## Support

For issues, questions, or suggestions, please open an issue on the [GitHub repository](https://github.com/ThiagoEvoa/flutter_workspaces_cli/issues).

## Author

Created by [ThiagoEvoa](https://github.com/ThiagoEvoa)

---

**Enjoy building amazing Flutter workspaces!** 🚀
