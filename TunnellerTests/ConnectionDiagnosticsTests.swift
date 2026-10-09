import Darwin
import XCTest
@testable import Tunneller

final class ConnectionDiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunneller-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCorrelationAcceptsOnlyOpaqueSupportedIdentifiers() {
        let uuid = UUID()
        XCTAssertEqual(DiagnosticCorrelationID(uuid.uuidString.lowercased())?.value, uuid.uuidString)
        XCTAssertEqual(DiagnosticCorrelationID("attempt.a0B1c2D3e4")?.value, "attempt.a0B1c2D3e4")
        for invalid in ["op://vault/item/password", "https://host/?code=secret", "attempt.a0B1c2D3e4-extra",
                        "attempt.abcdefgh/1", "attempt.ébcdefghij", "secret", "\n", ""] {
            XCTAssertNil(DiagnosticCorrelationID(invalid), invalid)
        }
    }

    @MainActor
    func testURLDiagnosticsKeepCorrelationAndDiscardSensitiveParameters() throws {
        let diagnostics = ConnectionDiagnostics(directory: directory)
        let requestID = UUID(), attemptID = UUID()
        let url = try XCTUnwrap(URL(string: "tunneller://connect?request=\(requestID)&attempt=\(attemptID)&correlation=attempt.a0B1c2D3e4&wait=1&password=SECRET&otp=123456&reference=op://private/item/password"))
        let request = AppDelegate.connectionRequest(from: url)
        diagnostics.record(.urlReceived, component: .app, request: request)
        diagnostics.record(.terminal, component: .app, request: request,
            terminal: .init(.failure("op://private/item/password SECRET 123456")))
        diagnostics.flush(timeout: 2)
        let entries = try readEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["request_id"] as? String, requestID.uuidString)
        XCTAssertEqual(entries[0]["attempt_id"] as? String, attemptID.uuidString)
        XCTAssertEqual(entries[0]["correlation_id"] as? String, "attempt.a0B1c2D3e4")
        XCTAssertEqual(entries[0]["wait"] as? Bool, true)
        XCTAssertEqual(entries[1]["reason"] as? String, "connection-failed")
        XCTAssertEqual(entries[1]["result"] as? String, "failure")
        let text = try String(contentsOf: directory.appendingPathComponent("timeline.jsonl"), encoding: .utf8)
        for forbidden in ["SECRET", "123456", "op://", "private", "password", "tunneller://"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertNotNil(entries[0]["timestamp"])
        XCTAssertEqual(entries[0]["pid"] as? Int32, getpid())
        XCTAssertEqual(entries[0]["ppid"] as? Int32, getppid())
        XCTAssertNil(entries[0]["args"])
    }

    @MainActor
    func testInvalidURLIdentifiersNeverEnterTimeline() throws {
        let diagnostics = ConnectionDiagnostics(directory: directory)
        let request = AppDelegate.connectionRequest(from: try XCTUnwrap(URL(string:
            "tunneller://connect?attempt=op://SECRET&request=SECRET&correlation=SECRET&wait=SECRET")))
        diagnostics.record(.requestIgnored, component: .app, request: request, reason: .invalidAttempt)
        diagnostics.flush(timeout: 2)
        let text = try String(contentsOf: directory.appendingPathComponent("timeline.jsonl"), encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("op://"))
        let entry = try XCTUnwrap(readEntries().first)
        XCTAssertEqual(entry["attempt_id"] as? String, request.requestID.uuidString)
        XCTAssertNil(entry["wait"])
    }

    func testRotationBoundsHistoryAndUsesPrivatePermissions() throws {
        let diagnostics = ConnectionDiagnostics(directory: directory, maximumBytes: 1024)
        for _ in 0..<20 {
            diagnostics.record(.cliInvocation, component: .cli, request: ConnectionRequest(attemptID: nil, wait: true))
        }
        diagnostics.flush(timeout: 2)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)),
            ["timeline.lock", "timeline.jsonl", "timeline.1.jsonl", "timeline.2.jsonl"])
        for file in files where file.pathExtension == "jsonl" {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertLessThanOrEqual((attributes[.size] as? Int) ?? .max, 1024)
            XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
            XCTAssertFalse(try readEntries(from: file).isEmpty)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
    }

    func testContendingWriterDropsEventWithoutWaiting() throws {
        let descriptor = open(directory.appendingPathComponent("timeline.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let diagnostics = ConnectionDiagnostics(directory: directory)
        let started = Date()
        diagnostics.record(.connectionStart, component: .app)
        diagnostics.flush(timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("timeline.jsonl").path))
    }

    func testUnsafeLogFilesAndUnwritableDirectoryAreBestEffort() throws {
        let target = directory.appendingPathComponent("untouched")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("timeline.jsonl"), withDestinationURL: target)
        let diagnostics = ConnectionDiagnostics(directory: directory)
        diagnostics.record(.connectionStart, component: .app)
        diagnostics.flush(timeout: 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        let invalid = ConnectionDiagnostics(directory: target)
        invalid.record(.connectionStart, component: .app)
        invalid.flush(timeout: 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testStoreReportsFirstTerminalOutcomeOnceIncludingTimeoutAndAbandonment() throws {
        let diagnostics = ConnectionDiagnostics(directory: directory.appendingPathComponent("logs"))
        let store = ConnectionAttemptStore(directory: directory.appendingPathComponent("attempts"),
            attemptTimeout: 0, diagnostics: diagnostics)
        let owner = try store.joinOrCreate()
        XCTAssertEqual(try store.wait(for: owner), .failure("timeout"))
        try store.complete(.success, for: owner.attempt.id)
        var abandoned: ConnectionAttemptStore.Registration? = try store.joinOrCreate()
        let abandonedID = try XCTUnwrap(abandoned).attempt.id
        abandoned = nil
        let retry = try store.joinOrCreate()
        try store.complete(.success, for: retry.attempt.id)
        diagnostics.flush(timeout: 2)
        let entries = try readEntries(from: diagnostics.directory.appendingPathComponent("timeline.jsonl"))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map { $0["result"] as? String }, ["timeout", "abandoned", "success"])
        XCTAssertEqual(entries[1]["attempt_id"] as? String, abandonedID.uuidString)
        XCTAssertTrue(entries.allSatisfy { $0["event"] as? String == "attempt_terminal" })
    }

    @MainActor
    func testQueuedRequestRetainsIdentityAndTimelineOrder() throws {
        let diagnostics = ConnectionDiagnostics(directory: directory)
        let router = ConnectionRequestRouter(diagnostics: diagnostics)
        let request = ConnectionRequest(attemptID: UUID().uuidString,
            correlationID: DiagnosticCorrelationID("attempt.a0B1c2D3e4"), wait: true)
        router.send(request)
        var delivered: ConnectionRequest?
        var terminated = false
        router.register({ delivered = $0 }, onTermination: { terminated = true })
        router.applicationWillTerminate()
        XCTAssertEqual(delivered?.requestID, request.requestID)
        XCTAssertEqual(delivered?.correlationID, request.correlationID)
        XCTAssertEqual(delivered?.wait, true)
        XCTAssertTrue(terminated)
        diagnostics.flush(timeout: 2)
        XCTAssertEqual(try readEntries().map { $0["event"] as? String }, ["url_queued", "url_handled"])
    }

    private func readEntries(from url: URL? = nil) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url ?? directory.appendingPathComponent("timeline.jsonl"))
        return try data.split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }
}
