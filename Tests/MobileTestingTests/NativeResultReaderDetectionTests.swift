import Foundation
import TestCommons
import Testing

@testable import MobileTesting

@Suite("Native result detection")
struct NativeResultReaderDetectionTests {
    @Test("Swift event streams are recognized from their first lines, however large the file")
    func swiftEventsFromPrefix() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let head = #"{"version":0,"kind":"event","payload":{}}"# + "\n"
        let filler = String(repeating: #"{"machine":"line"}"# + "\n", count: 40_000)
        let events = scratch.url.appendingPathComponent("events.jsonl")
        try Data((head + filler).utf8).write(to: events)
        #expect(try NativeResultReader.detect(events.path) == .swift)

        let flutter = scratch.url.appendingPathComponent("flutter.jsonl")
        try Data((filler).utf8).write(to: flutter)
        #expect(try NativeResultReader.detect(flutter.path) == .flutter)
    }

    @Test("Only the first complete lines of a long file are read")
    func leadingLinesAreBounded() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let file = scratch.url.appendingPathComponent("long.jsonl")
        try Data((0..<1000).map { "line-\($0)\n" }.joined().utf8).write(to: file)
        #expect(try NativeResultReader.leadingLines(ofFileAt: file, count: 3) == ["line-0", "line-1", "line-2"])
        let cut = try NativeResultReader.leadingLines(ofFileAt: file, count: 1000, maxBytes: 25)
        #expect(cut == ["line-0", "line-1", "line-2"], "A partial last line is dropped, not misread")
    }

    @Test("A directory is JUnit when any file below it is XML")
    func directoryWithXML() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let nested = scratch.url.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(try NativeResultReader.detect(scratch.url.path) == nil)
        try Data("<testsuite/>".utf8).write(to: nested.appendingPathComponent("TEST-x.xml"))
        #expect(try NativeResultReader.detect(scratch.url.path) == .junit)
    }
}
