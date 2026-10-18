# Capability scout rejected candidates

## Graphify-Labs/graphify

The date is 2026-10-18.

The version and revision are v0.9.92 on branch v8 at commit 86c57be8.

The whole-repository finding is `DO_NOT_INSTALL` at `100/CRITICAL`.

The package-only finding is `DO_NOT_INSTALL` at `100/CRITICAL` with 85% coverage.

The shipped agent skill file finding is `DO_NOT_INSTALL` at `88/CRITICAL` with 100% coverage.

The reason for rejection is that the gate blocks `DO_NOT_INSTALL` candidates wholesale as files and its install path writes agent configs, so no file enters any store.
