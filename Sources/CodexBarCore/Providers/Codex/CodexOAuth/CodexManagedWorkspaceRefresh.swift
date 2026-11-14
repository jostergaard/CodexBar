#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum CodexCredentialRefreshAuthReason: String, Sendable, CaseIterable {
    case invalidGrant = "invalid_grant"
    case refreshTokenInvalidated = "refresh_token_invalidated"
    case refreshTokenExpired = "refresh_token_expired"
    case refreshTokenReused = "refresh_token_reused"
    case refreshTokenRevoked = "refresh_token_revoked"
    case loginRequired = "login_required"

    static func fromRPCError(_ error: [String: Any]) -> Self? {
        if let data = error["data"] as? [String: Any], let code = data["code"] as? String,
           let reason = Self(rawValue: code)
        {
            return reason
        }
        if let code = error["code"] as? String, let reason = Self(rawValue: code) {
            return reason
        }
        guard let message = error["message"] as? String else { return nil }
        let identifiers = message.components(separatedBy: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_")).inverted)
        return identifiers.lazy.compactMap(Self.init(rawValue:)).first
    }
}

enum CodexCredentialRefreshError: Error, LocalizedError {
    case unavailable
    case startFailed
    case timeout
    case transport
    case authentication(CodexCredentialRefreshAuthReason)
    case requestRejected
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "Codex credential refresh unavailable: CLI not installed."
        case .startFailed: "Codex credential refresh could not start."
        case .timeout: "Codex credential refresh timed out."
        case .transport: "Codex credential refresh connection closed."
        case let .authentication(reason): "Codex credential refresh requires login (\(reason.rawValue))."
        case .requestRejected: "Codex credential refresh request was rejected."
        case .invalidResponse: "Codex credential refresh returned invalid data."
        }
    }
}

/// Seat changes can invalidate every workspace account together. Bound CLI launches across homes.
private actor CodexCredentialRenewalGate {
    static let shared = CodexCredentialRenewalGate()
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var testWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        let waiterID = UUID()
        if self.active < 2 {
            self.active += 1
        } else {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.waiters.append((waiterID, continuation))
                    self.testWaiters = self.testWaiters.filter { entry in
                        guard self.waiters.count >= entry.count else { return true }
                        entry.continuation.resume()
                        return false
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
        }
        defer {
            if self.waiters.isEmpty {
                self.active -= 1
            } else {
                self.waiters.removeFirst().continuation.resume()
            }
        }
        try Task.checkCancellation()
        try await operation()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func waitUntilWaitingCount(_ count: Int) async {
        guard self.waiters.count < count else { return }
        await withCheckedContinuation { continuation in
            self.testWaiters.append((count, continuation))
        }
    }
}

/// The CLI alone renews credentials. This coordinator never writes auth.json or consumes CLI usage.
actor CodexManagedWorkspaceRefresh {
    static let shared = CodexManagedWorkspaceRefresh()

    struct Snapshot: Sendable {
        struct Identity: Equatable, Sendable {
            let accountID: String
            let email: String
            let subject: String?
        }

        let credentials: CodexOAuthCredentials
        let fingerprint: String
        let identity: Identity?

        static func read(env: [String: String]) throws -> Self {
            let data = try CodexOAuthCredentialsStore.readAuthData(env: env)
            let credentials = try CodexOAuthCredentialsStore.parse(data: data)
            let owner = credentials.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = (credentials.idToken.flatMap(UsageFetcher.parseJWT)?["sub"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let email = CodexNativeCredentialOwnerIdentity.normalizedEmail(fromIDToken: credentials.idToken)
            let identity: Identity? = if let owner, !owner.isEmpty, let email {
                Identity(accountID: owner, email: email, subject: subject?.isEmpty == true ? nil : subject)
            } else {
                nil
            }
            let fingerprint = CodexManagedWorkspaceRefresh.digest(data)
            return Self(credentials: credentials, fingerprint: fingerprint, identity: identity)
        }
    }

    enum RecoveryError: LocalizedError {
        case temporarilyUnavailable

        var errorDescription: String? {
            "Codex credential renewal is temporarily unavailable. Retaining stale usage; retry later."
        }
    }

    private struct State: Codable {
        var fingerprint: String
        var attemptCount: Int
        var nextEligibleTime: Date
        var errorClass: String
        var unconfirmedCount: Int = 0
        var terminalReason: String?
    }

    private struct Flight {
        let id: UUID
        let workspace: String
        let fingerprint: String
        let task: Task<ProviderFetchResult, Error>
        var waiters: Set<UUID>
        var renewalStarted = false
    }

    private var flights: [String: Flight] = [:]
    private var flightWaiterTests: [
        (key: String, count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private let stateDirectory: URL

    private func markRenewalStarted(key: String, id: UUID) throws {
        try Task.checkCancellation()
        guard var flight = self.flights[key], flight.id == id, !flight.waiters.isEmpty else {
            throw CancellationError()
        }
        flight.renewalStarted = true
        self.flights[key] = flight
    }

    private func finishFlight(key: String, id: UUID) {
        guard self.flights[key]?.id == id else { return }
        self.flights[key] = nil
    }

    private func signalFlightWaiters(key: String) {
        self.flightWaiterTests = self.flightWaiterTests.filter { entry in
            guard entry.key == key, self.flights[key]?.waiters.count ?? 0 >= entry.count else { return true }
            entry.continuation.resume()
            return false
        }
    }

    private func cancelFlightWaiter(key: String, id: UUID, waiterID: UUID) {
        guard var flight = self.flights[key], flight.id == id,
              flight.waiters.remove(waiterID) != nil
        else { return }
        if flight.waiters.isEmpty, !flight.renewalStarted {
            flight.task.cancel()
        }
        self.flights[key] = flight
    }

    private func awaitFlight(
        key: String,
        flight: Flight,
        waiterID: UUID) async throws -> ProviderFetchResult
    {
        try await withTaskCancellationHandler {
            let result = await flight.task.result
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            Task { await self.cancelFlightWaiter(key: key, id: flight.id, waiterID: waiterID) }
        }
    }

    init(stateDirectory: URL? = nil) {
        self.stateDirectory = stateDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar/CodexCredentialRefresh", isDirectory: true)
    }

    static func home(env: [String: String]) -> URL? {
        guard let value = env["CODEX_HOME"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CodexHomeScope.ambientHomeURL(env: env).standardizedFileURL.resolvingSymlinksInPath()
    }

    // Keep the credential snapshot and both injected operations explicit at the recovery boundary.
    // swiftlint:disable:next function_parameter_count
    func recover(
        home: URL,
        workspace: String,
        failed: Snapshot,
        env: [String: String],
        now: Date = Date(),
        expectedEmail: String? = nil,
        renew: @escaping @Sendable () async throws -> Void,
        retry: @escaping @Sendable (CodexOAuthCredentials) async throws -> ProviderFetchResult) async throws
        -> ProviderFetchResult
    {
        let key = home.standardizedFileURL.resolvingSymlinksInPath().path
        try Task.checkCancellation()
        if let flight = self.flights[key] {
            let waiterID = UUID()
            var joined = flight
            joined.waiters.insert(waiterID)
            self.flights[key] = joined
            self.signalFlightWaiters(key: key)
            if flight.workspace == workspace, flight.fingerprint == failed.fingerprint {
                return try await self.awaitFlight(key: key, flight: joined, waiterID: waiterID)
            }
            do {
                _ = try await self.awaitFlight(key: key, flight: joined, waiterID: waiterID)
            } catch {
                if Task.isCancelled { throw error }
            }
            return try await self.recover(
                home: home,
                workspace: workspace,
                failed: failed,
                env: env,
                now: now,
                expectedEmail: expectedEmail,
                renew: renew,
                retry: retry)
        }
        let stateURL = self.stateURL(home: home, workspace: workspace)
        let id = UUID()
        let waiterID = UUID()
        let task = Task {
            defer { self.finishFlight(key: key, id: id) }
            return try await Self.perform(
                home: URL(fileURLWithPath: key),
                workspace: workspace,
                failed: failed,
                env: env,
                stateURL: stateURL,
                now: now,
                expectedEmail: expectedEmail,
                renewalStarted: { try await self.markRenewalStarted(key: key, id: id) },
                renew: renew,
                retry: retry)
        }
        self.flights[key] = Flight(
            id: id,
            workspace: workspace,
            fingerprint: failed.fingerprint,
            task: task,
            waiters: [waiterID])
        self.signalFlightWaiters(key: key)
        return try await self.awaitFlight(key: key, flight: self.flights[key]!, waiterID: waiterID)
    }

    static func waitForRenewalGateQueueForTesting() async {
        await CodexCredentialRenewalGate.shared.waitUntilWaitingCount(1)
    }

    func waitForFlightWaitersForTesting(home: URL, count: Int) async {
        let key = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard self.flights[key]?.waiters.count ?? 0 < count else { return }
        await withCheckedContinuation { continuation in
            self.flightWaiterTests.append((key: key, count: count, continuation: continuation))
            self.signalFlightWaiters(key: key)
        }
    }

    func checkTerminalFailure(home: URL, workspace: String, fingerprint: String) throws {
        if let state = try? Self.readState(at: self.stateURL(home: home, workspace: workspace)),
           state.fingerprint == fingerprint, state.errorClass == "authentication"
        {
            throw Self.authenticationError(state.terminalReason ?? "renewalUnconfirmed")
        }
    }

    func reset(home: URL, workspace: String, fingerprint: String, env: [String: String]) async {
        // Do not clear another process's newer failure after an older usage request completes.
        guard self.flights[home.standardizedFileURL.resolvingSymlinksInPath().path] == nil,
              let descriptor = try? await Self.acquireLock(home.appendingPathComponent(".codexbar-refresh.lock"))
        else { return }
        defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        guard let current = try? Snapshot.read(env: env), current.fingerprint == fingerprint else { return }
        try? FileManager.default.removeItem(at: self.stateURL(home: home, workspace: workspace))
    }

    private func stateURL(home: URL, workspace: String) -> URL {
        let key = home.standardizedFileURL.resolvingSymlinksInPath().path + "\n" + workspace
        return self.stateDirectory.appendingPathComponent(Self.digest(Data(key.utf8)) + ".json")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // swiftlint:disable:next function_parameter_count
    private static func perform(
        home: URL,
        workspace: String,
        failed: Snapshot,
        env: [String: String],
        stateURL: URL,
        now: Date,
        expectedEmail: String?,
        renewalStarted: @escaping @Sendable () async throws -> Void,
        renew: @Sendable () async throws -> Void,
        retry: @Sendable (CodexOAuthCredentials) async throws -> ProviderFetchResult) async throws
        -> ProviderFetchResult
    {
        let descriptor = try await self.acquireLock(home.appendingPathComponent(".codexbar-refresh.lock"))
        defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        var state: State?
        var latest = failed
        var terminalReason: String?
        var unconfirmedRenewal = false
        var expectedIdentity: Snapshot.Identity?
        do {
            latest = try Snapshot.read(env: env)
            expectedIdentity = latest.identity ?? failed.identity
            guard self.identityIsValid(latest.identity, expectedEmail: expectedEmail, fallback: nil) else {
                throw self.authenticationError("ownershipMismatch")
            }
            state = try self.readState(at: stateURL)
            if state?.fingerprint != latest.fingerprint { state = nil }
            if state?.errorClass == "authentication" {
                throw self.authenticationError(state?.terminalReason ?? "renewalUnconfirmed")
            }
            if let state, state.nextEligibleTime > now { throw RecoveryError.temporarilyUnavailable }

            if latest.fingerprint == failed.fingerprint {
                let count = min((state?.attemptCount ?? 0) + 1, 16)
                let unconfirmedCount = state?.unconfirmedCount ?? 0
                state = State(
                    fingerprint: latest.fingerprint,
                    attemptCount: count,
                    nextEligibleTime: now.addingTimeInterval(min(3600, 30 * pow(2, Double(count - 1)))),
                    errorClass: "transient",
                    unconfirmedCount: unconfirmedCount)
                // Persist before launching: a crash/restart must not create a refresh loop.
                try self.writeState(state!, at: stateURL)
                try await CodexCredentialRenewalGate.shared.run {
                    let queued = try Snapshot.read(env: env)
                    guard self
                        .identityIsValid(queued.identity, expectedEmail: expectedEmail, fallback: failed.identity)
                    else {
                        throw self.authenticationError("ownershipMismatch")
                    }
                    if queued.fingerprint == failed.fingerprint {
                        try await renewalStarted()
                        try await renew()
                    }
                }
                latest = try Snapshot.read(env: env)
                unconfirmedRenewal = latest.fingerprint == failed.fingerprint
            }
            guard self.identityIsValid(latest.identity, expectedEmail: expectedEmail, fallback: failed.identity),
                  latest.identity == expectedIdentity, !latest.credentials.isAPIKey
            else {
                throw self.authenticationError("ownershipMismatch")
            }
            let result: ProviderFetchResult
            do {
                result = try await retry(latest.credentials)
            } catch CodexOAuthFetchError.unauthorized {
                if unconfirmedRenewal {
                    state?.unconfirmedCount += 1
                    if (state?.unconfirmedCount ?? 0) < 3 { throw RecoveryError.temporarilyUnavailable }
                }
                let reason = unconfirmedRenewal ? "renewalUnconfirmed" : "usageUnauthorizedAfterRenewal"
                terminalReason = reason
                throw self.authenticationError(reason)
            }
            try? FileManager.default.removeItem(at: stateURL)
            return result
        } catch {
            if error is CancellationError || Task.isCancelled {
                try? FileManager.default.removeItem(at: stateURL)
                throw error
            }
            // The CLI may have persisted a rotation even if its RPC reply was lost. Never roll it back.
            let current = try? Snapshot.read(env: env)
            let changedDuringFailure = current.map { $0.fingerprint != latest.fingerprint } ?? false
            if let current { latest = current }
            if case let .authentication(reason) = error as? CodexCredentialRefreshError {
                terminalReason = reason.rawValue
            } else if let classified = error as? ProviderFetchClassifiedError,
                      classified.kind == .authenticationExpired,
                      classified.message.contains("ownershipMismatch")
            {
                terminalReason = "ownershipMismatch"
            }
            // Ownership mismatches are terminal even when auth.json changed while the gate was held.
            // Other authentication failures may be superseded by a new same-owner publication.
            let ownershipFailure = terminalReason == "ownershipMismatch"
                && (expectedEmail != nil || expectedIdentity != nil)
            let authenticationFailure = ownershipFailure || (!changedDuringFailure && (terminalReason != nil
                    || (error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired))
            var failure = state ?? State(
                fingerprint: latest.fingerprint,
                attemptCount: 1,
                nextEligibleTime: now.addingTimeInterval(30),
                errorClass: "transient")
            failure.fingerprint = latest.fingerprint
            failure.errorClass = authenticationFailure ? "authentication" : "transient"
            failure.terminalReason = terminalReason ?? failure.terminalReason
            try? self.writeState(failure, at: stateURL)
            if authenticationFailure {
                throw self.authenticationError(failure.terminalReason ?? "renewalUnconfirmed")
            }
            // Do not pass CLI error payloads or credential decode details into logs/UI.
            throw RecoveryError.temporarilyUnavailable
        }
    }

    private static func identityIsValid(
        _ identity: Snapshot.Identity?,
        expectedEmail: String?,
        fallback: Snapshot.Identity?) -> Bool
    {
        guard let identity else { return false }
        if let expectedEmail, identity.email != CodexIdentityResolver.normalizeEmail(expectedEmail) { return false }
        return fallback == nil || identity == fallback
    }

    private static func authenticationError(_ reason: String) -> ProviderFetchClassifiedError {
        ProviderFetchClassifiedError(
            kind: .authenticationExpired,
            message: "Codex login required (\(reason)). Reauthenticate this account in its managed Codex home.")
    }

    private static func readState(at url: URL) throws -> State? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    private static func writeState(_ state: State, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func acquireLock(_ url: URL) async throws -> Int32 {
        let descriptor = url.path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw RecoveryError.temporarilyUnavailable }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == getuid(), status.st_nlink == 1
        else { _ = close(descriptor); throw RecoveryError.temporarilyUnavailable }
        do {
            for _ in 0..<300 {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
                guard errno == EWOULDBLOCK || errno == EAGAIN else { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw RecoveryError.temporarilyUnavailable
        } catch {
            _ = close(descriptor)
            throw error
        }
    }
}
