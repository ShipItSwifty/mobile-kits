import Foundation

/// The framework an app is written in, which decides how its native artifacts are produced.
///
/// Orthogonal to ``MobilePlatform``: one Flutter, React Native, or Kotlin Multiplatform source
/// tree targets iOS and Android, while a native app has a separate project per platform.
///
/// The raw values are an interchange format (Shipfile `build_system:`, test reports); keep them
/// stable.
public enum AppFramework: String, Codable, Sendable, CaseIterable, Hashable {
    /// Swift/Objective-C with xcodebuild, or Kotlin/Java with Gradle.
    case native
    /// `flutter build` produces the `.app`/`.ipa` and `.apk`/`.aab`.
    case flutter
    /// Metro bundles JavaScript; xcodebuild and Gradle produce the native artifacts.
    case reactNative = "react_native"
    /// Gradle builds the Android app and an iOS framework that an Xcode project consumes.
    case kmp
}

/// The tool that builds or tests a target.
public enum BuildBackend: String, Codable, Sendable, CaseIterable, Hashable {
    case xcodebuild
    case gradle
    case swiftPM = "swiftpm"
    case flutter
    case reactNative = "react_native"
    case bazel
}
