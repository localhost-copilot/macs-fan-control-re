Native macOS fan control and hardware monitoring with live sensor readings, fan curves, presets, and menu bar status.

- Supports M6 processors; sensor reads and the GUI have been tested on Mac mini M6 (`Mac18,5`).
- Download `arm64` for Apple Silicon or `x86_64` for Intel. Requires macOS 13 or later.
- Both builds pass automated tests and code-signature verification in CI. Intel hardware compatibility, privileged helper installation, real fan-speed writes, and sleep recovery still need hardware validation.
- Apps are ad-hoc signed and not notarized. macOS may require approval in Privacy & Security before opening.
- SHA-256 checksum files are included with each ZIP.

See the README for helper setup, usage, and hardware limitations.
