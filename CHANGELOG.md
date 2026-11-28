# 2.0.0

## Compatibility

- Workspace generation now requires Flutter 3.44.0 or later with Dart 3.12.0 or later. Installing the CLI itself still requires Dart 3.11.5 or later.
- For Dart callers using the exported scaffolding helpers, `WorkspaceProcess.createWorkspaceFolderSync` now returns a reservation that the caller releases, and `CommonProcess.revertAllProcesses` accepts the reserved directory.

## Changes

- Added an explicit `setup` command and command-specific help. Invalid input, including reserved package names and `core` as an app name, fails before scaffolding.
- Protected existing workspaces and packages from overwrites. `setup` and `add-package` coordinate through an atomic file reservation on macOS, Linux, and Windows. Failed operations roll back their own changes and report the underlying Flutter or filesystem error.
- Detects the Dart SDK bundled with Flutter and generates manifests for that toolchain. The generated app, core package, and added packages include working test dependencies and templates.
- Preserves comments, quoting, line endings, and list indentation when adding workspace members. When an edit would change a YAML list shared with another field, the CLI asks you to give `workspace` its own list.
- Added CI coverage for formatting, analysis, real-filesystem reservations, and Flutter scaffolding on Linux and Windows.

# 1.2.1

Adding validation to Dart 3.11+ to use the new pubspec.yaml workspace syntax.

# 1.2.0

New Feature: Added add-package command to create new packages within an existing workspace.
Architectural Refactor: Implemented Dependency Injection (DI) with FileSystem and ProcessRunner abstractions, improving testability and adhering to SOLID principles.
Improved Testability: Migration to 100% unit testing using MemoryFileSystem and mock processes.
New Runners: Introduced SetupRunner and AddPackageRunner for better separation of concerns.
Generalized Package Creation: Refactored package creation logic into a reusable PackageProcess service.
Documentation: Updated READMEs and examples to reflect new command and architecture.

# 1.1.2

Updating folder structure example.

# 1.1.1

Adding changelog validation.

# 1.1.0

Improving the files generation.

# 1.0.3

Adding example file, updating pubspec.yaml project description and updating changelog file.

# 1.0.2

Fixing an issue where the main flutter app project was being generated at the wrong path.

# 1.0.1

Adding GitHub action to automate the publish process.

# 1.0.0

First commit of the project.
