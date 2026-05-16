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
