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

When capturing real tool output for a parser test, add a scrubbed fixture under the relevant
`Tests/<Product>Tests/Fixtures/real/` directory and update its `README.md` with the source command
or tool and any redactions. Keep synthetic fixtures separate from real output.

To develop against an unpublished `cli-wrappers` checkout, place that checkout beside this one and
run `swift package edit cli-wrappers --path ../cli-wrappers`. Do not commit generated dependency
state. Run `swift package unedit cli-wrappers` to return to the declared remote dependency.

Releases are bare SemVer tags (`0.1.0`, no `v`). Pushing a tag publishes a GitHub Release with
generated notes; there is no `CHANGELOG.md`.

Report security issues privately as described in [`SECURITY.md`](.github/SECURITY.md).
