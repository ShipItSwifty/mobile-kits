import Foundation
import MobileCore

/// Decides an app directory's framework from its own files, without walking the repository.
///
/// Precedence (first match wins), checking the directory and its first-level module
/// directories only:
/// 1. `pubspec.yaml` with a top-level `flutter:` key → `.flutter`
/// 2. `package.json` depending on `react-native` → `.reactNative`
/// 3. a `build.gradle[.kts]` applying the Kotlin Multiplatform plugin, at the root or in a
///    first-level module, or `gradle/libs.versions.toml` declaring it (version-catalog projects
///    apply it through an alias) → `.kmp`
///
/// Returns `nil` when none match, meaning a native app. ``RepositoryInspector`` reports every
/// framework anywhere in a repository instead.
public enum FrameworkDetector {
    public static func detect(in directory: String, fileManager: FileManager = .default) -> AppFramework? {
        let root = URL(fileURLWithPath: directory)
        func read(_ path: String) -> String? {
            let url = root.appendingPathComponent(path)
            return fileManager.fileExists(atPath: url.path) ? try? String(contentsOf: url, encoding: .utf8) : nil
        }
        if let pubspec = read("pubspec.yaml"), pubspec.range(of: #"(?m)^flutter:"#, options: .regularExpression) != nil {
            return .flutter
        }
        if let data = read("package.json").map({ Data($0.utf8) }),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let dependencies = (json["dependencies"] as? [String: Any]) ?? [:]
            let devDependencies = (json["devDependencies"] as? [String: Any]) ?? [:]
            if dependencies["react-native"] != nil || devDependencies["react-native"] != nil { return .reactNative }
        }
        if appliesKMP(in: root, fileManager: fileManager) { return .kmp }
        if read("gradle/libs.versions.toml")?.contains("org.jetbrains.kotlin.multiplatform") == true { return .kmp }
        for name in ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let module = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: module.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if appliesKMP(in: module, fileManager: fileManager) { return .kmp }
        }
        return nil
    }

    /// Whether a `build.gradle.kts` / `build.gradle` directly in `directory` references the plugin.
    static func appliesKMP(in directory: URL, fileManager: FileManager) -> Bool {
        for file in ["build.gradle.kts", "build.gradle"] {
            let url = directory.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: url.path), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains(#"kotlin("multiplatform")"#) || text.contains("org.jetbrains.kotlin.multiplatform")
                || text.contains("kotlin-multiplatform")
            {
                return true
            }
        }
        return false
    }
}
