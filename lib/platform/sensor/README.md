Gist: Interface modules for physical sensor integration with the platform.

## Purpose

The Sensor module provides interfaces and utilities for interacting with physical sensors connected to the BuckitUp platform:

1. **Sensor Abstraction**: Creates a consistent interface to different sensor types
2. **Polling Mechanisms**: Tools for periodically reading sensor data
3. **Device Support**: Implementations for specific sensor hardware models

## Key Components

- **Weigh**: Modules for interfacing with weighing scales and sensors
  - Supports multiple sensor types (NCI, Balena D700)
  - Implements polling mechanisms to read sensor data
  - Provides protocol definitions for sensor communication

## Integration Points

- Used by platform applications requiring sensor data
- Abstracts hardware specifics from business logic
- Supports expandable sensor types through a factory pattern
