# dsaad68/homebrew-tap

Homebrew tap for [SameDesk](https://github.com/dsaad68/SameDesk) — a LAN-only
remote desktop you reach from a web browser.

## Install

```sh
brew install --cask dsaad68/tap/samedesk
```

Or tap first, then install:

```sh
brew tap dsaad68/tap
brew install --cask samedesk
```

SameDesk is a menu-bar app (no Dock icon). On first launch grant it **Screen
Recording** and **Accessibility** in System Settings → Privacy & Security.

> The build is ad-hoc signed (not notarized). The cask clears the quarantine
> flag automatically; if macOS still blocks it, right-click the app → Open once.

## Upgrade / uninstall

```sh
brew upgrade --cask samedesk
brew uninstall --cask samedesk          # add --zap to also remove app data
```

## How updates work

`Casks/samedesk.rb` is kept current automatically by
[`.github/workflows/update-cask.yml`](.github/workflows/update-cask.yml):

- SameDesk's release workflow fires a `repository_dispatch` (`samedesk-release`)
  carrying the new version + sha256 — the cask updates within seconds.
- A daily `schedule` is a safety net if a dispatch is ever missed.
- `workflow_dispatch` lets you update manually (optionally pinning a version).

Requires macOS 14 (Sonoma) or newer on Apple Silicon.
