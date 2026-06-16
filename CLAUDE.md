## Linting & Formatting

After every code change, run SwiftFormat then SwiftLint from the repo root and resolve anything they flag before considering the task done:

```sh
swiftformat .          # apply formatting (or `swiftformat --lint .` to check only)
swiftlint lint --strict
```

Configs live at `.swiftformat` and `.swiftlint.yml`, and are reconciled so the two tools don't fight (e.g. no trailing commas, braces on the same line). The SwiftFormat pass is deliberately conservative — it preserves the codebase's concise one-liner style and leaves signatures/concurrency annotations alone. For SwiftLint, use `swiftlint --fix` for the mechanical rules, then fix the rest by hand. The tree should stay clean under `--strict` (warnings treated as errors).