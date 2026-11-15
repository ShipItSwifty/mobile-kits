# Running tests and reading results

Test runners return a ``TestExecution``. Inspect its status and parsed run; failing tests remain
in the run, while ``TestExecutionFailure`` means the tool produced no usable test outcomes.

```swift
let execution = try await GradleTestRunner().run(
    task: .unitTest(variant: "debug"),
    in: GradleProject(directory: "/path/to/project")
)
print(execution.run.summary)
```

For an existing artifact, ``NativeResultReader`` detects the format from the path where possible.
Pass `format` and, for ambiguous JUnit files, `runner` when detection is not enough:

```swift
let run = try await NativeResultReader().read(
    "build/test-results/test",
    format: .junit,
    runner: .gradle
)
```

An `.xcresult` requires macOS and Xcode. JUnit, Jest, Flutter machine output, and Swift Testing
event files can be read from either supported host when their files are available.

## Topics

- ``TestExecution``
- ``TestExecutionFailure``
- ``NativeResultReader``
- ``ParsedTestRun``
- ``TestSummary``
