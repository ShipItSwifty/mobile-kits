import Foundation
import GradleKit

/// Selects cached artifacts only for the module and variant the requested tasks build.
struct GradleOutputSelection {
    let tasks: [GradleTask]
    let module: String
    let root: String

    func includes(_ file: URL, fresh: Bool) -> Bool {
        guard !tasks.isEmpty else { return fresh }
        return tasks.contains { task in
            let parts = task.name.split(separator: ":").map(String.init)
            guard let name = parts.last else { return false }
            if parts.count > 1 {
                let requested = URL(fileURLWithPath: root).appendingPathComponent(parts.dropLast().joined(separator: "/"))
                    .standardizedFileURL.path
                guard requested == module else { return false }
            }
            if name == "build" || name == "assemble" { return true }
            let isAPK = file.lastPathComponent == "output-metadata.json"
            if isAPK, file.path.contains("/androidTest/"), !name.hasSuffix("AndroidTest") { return false }
            let prefix = isAPK ? "assemble" : "bundle"
            guard name.hasPrefix(prefix) else {
                return name.hasPrefix("assemble") || name.hasPrefix("bundle") ? false : fresh
            }
            var variant = String(name.dropFirst(prefix.count))
            if variant.hasSuffix("AndroidTest") { variant = String(variant.dropLast("AndroidTest".count)) }
            guard !variant.isEmpty else { return true }
            let actual: String
            if isAPK, let data = try? Data(contentsOf: file),
                let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let recorded = metadata["variantName"] as? String
            {
                actual = recorded
            } else {
                // Older APK metadata omits variantName; its path is apk/<flavor>/<buildType>.
                let marker = isAPK ? "/build/outputs/apk/" : "/build/outputs/bundle/"
                guard let range = file.path.range(of: marker) else { return false }
                actual = file.path[range.upperBound...].split(separator: "/").dropLast()
                    .filter { $0 != "androidTest" }.joined()
            }
            let normalized = actual.hasSuffix("AndroidTest") ? String(actual.dropLast("AndroidTest".count)) : actual
            return normalized.lowercased() == variant.lowercased()
        }
    }
}
