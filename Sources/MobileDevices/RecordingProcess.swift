import SwiftyShell

/// A cancelled wait does not cancel the process's own task. Tear it down before draining the group.
enum RecordingProcess {
    static func waitForExit(_ process: any SpawnedProcess, timeout: Duration) async -> ShellOutput {
        await withTaskGroup(of: ShellOutput?.self) { group in
            group.addTask { await process.waitForExit() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            return await process.teardownAndWait()
        }
    }
}
