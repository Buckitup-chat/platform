Gist: Wrappers of external tools

## Purpose

The Tools module provides wrappers and utilities for various system operations required by the BuckitUp platform:

1. **Filesystem Operations**: Tools for mounting, unmounting, and formatting storage devices.
2. **Partition Management**: Utilities for handling disk partitions.
3. **Database Operations**: PostgreSQL management tools for initialization and operation.
4. **System Diagnostics**: Tools for system checking and firmware updates.

## Key Components

- **Mount**: Wrapper for mounting/unmounting operations with device detection
- **Mkfs**: Filesystem creation and formatting
- **Fsck**: Filesystem checking and repair
- **PartEd**: Partition editing and management
- **Postgres**: PostgreSQL database management utilities
- **Fwup**: Firmware update tooling
- **Lsblk**: Block device listing utility

## Integration Points

- Integrates with Platform.UsbDrives for drive management
- Supports Platform.PgDb operations for database management
- Provides utilities for Platform storage management
- Used by system maintenance and diagnostics processes
