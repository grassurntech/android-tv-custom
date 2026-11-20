# Frontend

> **Purpose:** UI architecture, component conventions, TV/remote-navigation (focus) rules, and performance budgets.
>
> **Last updated:** 2026-11-19

We write no UI code. The home screen is the cleanyourtv launcher (see [references/cleanyourtv.md](references/cleanyourtv.md)); we supply a **theme** only.

- **Theme:** `themes/template/config.json` (placeholder name and apps). `make_theme.py` rebuilds `config.json` from it on every run (never edited by hand), so a re-run must repeat every flag:

  | Flag | Config key | Rule |
  |---|---|---|
  | `--name` | `greeting_name` | 1 to 40 visible characters; no control, direction or line-separator characters |
  | `--apps p1,p2,p3,p4` | `dock_apps` | exactly 4 different packages |
  | `--clock 12\|24` | `clock_format` | |
  | `--stock-home-redirect PKG` | `stock_home_redirect` | not protected, not `com.gathin.tvhome` |
  | `--app-key KEYCODE:PKG` (repeatable) | `app_keys` | not Back, Home, Power, D-pad centre, Enter or Menu (names, numbers or scan codes); one key, one app |
  | `--live-tv-package PKG` | `live_tv_package` | |
  | `--power-on home\|live-tv` | `power_on_home` or `boot_to_live_tv` | `live-tv` needs `--live-tv-package` |
  | `--key-filter true\|false` | `key_filter` | `false` with `--app-key` warns |

  No package anywhere may match `config/forbidden-packages.txt` (exit 2; an unreadable list is exit 3). `--out` must not overlap `--photos`, be a symlink, or sit in the repo un-ignored (use `user-content/theme`); an existing non-empty `--out` must carry the `.made-by-make_theme` marker, and only its `NN.jpg` files are ever deleted. `make_theme.py --check-theme DIR` is the check `push-theme` runs before sending (valid `config.json`, at least one `wallpapers/*.jpg`, no forbidden package).
- **Wallpapers:** 1920×1080 JPEG, under 300 KB each, all metadata stripped (EXIF/GPS, comments, ICC, XMP); transparency flattened onto black.
- **Remote:** the launcher handles focus. Down from the dock opens the full app list. App-button remapping is untested on our TV.
- **RAM budget:** these TVs have about 1 GB. Keep the theme light: no video, no blur, no network polling.
