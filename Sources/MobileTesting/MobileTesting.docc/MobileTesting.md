# MobileTesting

Runs native test tools and normalizes their outputs as ``ParsedTestRun``. A test failure is a
result, not an execution error; ``TestExecutionFailure`` is thrown when a runner produces no usable
results.

See <doc:RunningTests> for execution and offline parsing examples.

## Topics

### Running tests

- ``XcodeTestRunner``
- ``GradleTestRunner``
- ``SwiftPMTestRunner``
- ``FlutterTestRunner``
- ``JestTestRunner``
- ``BazelTestRunner``
- ``TestExecution``
- ``TestExecutionFailure``
- <doc:RunningTests>

### Reading results

- ``NativeResultReader``
- ``NativeResultFormat``
- ``ParsedTestRun``
- ``TestSummary``
- ``TestDestination``
- <doc:RunningTests>

### Format-specific parsers

- ``IOSXCResultTestParser``
- ``JUnitTestParser``
- ``FlutterMachineOutputParser``
- ``JestJSONTestParser``
- ``SwiftEventParser``
