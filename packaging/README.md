# Packaging

How SameDesk is built into a distributable macOS app and Homebrew cask.

Nothing here is published yet — it's staged locally. Follow **Going live** when
you're ready to put it on Homebrew.

## What's here

| Path | Purpose |
|------|---------|
| `../scripts/make-app.sh` | Assembles `dist/SameDesk.app` from a SwiftPM build (Info.plist, `LSUIElement`, ad-hoc signature, asset self-test). Used by both local builds and CI. |
| `../.github/workflows/release.yml` | On a changelog version bump merged to `main`: builds the `.app`, zips it, publishes a GitHub Release, and (optionally) pings the tap. |
| `homebrew-tap/` | The exact contents of the future `dsaad68/homebrew-tap` repo: the cask + its self-update workflow + README. |

## The `.app`

SameDesk needs a real `.app` bundle (not a bare binary) so its **Screen
Recording / Accessibility** grants are tied to a stable bundle identity
(`io.github.dsaad68.SameDesk`) and survive upgrades. Browser assets ship flat in
`Contents/Resources`; `ClientAssets.candidateURLs` resolves them there (and from
the SwiftPM resource bundle when run as a bare binary), so it works in every
layout without `Bundle.module`.

Build and test it locally:

```sh
swift build -c release
./scripts/make-app.sh 1.1.0          # -> dist/SameDesk.app  (runs the self-test)
open dist/SameDesk.app               # launches the menu-bar app
```

Sign with a real identity instead of ad-hoc (recommended once you have one):

```sh
SAMEDESK_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/make-app.sh 1.1.0
```

## Test the cask locally (no publishing)

```sh
swift build -c release && ./scripts/make-app.sh 1.1.0
ditto -c -k --keepParent dist/SameDesk.app dist/SameDesk-macos-arm64.zip

# Point the cask at the local zip and install it:
shasum -a 256 dist/SameDesk-macos-arm64.zip          # paste into the cask's sha256
brew install --cask ./packaging/homebrew-tap/Casks/samedesk.rb   # after editing url to file://…/dist/SameDesk-macos-arm64.zip
brew audit  --cask ./packaging/homebrew-tap/Casks/samedesk.rb
brew style  ./packaging/homebrew-tap/Casks/samedesk.rb
```

(Revert the `url`/`sha256` edits before committing — the committed cask points at
the GitHub release and is kept in sync automatically.)

## Going live

1. **Cut the first `.app` release.** The current `v1.0.0` asset is the old bare
   binary. Add a `## [1.1.0]` entry to `CHANGELOG.md` and merge to `main`;
   `release.yml` builds the `.app` and publishes `v1.1.0` with
   `SameDesk-macos-arm64.zip`.
2. **Create the tap repo.** Make a public `dsaad68/homebrew-tap` and copy
   `packaging/homebrew-tap/` into its root:

   ```sh
   gh repo create dsaad68/homebrew-tap --public -d "Homebrew tap for SameDesk"
   # then push Casks/ + .github/ + README.md to it
   ```
3. **Wire instant updates (optional).** Create a PAT with `contents:write` on
   the tap repo and add it to the **SameDesk** repo as the `HOMEBREW_TAP_TOKEN`
   secret. Then every release auto-bumps the cask. Without it, the tap's daily
   `schedule` still picks up new releases within a day.
4. **Sync the cask once** (the tap's `update-cask.yml` does this automatically,
   or run it via `workflow_dispatch`).

Then it's live:

```sh
brew install --cask dsaad68/tap/samedesk
```

## Notes & limits

- **Apple Silicon only.** The release builds `arm64`. Add a universal build
  (`swift build --arch arm64 --arch x86_64`) + drop `depends_on arch: :arm64` if
  you want Intel support.
- **Not notarized.** Ad-hoc signing gives a stable identity for TCC but not
  Gatekeeper trust; the cask strips quarantine on install. For zero friction,
  sign with a Developer ID and notarize in CI.
- **No icon.** Drop an `Resources/AppIcon.icns` and `make-app.sh` will wire it
  into the bundle. (A menu-bar app shows no Dock icon, so it's cosmetic.)
