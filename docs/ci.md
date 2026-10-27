---
read_when: Committing changes, fixing formatting failures, or updating CI tooling.
---

# Continuous integration

Both workflows pin `ubuntu-24.04` to avoid automatic operating-system migrations.
Review toolchain compatibility before changing this runner label.

Checkout v6 and setup-node v6 use the Node 24 action runtime. The lint job separately
installs Node 22 for project tooling. setup-node manages the Yarn package cache,
keyed by `yarn.lock`; installation still uses `yarn --frozen-lockfile`.
No custom cache-directory output or standalone cache action is needed.

## Local formatting and pre-commit hook

CI uses Prettier through `yarn format:check`, not `forge fmt` or Solhint.
Run `yarn --frozen-lockfile`, then `yarn hooks:install` once per clone to enable
`.githooks/pre-commit`. The Git hook path setting applies to linked worktrees too.
This replaces any existing `core.hooksPath`; integrate existing hooks first if needed.

The hook exports the full staged snapshot and runs the same `yarn format:check`
command as CI, using the installed dependencies. It checks staged configuration
and all files in CI's formatting scope, without modifying or staging files and
without stashing unrelated work. A failure blocks the commit. Run `yarn format`,
review changes and stage the intended fixes before retrying. For partially staged
files, use selective staging so unrelated edits stay out of the commit.

Keep dependencies synchronized with `yarn.lock` using `yarn --frozen-lockfile`;
CI uses Node 22. Hooks require Git, Yarn and the installed project dependencies.
To disable this hook path, run `git config --unset core.hooksPath` (or restore
its previous value). Hooks are local safeguards; CI remains required.
