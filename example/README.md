# Flutter Workspaces CLI Example

This example demonstrates how to use the `flutter_workspaces_cli` to scaffold a new monorepo project and manage it.

## 1. Installation

First, install the CLI globally using Dart:

```bash
dart pub global activate flutter_workspaces_cli
```

## 2. Create a Workspace

Run the CLI with the `--name` argument to generate your workspace. For this example, we'll create a project named `my_demo_app`.

```bash
flutter_workspaces_cli --name my_demo_app
```

## 3. Resulting Structure

The command creates a folder named `my_demo_app_workspaces` with the following structure:

```text
my_demo_app_workspaces/
├── pubspec.yaml              # Root workspace pubspec
├── analysis_options.yaml     # Root workspace analysis options
├── my_demo_app/                   # Main Flutter application
│   ├── lib/
│   │   └── main.dart        # Main entry point (imports core)
│   ├── pubspec.yaml
└── packages/
    └── core/                 # Shared core package
        ├── lib/
        │   └── core.dart
        └── pubspec.yaml
```

## 4. Adding a New Package

You can add more packages to your workspace using the `add-package` command:

```bash
cd my_demo_app_workspaces
flutter_workspaces_cli add-package --name shared_ui
```

This will create a new package in `packages/shared_ui`.

## 5. Running the Project

Navigate to the new workspace and run the app:

```bash
cd my_demo_app_workspaces
flutter pub get
cd my_demo_app
flutter run
```
