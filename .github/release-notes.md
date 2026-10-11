Adds CPU/GPU power and maximum-temperature readings, and restores your last successfully applied fan settings after restarting or upgrading the app.

- Saves Custom settings without requiring a named preset and restores them after hardware discovery and validation. Choosing Automatic persists too; quit and safety recovery still release hardware control. Settings never saved by older versions must be configured once after this upgrade.
- Adds current CPU and GPU maximum temperatures for the main window, menu bar, and temperature-based fan control. These are current sensor maxima, not historical peaks.
- Reads component power using Energy Model aggregation rules, with AppleCLPC CPU/GPU/ANE fallback for known M1–M6 drivers on macOS 27.0 / 27.0.1. Existing Energy Model readings take precedence; unsupported channels are not fabricated. Power is calculated from system energy counters, not a direct wattmeter measurement. CLPC ANE remains hidden by default pending load validation.
- Uses load-verified CPU performance, CPU efficiency, and GPU temperature groups on Mac18,5 (M6). Other inferred sensor classifications are explained in tooltips instead of cluttering display names.
- Records M6 power and temperature validation in the compatibility guide, including CLPC GPU agreement with Energy Model within 0.5% at 10.8 W.

Download `arm64` for Apple Silicon or `x86_64` for Intel. Both architectures include a drag-to-Applications DMG, a ZIP, and SHA-256 checksums. Requires macOS 13 or later.

After replacing the old app, quit the old process and authorize the helper update when prompted. The helper's signature binding must match the new app.

Apps are ad-hoc signed and not notarized. M6 telemetry validation does not establish hardware accuracy on every supported driver; other hardware models and sleep/crash recovery still need real-hardware validation.

See the README and `docs/COMPATIBILITY.md` for setup and hardware limitations.
