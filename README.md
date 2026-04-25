# ProcMonitor

A Windows process monitoring utility written in Zig that monitors specified processes and executes configurable actions when they start.

## Features

- **Process Monitoring**: Monitor specific processes with configurable check intervals
- **Action Execution**: Automatically close or start processes when monitored processes are detected
- **Daemon Mode**: Run as a background Windows service
- **TOML Configuration**: Simple and flexible configuration file format
- **Log Rotation**: Built-in logging with file rotation support

## Use Cases

- Automatically close proxy applications when game launchers start
- Clean up background processes when specific applications launch
- Automate process management workflows

## Requirements

- Windows operating system
- Zig 0.16.0 or later

## Building

```bash
git clone <repository-url>
cd proc_monitor
zig build
```

The executable will be available at `zig-out/bin/proc_monitor.exe`.

## Usage

```
proc_monitor - Process Monitor System v0.1.0

USAGE:
    proc_monitor [OPTIONS]

OPTIONS:
    -c, --config <PATH>    Configuration file path (default: config.toml)
    -d, --daemon           Run as background daemon
    -o, --once             Run check once and exit
    -h, --help             Show this help message
    -v, --version          Show version information

EXAMPLES:
    proc_monitor -c myconfig.toml
    proc_monitor --daemon
    proc_monitor --once
```

## Configuration

Create a `config.toml` file with the following structure:

```toml
[log]
level = "info"                    # Log level: debug, info, warn, error
file_path = "logs/proc_monitor.log"
console = true                    # Output to console
max_size_mb = 10                  # Max log file size before rotation
max_files = 5                     # Number of rotated log files to keep

daemon = false                    # Run as daemon (can be overridden with -d flag)
pid_file = "proc_monitor.pid"     # PID file path for daemon mode

[[monitor.process]]
monitored = "steam.exe"           # Process name to monitor
action = { "clash-verge.exe" = "close" }  # Action: close or start
check_interval = 10               # Check interval in seconds

[[monitor.process]]
monitored = "EpicGamesLauncher.exe"
action = { "helper.exe" = "start" }
check_interval = 10
```

### Action Types

| Action | Description |
|--------|-------------|
| `close` | Terminate the specified process when the monitored process starts |
| `start` | Launch the specified process when the monitored process starts |

### Multiple Actions

You can specify multiple actions for a single monitored process:

```toml
[[monitor.process]]
monitored = "steam.exe"
action = { "clash-verge.exe" = "close", "ShadowsocksR.exe" = "close" }
check_interval = 10
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Entry Layer                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    main.zig                          │   │
│  │              CLI & Orchestration                      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        Core Layer                           │
│  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐  │
│  │process_monitor │ │process_handler │ │    daemon      │  │
│  │     .zig       │ │     .zig       │ │     .zig       │  │
│  │   Monitoring   │ │ Windows API    │ │ Daemonization  │  │
│  │    Logic       │ │  Integration   │ │                │  │
│  └────────────────┘ └────────────────┘ └────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Infrastructure Layer                      │
│  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐  │
│  │    config      │ │    logger      │ │     utils      │  │
│  │     .zig       │ │     .zig       │ │     .zig       │  │
│  │     TOML       │ │   Logging &    │ │     Path       │  │
│  │ Configuration  │ │   Rotation     │ │   Utilities    │  │
│  └────────────────┘ └────────────────┘ └────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Module Responsibilities

| Module | Responsibility |
|--------|---------------|
| `main.zig` | Entry point, CLI parsing, initialization |
| `config.zig` | TOML configuration parsing |
| `daemon.zig` | Windows daemon process management |
| `logger.zig` | Thread-safe logging with rotation |
| `process_handler.zig` | Windows process enumeration and control |
| `process_monitor.zig` | Core monitoring state machine |
| `utils.zig` | Path resolution utilities |

## How It Works

1. **Startup**: Parse CLI arguments and load configuration
2. **Initialization**: Set up logging and optionally daemonize
3. **Monitoring Loop**:
   - Enumerate all running processes
   - Check if any monitored processes are running
   - Execute configured actions when a monitored process is detected
   - Sleep for the configured interval
4. **Action Execution**:
   - `close`: Find and terminate the target process
   - `start`: Launch the specified executable

## Development

### Project Structure

```
proc_monitor/
├── build.zig           # Build configuration
├── build.zig.zon       # Project manifest and dependencies
├── config.toml         # Default configuration file
├── ProcMonitor-Info.md # Detailed technical documentation
└── src/
    ├── main.zig            # Entry point
    ├── config.zig          # Configuration parsing
    ├── daemon.zig          # Daemon functionality
    ├── logger.zig          # Logging system
    ├── process_handler.zig # Windows process API
    ├── process_monitor.zig # Monitoring logic
    └── utils.zig           # Utility functions
```

### Running Tests

```bash
zig build test
```

### Building for Release

```bash
zig build -Doptimize=ReleaseFast
```

