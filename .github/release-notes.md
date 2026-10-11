Fixes fan-control failures caused by delayed SMC mode and target readback, including automatic recovery on machines without an `Ftst` unlock key. The user confirmed fan control works on M4 Mac mini (`Mac16,10`) running macOS 27 after this fix.

- Adds bounded retries for mode and target writes while retaining readback verification and recovery on failure. Errors now include the requested and actual values.
- Allows more time for the helper to reply while hardware retries and recovery run.
- Restores the original app window to the foreground after administrator authorization succeeds, fails, or is cancelled.
- Removes obsolete documentation, sensor snapshots, and unused screenshots; consolidates current hardware validation status in the compatibility guide.

Download `arm64` for Apple Silicon or `x86_64` for Intel. Both architectures include a drag-to-Applications DMG, a ZIP, and SHA-256 checksums. Requires macOS 13 or later.

After replacing the old app, quit the old process and authorize the helper update when prompted. The helper's signature binding must match the new app.

Apps are ad-hoc signed and not notarized. Other hardware models and sleep/crash recovery still need real-hardware validation; the authorization-window change was checked with simulated AppKit window transitions, without replaying a real password prompt.

See the README and `docs/COMPATIBILITY.md` for setup and hardware limitations.
