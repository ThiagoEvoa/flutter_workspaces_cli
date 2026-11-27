# Flutter Workspaces CLI

A command-line tool for scaffolding and managing monorepo-style Flutter workspace structures. This CLI automates the creation of a complete Flutter workspace with a core shared package, main application, and proper dependency configuration.

## Features

- ✅ **Workspace Creation**: Automatically creates a `<name>_workspaces` folder and sets up the workspace structure.
- 📦 **Core Package Scaffolding**: Creates a reusable `packages/core` package for shared code.
- ➕ **Add Package**: Easily add new packages to your existing workspace with a single command.
- 📱 **Flutter App Scaffolding**: Generates a main Flutter application that imports and uses the core package.
- 🎯 **Workspace Resolution**: Configures `pubspec.yaml` files with workspace resolution for monorepo support.
- 🔍 **Environment Validation**: Verifies that the Flutter toolchain on PATH bundles a supported Dart SDK (>= 3.6.0) and uses that same version for every generated manifest.
- 📋 **Dependency Management**: Automatically adds common Flutter dependencies (cupertino_icons, flutter_lints).
- 🧹 **Error Handling**: Reverts workspace creation on failure for clean error states.
- 🏗️ **SOLID Architecture**: Refactored to use Dependency Injection with `FileSystem` and `ProcessRunner` abstractions for better testability and maintainability.

## Requirements

Two different Dart requirements apply, and they are not the same:

- **CLI installation** (the `flutter_workspaces_cli` package itself): [Dart SDK](https://dart.dev/get-dart) `^3.11.5` (per this package's own `pubspec.yaml` `environment.sdk`) plus the [Flutter SDK](https://docs.flutter.dev/get-started/install) required to use the CLI.
- **Flutter toolchain used for generation** (the `flutter` executable on PATH that scaffolds and resolves the workspaces): must bundle a Dart SDK `>= 3.6.0`. The CLI detects that version (machine-readable `flutter --version --machine`, with a text-parse fallback) and serializes it into every generated manifest. Workspace glob syntax (`packages/*`) is emitted only when the bundled Dart SDK is `>= 3.11` (both the resolver and the generated workspace constraint support it); older toolchains generate explicit member lists (`packages/core`).
- **System**: macOS, Linux, or Windows with shell support

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
5. Publishes with `dart pub publish`.

The workflow only runs when the maintainer pushes the tag — nothing is published before that push. The maintainer owns the release; this page documents the path.

### Retry behavior

- An existing tag does **not** re-trigger the workflow — do not silently re-push or delete an existing tag.
- If a run fails mid-way, re-run the failed job from the Actions UI (or `gh run rerun <run-id>`). Never silently re-push or force-push the tag.
- If the version in `pubspec.yaml` was wrong, fix it forward on a new commit and a new tag — do not reuse a pushed tag.

### Verification

`dart pub publish --dry-run` (run locally or in CI) confirms the package is publishable without publishing anything. Do not publish a live version as part of implementation — the maintainer publishes later.

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

The CI `smoke` job scaffolds a workspace with the real CLI, then analyzes and tests the generated app, core package, and an added package. To replicate it locally in a clean directory:

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
