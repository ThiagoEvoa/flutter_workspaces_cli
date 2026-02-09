# Flutter Workspaces CLI

A command-line tool for scaffolding and managing monorepo-style Flutter workspace structures. This CLI automates the creation of a complete Flutter workspace with a core shared package, main application, and proper dependency configuration.

## Features

- ✅ **Workspace Creation**: Automatically creates a `<name>_workspaces` folder and sets up the workspace structure.
- 📦 **Core Package Scaffolding**: Creates a reusable `packages/core` package for shared code.
- 📱 **Flutter App Scaffolding**: Generates a main Flutter application that imports and uses the core package.
- 🎯 **Workspace Resolution**: Configures `pubspec.yaml` files with workspace resolution for monorepo support.
- 🔍 **Environment Validation**: Checks for Flutter and Dart SDK requirements (Dart 3.6.0+).
- 📋 **Dependency Management**: Automatically adds common Flutter dependencies (cupertino_icons, flutter_lints, custom_lint).
- 🧹 **Error Handling**: Reverts workspace creation on failure for clean error states.

## Requirements

- **Dart SDK**: 3.6.0 or higher
- **Flutter SDK**: Latest stable version (with Dart 3.6.0+)
- **System**: macOS, Linux, or Windows with shell support

## Installation

```bash
dart pub global activate flutter_workspaces_cli
```

## Usage

Run the CLI with the required `--name` argument to create a new workspace:

```bash
flutter_workspaces_cli.dart --name my_app
```

Or use the short flag:

```bash
flutter_workspaces_cli.dart -n my_app
```

### What Gets Created

After running the command, the following structure is created:

```
my_app_workspaces/
├── pubspec.yaml              # Root workspace pubspec
├── my_app/                   # Main Flutter application
│   ├── lib/
│   │   └── main.dart        # Main entry point (imports core)
│   ├── pubspec.yaml
│   └── analysis_options.yaml
└── packages/
    └── core/                 # Shared core package
        ├── lib/
        │   └── core.dart
        └── pubspec.yaml
```

The root `pubspec.yaml` includes workspace configuration that allows both the app and core package to be developed together with shared dependency resolution.

## Command-Line Arguments

| Argument | Short | Required | Description |
|----------|-------|----------|-------------|
| `--name` | `-n` | Yes | The base name for your workspace and app (e.g., `my_app`) |

### Example

```bash
flutter_workspaces_cli.dart --name flutter_monorepo
```

This creates a workspace named `flutter_monorepo_workspaces` with all required structure and dependencies.

## Exit Codes

- `0`: Success
- `1`: General error (execution failed)
- `64`: Missing or invalid arguments (e.g., `--name` not provided)

## Error Handling

If the CLI encounters an error during workspace creation:

1. **Missing `--name` argument**: Prints usage help and exits with code 64 (no workspace created).
2. **Other errors**: Reverts the workspace if it was partially created and exits with code 1.

## Development

### Running Tests

Run the test suite to verify all functionality:

```bash
dart test
```

The test suite includes:
- Project name parsing and validation
- Dart version detection and validation
- Flutter installation checks
- Workspace and package file generation
- Pubspec configuration verification

### Project Structure

```
lib/
├── dart_process.dart           # Dart SDK detection & validation
├── project_name_process.dart   # CLI argument parsing
├── common_process.dart         # Shared utilities
├── core_package_process.dart   # Core package scaffolding
├── flutter_app_process.dart    # Flutter app scaffolding
├── flutter_process.dart        # Flutter SDK checks
└── workspace_process.dart      # Workspace creation & config

bin/
└── flutter_workspaces_cli.dart # Main entry point

test/
└── flutter_workspaces_cli_test.dart # Test suite
```

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
