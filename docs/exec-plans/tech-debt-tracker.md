# Tech Debt Tracker

> **Purpose:** Running list of known shortcuts and debt: item, impact, owner, target fix.
>
> **Last updated:** 2026-11-18

| Item | Impact | Owner | Target fix |
|---|---|---|---|
| `config/protected-packages.txt` and `forbidden-packages.txt` are seed lists from standard Android names, not yet verified on a real TCL TV | A TCL-specific core package could go unprotected, or a factory app could go unlisted | Maintainers | First on-device session: run `pm list packages` and `dumpsys package`, add the TCL names |
