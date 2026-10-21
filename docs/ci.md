---
read_when: Updating GitHub Actions workflows, runner images, or dependency caching.
---

# Continuous integration

Both workflows pin `ubuntu-24.04` to avoid automatic operating-system migrations.
Review toolchain compatibility before changing this runner label.

Checkout v6 and setup-node v6 use the Node 24 action runtime. The lint job separately
installs Node 22 for project tooling. setup-node manages the Yarn package cache,
keyed by `yarn.lock`; installation still uses `yarn --frozen-lockfile`.
No custom cache-directory output or standalone cache action is needed.
