# Flutter Workspaces CLI

A command-line tool for scaffolding and managing monorepo-style Flutter workspace structures. This CLI automates the creation of a complete Flutter workspace with a core shared package, main application, and proper dependency configuration.

## Features

- ✅ **Workspace Creation**: Automatically creates a `<name>_workspaces` folder and sets up the workspace structure.
- 📦 **Core Package Scaffolding**: Creates a reusable `packages/core` package for shared code.
- ➕ **Add Package**: Easily add new packages to your existing workspace with a single command.
- 📱 **Flutter App Scaffolding**: Generates a main Flutter application that imports and uses the core package.
- 🎯 **Workspace Resolution**: Configures `pubspec.yaml` files with workspace resolution for monorepo support.
- 🔍 **Environment Validation**: Checks for Flutter and Dart SDK requirements (Dart 3.6.0+).
- 📋 **Dependency Management**: Automatically adds common Flutter dependencies (cupertino_icons, flutter_lints, custom_lint).
- 🧹 **Error Handling**: Reverts workspace creation on failure for clean error states.
- 🏗️ **SOLID Architecture**: Refactored to use Dependency Injection with `FileSystem` and `ProcessRunner` abstractions for better testability and maintainability.

## Requirements

- **Dart SDK**: 3.6.0 or higher
- **Flutter SDK**: Latest stable version (with Dart 3.6.0+)
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
│   ├── pubspec.yaml
└── packages/
    └── core/                 # Shared core package
        ├── lib/
        │   └── core.dart
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

- `0`: Success
- `1`: General error (execution failed)
- `64`: Missing or invalid arguments (e.g., `--name` not provided)

## Development

### Running Tests

Run the test suite to verify all functionality:

```bash
dart test
```

The test suite leverages the `FileSystem` and `ProcessRunner` abstractions to provide 100% coverage without side effects on your local machine.

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
