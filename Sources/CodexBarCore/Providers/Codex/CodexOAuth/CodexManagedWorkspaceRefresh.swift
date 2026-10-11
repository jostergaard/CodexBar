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

/// Seat changes can invalidate every workspace account together. Bound CLI launches across homes.
private actor CodexCredentialRenewalGate {
    static let shared = CodexCredentialRenewalGate()
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: @Sendable () async throws -> Void) async throws {
        if self.active >= 2 {
            await withCheckedContinuation { self.waiters.append($0) }
        } else {
            self.active += 1
        }
        defer {
            if self.waiters.isEmpty {
                self.active -= 1
            } else {
                self.waiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        try await operation()
    }
}

/// The CLI alone renews credentials. This coordinator never writes auth.json or consumes CLI usage.
actor CodexManagedWorkspaceRefresh {
    static let shared = CodexManagedWorkspaceRefresh()

    struct Snapshot: Sendable {
        let credentials: CodexOAuthCredentials
        let fingerprint: String
        let owner: String?

        static func read(env: [String: String]) throws -> Self {
            let data = try CodexOAuthCredentialsStore.nativeUsageData(env: env)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let tokens = object?["tokens"] as? [String: Any]
            return try Self(
                credentials: CodexOAuthCredentialsStore.parse(data: data),
                fingerprint: CodexManagedWorkspaceRefresh.digest(data),
                owner: (tokens?["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
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
    }

    private var flights: [String: Flight] = [:]
    private let stateDirectory: URL

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
        renew: @escaping @Sendable () async throws -> Void,
        retry: @escaping @Sendable (CodexOAuthCredentials) async throws -> ProviderFetchResult) async throws
        -> ProviderFetchResult
    {
        let key = home.standardizedFileURL.resolvingSymlinksInPath().path
        if let flight = self.flights[key] {
            if flight.workspace == workspace, flight.fingerprint == failed.fingerprint {
                return try await flight.task.value
            }
            _ = try? await flight.task.value
            if self.flights[key]?.id == flight.id { self.flights[key] = nil }
            return try await self.recover(
                home: home, workspace: workspace, failed: failed, env: env, now: now, renew: renew, retry: retry)
        }
        let stateURL = self.stateURL(home: home, workspace: workspace)
        let id = UUID()
        let task = Task {
            try await Self.perform(
                home: URL(fileURLWithPath: key),
                workspace: workspace,
                failed: failed,
                env: env,
                stateURL: stateURL,
                now: now,
                renew: renew,
                retry: retry)
        }
        self.flights[key] = Flight(id: id, workspace: workspace, fingerprint: failed.fingerprint, task: task)
        defer {
            if self.flights[key]?.id == id { self.flights[key] = nil }
        }
        return try await task.value
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
        do {
            latest = try Snapshot.read(env: env)
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
                try await CodexCredentialRenewalGate.shared.run(renew)
                latest = try Snapshot.read(env: env)
                unconfirmedRenewal = latest.fingerprint == failed.fingerprint
            }
            guard latest.owner == workspace, !latest.credentials.isAPIKey else {
                terminalReason = "ownershipMismatch"
                throw self.authenticationError("ownershipMismatch")
            }
            let result: ProviderFetchResult
            do {
                result = try await retry(latest.credentials)
            } catch CodexOAuthFetchError.unauthorized {
                if unconfirmedRenewal {
                    state?.unconfirmedCount += 1
                    if (state?.unconfirmedCount ?? 0) < 3 { throw RecoveryError.temporarilyUnavailable }
                    terminalReason = "renewalUnconfirmed"
                } else {
                    terminalReason = "usageUnauthorizedAfterRenewal"
                }
                throw self.authenticationError(terminalReason!)
            }
            try? FileManager.default.removeItem(at: stateURL)
            return result
        } catch {
            // The CLI may have persisted a rotation even if its RPC reply was lost. Never roll it back.
            let current = try? Snapshot.read(env: env)
            let changedDuringFailure = current.map { $0.fingerprint != latest.fingerprint } ?? false
            if let current { latest = current }
            if case let .authentication(reason) = error as? CodexCredentialRefreshError {
                terminalReason = reason.rawValue
            }
            // A CLI publication or new login that overlapped the failure has not itself been rejected.
            let authenticationFailure = !changedDuringFailure && (terminalReason != nil
                || (error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired)
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
            if error is CancellationError { throw error }
            // Do not pass CLI error payloads or credential decode details into logs/UI.
            throw RecoveryError.temporarilyUnavailable
        }
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
