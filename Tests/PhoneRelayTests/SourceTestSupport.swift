import Foundation

enum SourceTestSupport {
    static func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// Source-contract tests intentionally protect a few orchestration
    /// invariants. AppModel is now a facade split across cohesive files, so
    /// those tests inspect the complete implementation instead of coupling to
    /// one physical file.
    static func appModelImplementation() throws -> String {
        try [
            "Sources/PhoneRelay/AppModel.swift",
            "Sources/PhoneRelay/AppModel+Connection.swift",
            "Sources/PhoneRelay/AppModel+ConnectionRuntime.swift",
            "Sources/PhoneRelay/AppModel+MirrorLifecycle.swift",
            "Sources/PhoneRelay/AppModel+MirrorRuntime.swift"
        ]
        .map(source)
        .joined(separator: "\n")
    }
}
