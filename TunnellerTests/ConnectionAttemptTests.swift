import Darwin
import XCTest
@testable import Tunneller

final class ConnectionAttemptTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tunneller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testFailureReachesAllWaitersAndImmediateRetryIsFresh() throws {
        let store = ConnectionAttemptStore(directory: directory)
        let owner = try store.joinOrCreate()
        let waiterA = try store.joinOrCreate()
        let waiterB = try store.joinOrCreate()
        XCTAssertTrue(owner.isOwner)
        XCTAssertFalse(waiterA.isOwner)
        XCTAssertEqual(waiterA.attempt, owner.attempt)
        XCTAssertEqual(waiterB.attempt, owner.attempt)

        try store.complete(.failure("authentication-cancelled"), for: owner.attempt.id)
        let retry = try store.joinOrCreate()
        XCTAssertTrue(retry.isOwner)
        XCTAssertNotEqual(retry.attempt.id, owner.attempt.id)
        XCTAssertEqual(try store.wait(for: owner), .failure("authentication-cancelled"))
        XCTAssertEqual(try store.wait(for: waiterA), .failure("authentication-cancelled"))
        XCTAssertEqual(try store.wait(for: waiterB), .failure("authentication-cancelled"))
        XCTAssertTrue(try store.isPending(retry.attempt.id))
    }

    func testSuccessIsSharedAndTerminalOutcomeCannotBeOverwritten() throws {
        let store = ConnectionAttemptStore(directory: directory)
        let owner = try store.joinOrCreate()
        let waiter = try store.joinOrCreate()
        try store.complete(.success, for: owner.attempt.id)
        XCTAssertEqual(try store.complete(.failure("late-error"), for: owner.attempt.id), .success)
        XCTAssertEqual(try store.wait(for: waiter), .success)
        XCTAssertFalse(try store.isPending(owner.attempt.id))
    }

    func testDeadOwnerFailsOldWaitersWithoutClearingNewOwner() throws {
        let store = ConnectionAttemptStore(directory: directory)
        var owner: ConnectionAttemptStore.Registration? = try store.joinOrCreate()
        let oldID = owner!.attempt.id
        let waiter = try store.joinOrCreate()
        owner = nil // Closing the lifetime FD simulates owner process exit.
        let retry = try store.joinOrCreate()
        XCTAssertTrue(retry.isOwner)
        XCTAssertNotEqual(retry.attempt.id, oldID)
        XCTAssertEqual(try store.wait(for: waiter), .failure("owner-abandoned"))
        XCTAssertTrue(try store.isPending(retry.attempt.id))
        let joinedRetry = try store.joinOrCreate()
        XCTAssertFalse(joinedRetry.isOwner)
        XCTAssertEqual(joinedRetry.attempt.id, retry.attempt.id)
    }

    func testWaiterDetectsOwnerExitWithoutAnotherRequest() throws {
        let store = ConnectionAttemptStore(directory: directory)
        var owner: ConnectionAttemptStore.Registration? = try store.joinOrCreate()
        let waiter = try store.joinOrCreate()
        XCTAssertNotNil(owner)
        owner = nil
        XCTAssertEqual(try store.wait(for: waiter), .failure("owner-abandoned"))
        XCTAssertTrue(try store.joinOrCreate().isOwner)
    }

    func testAllWaitersUseTheOwnersDeadline() throws {
        let store = ConnectionAttemptStore(directory: directory, attemptTimeout: 0)
        let owner = try store.joinOrCreate()
        let waiter = try store.joinOrCreate()
        XCTAssertEqual(owner.attempt.deadline, waiter.attempt.deadline)
        XCTAssertEqual(try store.wait(for: waiter), .failure("timeout"))
        XCTAssertEqual(try store.wait(for: owner), .failure("timeout"))
        XCTAssertTrue(try store.joinOrCreate().isOwner)
    }

    func testMalformedMetadataFailsPromptly() throws {
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("active.json"))
        let started = Date()
        XCTAssertThrowsError(try ConnectionAttemptStore(directory: directory).joinOrCreate())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testInvalidCoordinatorFileFailsPromptly() throws {
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("coordinator.lock"),
            withDestinationURL: directory.appendingPathComponent("absent"))
        let started = Date()
        XCTAssertThrowsError(try ConnectionAttemptStore(directory: directory).joinOrCreate())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCoordinatorWaitIsBounded() throws {
        let descriptor = open(directory.appendingPathComponent("coordinator.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        XCTAssertThrowsError(try ConnectionAttemptStore(directory: directory, coordinatorTimeout: 0.05).joinOrCreate())
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testCollectionPreservesLiveWaitersAndRemovesReleasedAttempts() throws {
        let store = ConnectionAttemptStore(directory: directory, retention: 0)
        var owner: ConnectionAttemptStore.Registration? = try store.joinOrCreate()
        let id = owner!.attempt.id
        var waiter: ConnectionAttemptStore.Registration? = try store.joinOrCreate()
        try store.complete(.failure("cancelled"), for: id)
        owner = nil
        let retry = try store.joinOrCreate()
        XCTAssertEqual(try store.wait(for: waiter!), .failure("cancelled"))
        waiter = nil
        let joinedRetry = try store.joinOrCreate()
        XCTAssertEqual(joinedRetry.attempt.id, retry.attempt.id)
        XCTAssertNil(try store.outcome(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).owner").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id.uuidString).pin").path))
    }

    func testConcurrentRegistrationCreatesExactlyOneOwner() throws {
        let store = ConnectionAttemptStore(directory: directory)
        let finished = expectation(description: "registered all callers")
        finished.expectedFulfillmentCount = 12
        let mutex = NSLock()
        var registrations: [ConnectionAttemptStore.Registration] = []
        var errors: [Error] = []
        for _ in 0..<12 {
            DispatchQueue.global().async {
                do {
                    let registration = try store.joinOrCreate()
                    mutex.lock()
                    registrations.append(registration)
                    mutex.unlock()
                } catch {
                    mutex.lock()
                    errors.append(error)
                    mutex.unlock()
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(registrations.count, 12)
        XCTAssertEqual(registrations.filter(\.isOwner).count, 1)
        XCTAssertEqual(Set(registrations.map { $0.attempt.id }).count, 1)
        let id = try XCTUnwrap(registrations.first?.attempt.id)
        try store.complete(.failure("cancelled"), for: id)
        for registration in registrations {
            XCTAssertEqual(try store.wait(for: registration), .failure("cancelled"))
        }
    }

    func testLateURLForAbandonedOwnerDoesNotStartAuthentication() throws {
        let store = ConnectionAttemptStore(directory: directory)
        var owner: ConnectionAttemptStore.Registration? = try store.joinOrCreate()
        let id = owner!.attempt.id
        owner = nil
        XCTAssertFalse(try store.isPending(id))
        XCTAssertEqual(try store.outcome(for: id), .failure("owner-abandoned"))
    }

    func testCollectionRemovesBootstrapCrashFiles() throws {
        let orphan = UUID().uuidString
        for ext in ["owner", "pin"] {
            try Data().write(to: directory.appendingPathComponent("\(orphan).\(ext)"))
        }
        let registration = try ConnectionAttemptStore(directory: directory, retention: 0).joinOrCreate()
        XCTAssertTrue(registration.isOwner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(orphan).owner").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(orphan).pin").path))
    }

    @MainActor
    func testColdLaunchRequestsAreBufferedAndDeliveredOnce() {
        let router = ConnectionRequestRouter()
        router.send(attemptID: "first")
        router.send(attemptID: nil)
        var delivered: [String?] = []
        router.register { delivered.append($0) }
        XCTAssertEqual(delivered, ["first", nil])
        router.send(attemptID: "third")
        XCTAssertEqual(delivered, ["first", nil, "third"])
        router.register { delivered.append($0) }
        XCTAssertEqual(delivered.count, 3)
    }
}
