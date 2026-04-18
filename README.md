# OpenShift-LP-QE--Tools

Repository for OpenShift Layered Product Quality Engineering Tooling.

## Repository Structure
```
.
├── .AI_INIT.md                         # Main AI agent instructions.
├── AGENTS.md                           # Symbolic link to .AI_INIT.md for generic AI Agents.
├── CLAUDE.md                           # Symbolic link to .AI_INIT.md for Claude Code.
├── GEMINI.md                           # Symbolic link to .AI_INIT.md for Gemini CLI.
├── .continuerules                      # Symbolic link to .AI_INIT.md for Continue.dev.
├── .cursorrules                        # Symbolic link to .AI_INIT.md for Cursor IDE.
├── .AI_README.md                       # Project overview and guidelines (auto-generated).
├── .AI_HISTORY.md                      # Repository change log (auto-generated).
├── README.md                           # This file.
├── apps/                               # Application code.
│   └── <appName>/
│       ├── .AI_README.md               # App-specific AI instructions (optional).
│       ├── .AI_HISTORY.md              # App-specific change log.
│       ├── src/                        # Application source code.
│       ├── test/                       # Unit and/or integration tests (optional).
│       ├── docs/                       # App-specific documentation (optional).
│       └── README.md                   # Application documentation.
├── image/
│   └── container/                      # Container image definitions.
│       ├── <appName>/
│       │   ├── Dockerfile              # Application container image.
│       │   └── Makefile                # Build automation.
│       └── common/
│           └── Makefile.inc/           # Modular Makefile includes.
├── libs/                               # Shared libraries.
│   ├── bash/                           # Bash shell libraries.
│   └── python/                         # Python libraries.
└── tools/                              # Repository maintenance scripts.
```

## Directory Conventions
### `apps/`
Application code organized by application name. Each application is self-contained with its own source, tests, and documentation.

### `image/container/`
Container Image build definitions. Each application has a corresponding directory with its Dockerfile and Makefile.

Shared Makefile includes for common build patterns are in `common/Makefile.inc/`.

### `libs/`
Shared libraries that can be sourced or imported by multiple applications. Organized by programming or scripting language.

### `tools/`
Repository-level maintenance scripts for building, testing, linting, and releasing.

## AI Agent Instructions
This repository uses a unified AI agent instruction system:
- The `.AI_INIT.md` contains the main instructions.
- The AI Agent specific default files, e.g. `AGENTS.md`, `CLAUDE.md`, `.continuerules`, `.cursorrules`, etc., are symbolic links to `.AI_INIT.md`.
- Each application can have its own `.AI_README.md` for app-specific context.
- Change history is tracked in `.AI_HISTORY.md` files.

## Getting Started
### Building an Application
```bash
cd image/container/<appName>
make build
```

### Running Tests
```bash
cd apps/<appName>
# Run app-specific tests.
```

## Contributing
- Follow the directory structure conventions.
- Update `.AI_HISTORY.md` for significant changes.
- Ensure each application has proper documentation in its `README.md`.
- Use shared libraries in `libs/` when code is reused across applications.
- See [`CONTRIBUTING.md`](CONTRIBUTING.md) for contribution conventions and workflow details.
