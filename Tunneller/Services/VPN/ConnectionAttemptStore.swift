import Darwin
import Foundation

/// Registration/publication share a short coordinator lock. An owner retains
/// its own kernel lock until exit; waiters keep the UUID they originally joined.
final class ConnectionAttemptStore {
    static let shared = ConnectionAttemptStore()

    enum Outcome: Equatable {
        case success
        case failure(String)

        var serialized: String {
            switch self {
            case .success: "success\n"
            case .failure(let code): "failure:\(code.replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
    }

    struct Attempt: Codable, Equatable {
        let id: UUID
        let deadline: Date
    }

    final class Registration {
        let attempt: Attempt
        let isOwner: Bool
        // Pins prevent collection while a caller still needs the outcome.
        private let pin: FileLock
        private let ownership: FileLock?

        fileprivate init(attempt: Attempt, pin: FileLock, ownership: FileLock?) {
            self.attempt = attempt
            self.pin = pin
            self.ownership = ownership
            isOwner = ownership != nil
        }
    }

    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let directory: URL
    private let attemptTimeout: TimeInterval
    private let retention: TimeInterval
    private let coordinatorTimeout: TimeInterval

    init(directory: URL? = nil, attemptTimeout: TimeInterval = 300,
         retention: TimeInterval = 24 * 60 * 60, coordinatorTimeout: TimeInterval = 5) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tunneller/connection-attempts", isDirectory: true)
        // This bounds one stalled operation, never a retry cooldown. Allow both
        // credential reads, user interaction, and Cisco automation to finish.
        self.attemptTimeout = attemptTimeout
        self.retention = retention
        self.coordinatorTimeout = coordinatorTimeout
    }

    func joinOrCreate() throws -> Registration {
        try coordinated {
            try collectResults()
            if let active = try readActive() {
                if try readOutcome(active.id) != nil {
                    try clearActive(active.id)
                } else {
                    let ownership = try FileLock(url: ownerURL(active.id))
                    if try ownership.tryAcquire(exclusive: true) {
                        // Recover under the coordinator, without PIDs or unlink races.
                        _ = try completeLocked(.failure("owner-abandoned"), for: active.id)
                    } else {
                        return try registration(for: active, ownership: nil)
                    }
                }
            }
            let attempt = Attempt(id: UUID(), deadline: Date().addingTimeInterval(attemptTimeout))
            let ownership = try FileLock(url: ownerURL(attempt.id))
            guard try ownership.tryAcquire(exclusive: true) else {
                throw StoreError(message: "Could not own a new connection attempt.")
            }
            let registration = try registration(for: attempt, ownership: ownership)
            try JSONEncoder().encode(attempt).write(to: activeURL, options: .atomic)
            return registration
        }
    }

    /// First terminal result wins, including a timeout or owner crash.
    @discardableResult
    func complete(_ outcome: Outcome, for id: UUID) throws -> Outcome {
        try coordinated { try completeLocked(outcome, for: id) }
    }

    func outcome(for id: UUID) throws -> Outcome? {
        try coordinated { try readOutcome(id) }
    }

    /// Ignore delayed URL deliveries from a caller that has already failed.
    func isPending(_ id: UUID) throws -> Bool {
        try coordinated {
            guard try readOutcome(id) == nil, let active = try readActive() else { return false }
            guard active.id == id else { return false }
            if Date() >= active.deadline {
                _ = try completeLocked(.failure("timeout"), for: id)
                return false
            }
            let ownership = try FileLock(url: ownerURL(id))
            if try ownership.tryAcquire(exclusive: true) {
                _ = try completeLocked(.failure("owner-abandoned"), for: id)
                return false
            }
            return true
        }
    }

    func wait(for registration: Registration) throws -> Outcome {
        while true {
            let outcome: Outcome? = try coordinated {
                if let result = try readOutcome(registration.attempt.id) { return result }
                if Date() >= registration.attempt.deadline {
                    return try completeLocked(.failure("timeout"), for: registration.attempt.id)
                }
                if !registration.isOwner {
                    let ownership = try FileLock(url: ownerURL(registration.attempt.id))
                    if try ownership.tryAcquire(exclusive: true) {
                        return try completeLocked(.failure("owner-abandoned"), for: registration.attempt.id)
                    }
                }
                return nil
            }
            if let outcome { return outcome }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private var activeURL: URL { directory.appendingPathComponent("active.json") }
    private func resultURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).result") }
    private func ownerURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).owner") }
    private func pinURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).pin") }

    private func registration(for attempt: Attempt, ownership: FileLock?) throws -> Registration {
        let pin = try FileLock(url: pinURL(attempt.id))
        guard try pin.tryAcquire(exclusive: false) else {
            throw StoreError(message: "Could not retain a connection attempt.")
        }
        return Registration(attempt: attempt, pin: pin, ownership: ownership)
    }

    private func coordinated<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw StoreError(message: "The connection-attempt directory is not owned by this user.")
        }
        let lock = try FileLock(url: directory.appendingPathComponent("coordinator.lock"))
        let deadline = ProcessInfo.processInfo.systemUptime + coordinatorTimeout
        while try !lock.tryAcquire(exclusive: true) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw StoreError(message: "Timed out acquiring the connection-attempt coordinator.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Never unlink this inode: all callers must lock the same file.
        return try withExtendedLifetime(lock) { try body() }
    }

    private func readActive() throws -> Attempt? {
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return nil }
        do { return try JSONDecoder().decode(Attempt.self, from: Data(contentsOf: activeURL)) }
        catch { throw StoreError(message: "Cannot read connection-attempt metadata: \(error.localizedDescription)") }
    }

    private func readOutcome(_ id: UUID) throws -> Outcome? {
        let url = resultURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "success" { return .success }
        if value.hasPrefix("failure:"), value.count > 8 { return .failure(String(value.dropFirst(8))) }
        throw StoreError(message: "Malformed result for connection attempt \(id.uuidString).")
    }

    private func completeLocked(_ outcome: Outcome, for id: UUID) throws -> Outcome {
        let existing = try readOutcome(id)
        let terminal = existing ?? outcome
        if existing == nil {
            // Atomic write renames a complete file into place; the coordinator
            // serializes publishers so a terminal result can never be overwritten.
            try Data(terminal.serialized.utf8).write(to: resultURL(id), options: .atomic)
        }
        try clearActive(id)
        return terminal
    }

    private func clearActive(_ id: UUID) throws {
        if try readActive()?.id == id { try FileManager.default.removeItem(at: activeURL) }
    }

    /// Retain outcomes for live callers. Also collect bootstrap files left by an
    /// owner that crashed before publishing metadata. Never remove a live inode.
    private func collectResults() throws {
        let cutoff = Date().addingTimeInterval(-retention)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        let activeID = try readActive()?.id
        var artifacts: [UUID: [URL]] = [:]
        for file in files where ["result", "owner", "pin"].contains(file.pathExtension) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), id != activeID else { continue }
            artifacts[id, default: []].append(file)
        }
        for (id, paths) in artifacts {
            let dates = try paths.compactMap {
                try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            guard dates.count == paths.count, dates.allSatisfy({ $0 < cutoff }) else { continue }
            let pin = try FileLock(url: pinURL(id))
            guard try pin.tryAcquire(exclusive: true) else { continue }
            let ownership = try FileLock(url: ownerURL(id))
            guard try ownership.tryAcquire(exclusive: true) else { continue }
            // No live registration and no active metadata can name this ID.
            for path in [resultURL(id), ownerURL(id), pinURL(id)] where FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
    }
}

fileprivate final class FileLock {
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ConnectionAttemptStore.StoreError(message: "Cannot open \(url.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            close(descriptor)
            throw ConnectionAttemptStore.StoreError(message: "Invalid connection-attempt lock file.")
        }
    }

    func tryAcquire(exclusive: Bool) throws -> Bool {
        while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return false }
            throw ConnectionAttemptStore.StoreError(message: "Cannot lock connection attempt: \(String(cString: strerror(errno))).")
        }
        return true
    }

    deinit { close(descriptor) }
}
