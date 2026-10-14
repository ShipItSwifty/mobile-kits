# Contributing

1. Branch from `main` with a short descriptive name (`fix/simctl-boot-timeout`, `feat/bazel-coverage`).
2. Keep a pull request to one concern. Read [`AGENTS.md`](AGENTS.md) for the layout and rules.
3. Before pushing:

   ```bash
   swift build
   swift test
   swift format lint --recursive --strict --configuration .swift-format Sources Tests Package.swift
   ```

CI builds and tests on macOS and on Linux with the oldest supported Swift (6.2) and the latest,
and builds the DocC site on every pull request.

Releases are bare SemVer tags (`0.1.0`, no `v`). Pushing a tag publishes a GitHub Release with
generated notes; there is no `CHANGELOG.md`.

Report security issues privately as described in [`SECURITY.md`](.github/SECURITY.md).
