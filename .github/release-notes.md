Fixes unexpected loss of manual fan control during normal use and improves temperature and power readings.

- Sends control heartbeats independently of sensor sampling, so slow monitoring reads no longer delay renewal of the helper's eight-second control lease.
- Prevents App Nap while manual fan control is active, while still allowing system sleep. Sleep, quit, and genuine control failures continue to return fans to automatic control.
- Uses fresh HID temperature readings for fan control, including sensors with hashed identities.
- Prefers valid AppleCLPC power readings over Energy Model counters on supported macOS versions and drivers, preserving saved sensor selections when the source changes. CLPC ANE remains hidden by default pending load validation.
- Handles Ultra CPU power totals without double-counting overlapping package, die, and cluster counters.

Download `arm64` for Apple Silicon or `x86_64` for Intel. Both architectures include a drag-to-Applications DMG, a ZIP, and SHA-256 checksums. Requires macOS 13 or later.

After replacing the old app, quit the old process and authorize the helper update when prompted. The helper's signature binding must match the new app.

Apps are ad-hoc signed and not notarized. M6 telemetry validation does not establish hardware accuracy on every supported driver; other hardware models and sleep/crash recovery still need real-hardware validation.

See the README and `docs/COMPATIBILITY.md` for setup and hardware limitations.
