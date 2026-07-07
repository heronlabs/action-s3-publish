<!-- supera:guardrails -->
## Working with this repo (managed by /init — edits between these markers are overwritten on re-init)

- **Edit, don't rewrite.** Change only the needed entry in a config/generated file (`package.json`, lockfiles, manifests, CI yaml); preserve the rest. Never regenerate a whole file to add one line.
- **No scope creep.** Build only what was asked; no speculative abstractions, layers, or options. Prefer the simplest working solution.
- **Ambiguous literals: flag, don't guess.** Config keys, IDs, and env names can be literal values, not mappings. State which reading you took.
- **Scope a change to where it belongs** — most changes are localized to one area; touch other repos only when the change genuinely cuts across, and then update the related repos too.
<!-- /supera:guardrails -->

## Stack
- **Runtime**: Bash (composite GitHub Action)
- **Test framework**: [BATS](https://github.com/bats-core/bats-core) — `tests/action.bats`
- **Linter**: [shellcheck](https://www.shellcheck.net/) — all shell scripts + test files
- **Entry point**: `core/publish.sh` — invoked by `action.yml` composite step

## Commands
| Command | Description |
|---------|-------------|
| `make test` | Run BATS tests |
| `make lint` | Run shellcheck on all shell scripts |

## Key files
| File | Purpose |
|------|---------|
| `action.yml` | Composite action definition (inputs, outputs, steps) |
| `core/publish.sh` | S3 bucket sync script |
| `tests/action.bats` | BATS integration tests |
| `tests/__mocks__/aws` | AWS CLI stub (records invocations) |
| `Makefile` | Test + lint targets |
| `version.txt` | Current semver version |
| `CHANGELOG.md` | Release history |
