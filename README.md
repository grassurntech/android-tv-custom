# android-tv-custom

An open-source way to take back your Android TV: switch off the ads and preinstalled junk, and replace the home screen with your own photos, a small clock, your name and your four favourite apps.

> **Status:** early design. Nothing to install yet.

## What it will do
- **Remove the junk and ads.** Disable ad services and bloatware from your computer over your home Wi-Fi. Every step can be undone.
- **Give you your own home screen.** Your photos as the background, plus a clock, your name and four app shortcuts. Nothing else.

## Fork it, run it, change it
This project is built for forking. Your photos, name and TV details live only in your local `.env` and content folders, which git ignores, so your fork never exposes them.

```bash
git clone https://github.com/<you>/android-tv-custom.git
cd android-tv-custom
cp .env.example .env        # then fill in your own values
git config core.hooksPath scripts/hooks   # turns on the secret guardrail
```

Setup steps will appear here once the first version is built.

## Contributing & security
- [CONTRIBUTING.md](CONTRIBUTING.md): how to propose changes
- [docs/SECURITY.md](docs/SECURITY.md): secrets policy and how to report a vulnerability

## License
[MIT](LICENSE). Use it, fork it, change it, share it. Just keep the copyright notice.

## Disclaimer
This is an independent community project. It is not affiliated with or endorsed by TCL, Google or any TV manufacturer. Changing system apps on your TV is at your own risk. Always keep the restore steps handy.
