# SameDesk task runner — https://github.com/casey/just
#
#   just            # list recipes
#   just build      # compile (release)
#   just run        # build & run from the terminal
#   just install    # copy the binary (+ its resource bundle) onto your PATH
#
# Override the build config or install location per-invocation:
#   just config=debug run
#   just prefix=/usr/local/bin install

config := "release"
prefix := "~/.local/bin"

bin := ".build" / config / "SameDesk"
bundle := ".build" / config / "SameDesk_SameDesk.bundle"

# List available recipes.
default:
    @just --list

# Compile the SameDesk executable.
build:
    swift build -c {{config}}

# Build and run from the terminal (Ctrl-C to quit). Grants prompt on first launch.
run *ARGS:
    swift run -c {{config}} SameDesk {{ARGS}}

# Install the binary + its resource bundle into {{prefix}} (must be on $PATH).
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    # SameDesk loads client.html/client.js from SameDesk_SameDesk.bundle next to
    # the executable, so the binary and its bundle are copied together.
    dest="{{prefix}}"; dest="${dest/#\~/$HOME}"
    mkdir -p "$dest"
    cp -f "{{bin}}" "$dest/SameDesk"
    rm -rf "$dest/SameDesk_SameDesk.bundle"
    cp -R "{{bundle}}" "$dest/SameDesk_SameDesk.bundle"
    # Confirm the bundled client assets resolve from the new location.
    SAMEDESK_SELFTEST=1 "$dest/SameDesk"
    echo "Installed: $dest/SameDesk (+ resource bundle)"
    case ":$PATH:" in
      *":$dest:"*) ;;
      *) printf 'NOTE: %s is not on your PATH. Add it:\n  echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc\n' "$dest" "$dest" ;;
    esac

# Remove an installed binary + bundle from {{prefix}}.
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="{{prefix}}"; dest="${dest/#\~/$HOME}"
    rm -f "$dest/SameDesk"
    rm -rf "$dest/SameDesk_SameDesk.bundle"
    echo "Removed SameDesk from $dest"

# Run the Swift unit tests.
test:
    swift test

# Run the browser smoke tests (first time: cd Tests/browser && npm install && npm run setup).
test-browser:
    cd Tests/browser && npm test

# Apply SwiftFormat.
fmt:
    swiftformat .

# Check formatting + lint strictly (what CI enforces).
lint:
    swiftformat --lint .
    swiftlint lint --strict

# Assemble a signed dist/SameDesk.app bundle.
app:
    ./scripts/make-app.sh

# Remove build artifacts.
clean:
    swift package clean
    rm -rf .build/{{config}}/SameDesk dist
