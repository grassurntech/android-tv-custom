# cleanyourtv (upstream)

> **Purpose:** The upstream launcher and tools we build on, the pinned version, and the rule for moving the pin.
>
> **Last updated:** 2026-11-19

Source: <https://github.com/Gathin23/cleanyourtv> (MIT). The pin lives in [config/upstream.env](../../config/upstream.env):

- Tag: `v3.5.0`
- Commit: `d11bd68c9ac45b2fb38480941586d17930137e9d` (`fetch-tools` refuses a copy that doesn't match, exit 30)
- Launcher package: `com.gathin.tvhome`

**Upstream files we rely on** (fetched into git-ignored `vendor/cleanyourtv/`):
- `tools/docker-build.*` and `launcher/build-and-install.*` (build and install the APK)
- `tools/theme.*` and `themes/README.md` (theme format and push)
- `examples/` (example themes)
- `docs/devices/` and `docs/TROUBLESHOOTING.md` (device notes)

**Rule:** the pin moves only after the new version has been tested on a real TV. Update the tag and commit together.
