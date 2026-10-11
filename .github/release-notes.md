Native macOS fan control and hardware monitoring with live sensor readings, fan curves, presets, and menu bar status.

- Expands Apple Silicon and Intel compatibility: selects the sensor database using hardware identity, including Rosetta, and adds explicitly inferred CPU/GPU groups where Apple Silicon mappings are missing.
- Adds capability-based `Ftst` unlock for firmware that rejects manual fan mode with `0x82`, with bounded retries and coordinated recovery across multiple fans.
- Correctly treats firmware mode 3 as system control, verifies mode and target writes, and tolerates target rounding within 1 RPM.
- Persists fan and unlock ownership so a restarted helper can recover control left behind by a previous process before accepting new requests.
- Includes the latest SMC recovery hardening from `1567390`, with fresh builds for both architectures. Sensor reads and the GUI have been tested on Mac mini M6 (`Mac18,5`); other models and real fan-control behavior still need hardware validation. Fanless models provide monitoring only.
- Includes DMG drag-to-Applications installers and ZIP downloads.
- Download `arm64` for Apple Silicon or `x86_64` for Intel. Requires macOS 13 or later.
- Both builds pass automated tests and code-signature verification in CI. Intel hardware compatibility, privileged helper installation, real fan-speed writes, and sleep recovery still need hardware validation.
- Apps are ad-hoc signed and not notarized. macOS may require approval in Privacy & Security before opening.
- SHA-256 checksum files are included with each DMG and ZIP. After replacing an older build, authorize the helper update when prompted so its signature binding matches the new app.

See the README for helper setup, usage, and hardware limitations.
