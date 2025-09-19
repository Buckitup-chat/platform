Gist: USB drive detection, management, and operational decision-making.

## Purpose

The USB Drives module handles the complete lifecycle of USB drives connected to the system:

1. **Detection**: Monitors device changes in the `/dev/` directory to detect when USB drives are inserted or removed.
2. **Drive Management**: Manages the lifecycle of connected drives including initialization and termination.
3. **Decision Making**: Determines the appropriate scenario for each drive based on its contents and system settings.

## Components

- **Detector**: Provides mechanisms for detecting drive insertion and removal events.
  - **Polling**: Monitors for drive changes
  - **State**: Manages the state of connected drives
  - **Watcher**: GenServer implementation that watches for device changes

- **Drive**: Utility functions for drive registry management and termination.

- **Decider**: Analyzes drive contents to determine its purpose and appropriate handling scenario (backup, cargo sync, onliners sync, etc.).

## Key Features

- Dynamic drive detection and automatic handling
- Support for various drive scenarios (backup, main DB, cargo sync, etc.)
- Filesystem optimization for blank drives when configured
- Integration with the platform's indication system for user feedback

## Integration Points

This module integrates with various platform subsystems:
- Platform.App.Drive.* supervisors for different drive functions
- Platform.Storage.DriveIndication for user feedback
- Chat.Admin modules for configuration settings
