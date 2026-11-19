# Frontend

> **Purpose:** UI architecture, component conventions, TV/remote-navigation (focus) rules, and performance budgets.
>
> **Last updated:** 2026-11-19

We write no UI code. The home screen is the cleanyourtv launcher (see [references/cleanyourtv.md](references/cleanyourtv.md)); we supply a **theme** only.

- **Theme:** `themes/template/config.json` (placeholder name and apps). `make_theme.py` sets `greeting_name`, `dock_apps` (4 packages) and `clock_format` (`"12"` or `"24"`); `columns` is 4.
- **Wallpapers:** 1920×1080 JPEG, under 300 KB each, EXIF stripped.
- **Remote:** the launcher handles focus. Down from the dock opens the full app list. App-button remapping is untested on our TV.
- **RAM budget:** these TVs have about 1 GB. Keep the theme light: no video, no blur, no network polling.
