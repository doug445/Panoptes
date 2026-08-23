# Rulesets

The branch and tag protection for this repository, as JSON rather than as
settings someone clicked once and cannot reproduce.

Apply or re-apply:

```bash
gh api --method POST repos/OWNER/REPO/rulesets --input .github/rulesets/branch-main.json
gh api --method POST repos/OWNER/REPO/rulesets --input .github/rulesets/tags-release.json
```

List what is live, and read one back:

```bash
gh api repos/OWNER/REPO/rulesets --jq '.[] | "\(.id)  \(.name)  [\(.target)]  \(.enforcement)"'
gh api repos/OWNER/REPO/rulesets/RULESET_ID --jq '.rules'
```

## What is enforced

**`branch-main.json`** — the default branch:

| Rule | Effect |
|---|---|
| `deletion` | `main` cannot be deleted |
| `non_fast_forward` | no force-pushing `main`; history cannot be rewritten |

**`tags-release.json`** — every tag matching `v*`:

| Rule | Effect |
|---|---|
| `deletion` | a published version tag cannot be removed |
| `update` | a version tag cannot be moved to another commit |
| `non_fast_forward` | no force-pushing a tag over an existing one |

Creating *new* `v*` tags is unaffected — that is the `creation` rule, which is
deliberately not enabled.

## What is deliberately not enforced

This is a small repository with direct pushes to `main`. Rules that assume a
pull-request workflow would break it for no gain:

- **`pull_request`** — would forbid pushing to `main` at all. Add it the moment a
  second contributor appears.
- **`required_status_checks`** — only evaluated when merging a pull request, so
  it does nothing here while also implying `pull_request`.
- **`required_signatures`** — commits here are not GPG-signed, so this would
  reject every push, including your own.
- **`required_linear_history`** — would block merge commits. Dependabot's grouped
  pull request merges cleanly by squash, but this rule turns an ordinary "Merge"
  click into a confusing failure.

## Bypass, and getting unstuck

`bypass_actors` is empty on purpose. With a bypass entry for repository admin
the rules would not bind you at all, and you are the only one pushing — the
guard exists precisely to catch a bad `--force` from you or from tooling.

Nothing is locked: as an admin you can set a ruleset to `disabled`, do the
thing, and set it back.

```bash
gh api --method PUT repos/OWNER/REPO/rulesets/RULESET_ID -f enforcement=disabled
# ... force-push ...
gh api --method PUT repos/OWNER/REPO/rulesets/RULESET_ID -f enforcement=active
```
