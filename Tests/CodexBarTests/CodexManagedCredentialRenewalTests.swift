import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CodexCredentialFixtures())
struct CodexManagedCredentialRenewalTests {
    @Test(arguments: [ProviderSourceMode.auto, .oauth], [true, false])
    func `managed OAuth renews expired credentials or an unexpired token rejected with 401`(
        mode: ProviderSourceMode,
        expired: Bool) async throws
    {
        let fixture = try Fixture(expired: expired)
        let calls = Calls()
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == Fixture.workspace)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.originalToken)" {
                #expect(!expired)
                return try Self.response(request, code: 401)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.token("rotated"))")
            return try Self.response(request)
        }
        let recovery = fixture.coordinator()
        let pipeline = ProviderFetchPipeline { context in
            let strategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
            return strategies.map { strategy -> any ProviderFetchStrategy in
                guard strategy.id == "codex.oauth" else { return UnavailableStrategy(id: strategy.id) }
                return ManagedStrategy(fixture: fixture, recovery: recovery, renew: {
                    await calls.renewed()
                    try fixture.rotate()
                })
            }
        }
        let outcome = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await pipeline.fetch(context: Self.context(mode: mode, fixture: fixture), provider: .codex)
        }
        let result = try outcome.result.get()
        #expect(result.usage.primary?.usedPercent == 22)
        #expect(outcome.attempts.filter(\.wasAvailable).map(\.strategyID) == ["codex.oauth"])
        #expect(await calls.renewals == 1)
        #expect(await transport.requests().count == (expired ? 1 : 2))
        #expect(try fixture.snapshot().credentials.accessToken == Fixture.token("rotated"))
    }

    @Test
    func `managed OAuth retries a renewed token only once when usage still returns 401`() async throws {
        let fixture = try Fixture(expired: false)
        let calls = Calls()
        let transport = ProviderHTTPTransportStub { request in try Self.response(request, code: 401) }
        await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            for _ in 0..<2 {
                await Self.expectUnauthorized {
                    try await CodexOAuthFetchStrategy.fetchManagedWorkspace(
                        Self.context(mode: .oauth, fixture: fixture),
                        home: fixture.home,
                        workspace: Fixture.workspace,
                        recovery: fixture.coordinator(),
                        renew: {
                            await calls.renewed()
                            try fixture.rotate()
                        })
                }
            }
        }
        #expect(await calls.renewals == 1)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `selected workspace header is kept when auth json names another default workspace`() async throws {
        let fixture = try Fixture(expired: false, owner: "native-default")
        let calls = Calls()
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "selected-workspace")
            let original = request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.originalToken)"
            return try Self.response(request, code: original ? 401 : 200)
        }
        let context = Self.context(mode: .oauth, fixture: fixture, workspace: "selected-workspace")
        _ = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await CodexOAuthFetchStrategy.fetchManagedWorkspace(
                context, home: fixture.home, workspace: "selected-workspace", recovery: fixture.coordinator(), renew: {
                    await calls.renewed()
                    try fixture.rotate(owner: "native-default")
                })
        }
        #expect(await calls.renewals == 1)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `accounts sharing a workspace each renew with their own email`() async throws {
        for email in ["account0@example.test", "account1@example.test"] {
            let fixture = try Fixture(email: email)
            let calls = Calls()
            _ = try await fixture.recover(expectedEmail: email, renew: calls.renew, retry: calls.retry)
            #expect(await calls.renewals == 1)
            #expect(await calls.retries == 1)
        }
    }

    @Test(arguments: ["email", "subject", "owner"])
    func `renewal that changes the account identity fails before usage retry`(change: String) async throws {
        let fixture = try Fixture()
        let calls = Calls()
        await Self.expectUnauthorized {
            try await fixture.recover(
                expectedEmail: fixture.email,
                renew: {
                    await calls.renewed()
                    try fixture.rotate(
                        owner: change == "owner" ? "other-workspace" : Fixture.workspace,
                        email: change == "email" ? "different@example.test" : fixture.email,
                        subject: change == "subject" ? "different-subject" : fixture.subject)
                },
                retry: calls.retry)
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 0)

        // A new login with the expected identity clears the ownership failure.
        try fixture.rotate(generation: "new-login")
        _ = try await fixture.recover(renew: calls.renew, retry: calls.retry)
        #expect(await calls.renewals == 2)
        #expect(await calls.retries == 1)
    }

    @Test
    func `email mismatch before launch rejects without renewal or retry`() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        await Self.expectUnauthorized {
            try await fixture.recover(
                expectedEmail: "not-the-selected-account@example.test", renew: calls.renew, retry: calls.retry)
        }
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 0)
    }

    @Test
    func `queued renewal rechecks ownership after both gate slots are released`() async throws {
        let blocker = RenewalBlocker()
        let blockerTasks = try (0..<2).map { _ in
            let fixture = try Fixture()
            return Task { try await fixture.recover(renew: { await blocker.enterAndWait() }) }
        }
        await blocker.waitForStarted(2)
        let queued = try Fixture()
        let calls = Calls()
        let queuedTask = Task {
            try await queued.recover(expectedEmail: queued.email, renew: calls.renew, retry: calls.retry)
        }
        await CodexManagedWorkspaceRefresh.waitForRenewalGateQueueForTesting()
        try queued.rotate(owner: "different-owner")
        await blocker.release()
        for task in blockerTasks {
            _ = try await task.value
        }
        await Self.expectUnauthorized { try await queuedTask.value }
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 0)
    }

    @Test
    func `cancelled renewal does not write state and next recovery proceeds`() async throws {
        let fixture = try Fixture()
        let blocker = RenewalBlocker()
        let task = Task {
            try await fixture.recover(renew: {
                await blocker.enterAndWait()
                try fixture.rotate()
            })
        }
        await blocker.waitForStarted(1)
        task.cancel()
        await blocker.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.snapshot().credentials.accessToken == Fixture.token("rotated"))
        #expect(fixture.stateFiles.isEmpty)
        _ = try await fixture.recover()
    }

    @Test
    func `cancelling one joined waiter leaves the other successful`() async throws {
        let fixture = try Fixture()
        let blocker = RenewalBlocker()
        let calls = Calls()
        let coordinator = fixture.coordinator()
        let first = Task {
            try await fixture.recover(
                coordinator,
                renew: {
                    await blocker.enterAndWait()
                    try fixture.rotate()
                },
                retry: calls.retry)
        }
        await blocker.waitForStarted(1)
        let second = Task { try await fixture.recover(coordinator, renew: calls.renew, retry: calls.retry) }
        await coordinator.waitForFlightWaitersForTesting(home: fixture.home, count: 2)
        first.cancel()
        await blocker.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        _ = try await second.value
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 1)
        #expect(fixture.stateFiles.isEmpty)
    }

    @Test
    func `cancelling only queued waiter prevents renewal and state`() async throws {
        let blocker = RenewalBlocker()
        let blockerTasks = try (0..<2).map { _ in
            let fixture = try Fixture()
            return Task { try await fixture.recover(renew: { await blocker.enterAndWait() }) }
        }
        await blocker.waitForStarted(2)
        let queued = try Fixture()
        let calls = Calls()
        let queuedTask = Task { try await queued.recover(renew: calls.renew) }
        await CodexManagedWorkspaceRefresh.waitForRenewalGateQueueForTesting()
        queuedTask.cancel()
        await #expect(throws: CancellationError.self) { try await queuedTask.value }
        await blocker.release()
        for task in blockerTasks {
            _ = try await task.value
        }
        #expect(await calls.renewals == 0)
        #expect(queued.stateFiles.isEmpty)
    }

    @Test
    func `completed flights are removed for subsequent recovery on the same coordinator`() async throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator()
        let calls = Calls()
        for _ in 0..<2 {
            _ = try await fixture.recover(coordinator, renew: calls.renew, retry: calls.retry)
        }
        #expect(await calls.renewals == 2)
        #expect(await calls.retries == 2)
    }

    @Test
    func `a changed credential on disk skips renewal and retries the replacement`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        try fixture.rotate()
        let calls = Calls()
        _ = try await fixture.recover(failed: failed, renew: calls.renew, retry: { credentials in
            #expect(credentials.accessToken == Fixture.token("rotated"))
            return try await calls.retry(credentials)
        })
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 1)
    }

    @Test(arguments: [false, true])
    func `concurrent recovery callers perform only one renewal`(separateCoordinators: Bool) async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let shared = fixture.coordinator()
        let calls = Calls()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try await fixture.recover(
                        separateCoordinators ? nil : shared,
                        failed: failed,
                        renew: {
                            await calls.renewed()
                            try await Task.sleep(for: .milliseconds(25))
                            try fixture.rotate()
                        }, retry: { credentials in
                            #expect(credentials.accessToken == Fixture.token("rotated"))
                            return Self.result()
                        })
                }
            }
            try await group.waitForAll()
        }
        #expect(await calls.renewals == 1)
    }

    @Test
    func `unchanged renewal retries scoped usage and stops after three unconfirmed 401 failures`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let now = Date()
        for (index, elapsed) in [0.0, 31.0, 92.0, 7200.0].enumerated() {
            let operation = {
                let now = now.addingTimeInterval(elapsed)
                return try await fixture.recover(failed: failed, now: now, renew: calls.renew) { _ in
                    await calls.retried()
                    throw CodexOAuthFetchError.unauthorized
                }
            }
            if index < 2 {
                await Self.expectTransient(operation)
            } else {
                await Self.expectUnauthorized(operation)
            }
            #expect(await calls.renewals == min(index + 1, 3))
            #expect(await calls.retries == min(index + 1, 3))
        }
    }

    @Test(arguments: ["timeout", "server", "lost-rpc-reply"])
    func `post renewal transient failures retain the CLI credential without rollback`(failure: String) async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        await Self.expectTransient {
            try await fixture.recover(
                failed: failed,
                renew: {
                    await calls.renewed()
                    try fixture.rotate()
                    if failure == "lost-rpc-reply" { throw URLError(.timedOut) }
                },
                retry: { _ in
                    await calls.retried()
                    if failure == "server" { throw CodexOAuthFetchError.serverError(503, "synthetic failure") }
                    throw URLError(.timedOut)
                })
        }
        #expect(await calls.retries == (failure == "lost-rpc-reply" ? 0 : 1))
        let rotated = try fixture.snapshot()
        #expect(rotated.credentials.accessToken == Fixture.token("rotated"))
        #expect(rotated.credentials.refreshToken == "fixture-refresh-rotated")
        // The rotated credential inherits the backoff instead of launching another renewal.
        await Self.expectTransient { try await fixture.recover(failed: rotated, renew: calls.renew) }
        #expect(await calls.renewals == 1)
    }

    @Test
    func `terminal authentication failure stops future renewal and usage retries until a new login`() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        let now = Date()
        await Self.expectUnauthorized {
            try await fixture.recover(
                now: now,
                renew: {
                    await calls.renewed()
                    try fixture.rotate()
                },
                retry: { _ in
                    await calls.retried()
                    throw CodexOAuthFetchError.unauthorized
                })
        }
        await Self.expectUnauthorized {
            try await fixture.recover(now: now.addingTimeInterval(7200), renew: calls.renew, retry: calls.retry)
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 1)

        try fixture.rotate(generation: "new-login")
        _ = try await fixture.recover(now: now.addingTimeInterval(7201), renew: calls.renew, retry: calls.retry)
        #expect(await calls.renewals == 2)
        #expect(await calls.retries == 2)
    }

    @Test
    func `invalid grant stops renewal immediately and preserves its safe reason across restart`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let now = Date()
        for elapsed in [0.0, 7200.0] {
            let error = await #expect(throws: ProviderFetchClassifiedError.self) {
                try await fixture.recover(
                    failed: failed,
                    now: now.addingTimeInterval(elapsed),
                    renew: {
                        await calls.renewed()
                        throw CodexCredentialRefreshError.authentication(.invalidGrant)
                    },
                    retry: calls.retry)
            }
            #expect(error?.kind == .authenticationExpired)
            #expect(error?.message.contains("invalid_grant") == true)
            #expect(error?.message.contains(fixture.home.path) == false)
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 0)
    }

    @Test(arguments: [
        URLError(.timedOut) as any Error & Sendable,
        CodexCredentialRefreshError.requestRejected,
        CodexCredentialRefreshError.invalidResponse,
    ])
    func `transient failures back off across instances until a new login`(failure: any Error & Sendable) async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let now = Date()
        for elapsed in [0.0, 1.0, 29.0, 31.0, 32.0, 90.0] {
            await Self.expectTransient {
                try await fixture.recover(
                    failed: failed,
                    now: now.addingTimeInterval(elapsed),
                    renew: {
                        await calls.renewed()
                        throw failure
                    },
                    retry: calls.retry)
            }
            #expect(await calls.renewals == (elapsed < 31 ? 1 : 2))
        }
        #expect(await calls.retries == 0)
        try fixture.rotate(generation: "new-login")
        _ = try await fixture.recover(now: now.addingTimeInterval(90), renew: calls.renew, retry: calls.retry)
        #expect(await calls.renewals == 3)
        #expect(await calls.retries == 1)
        #expect(fixture.stateFiles.isEmpty)
    }
}

extension CodexManagedCredentialRenewalTests {
    private actor RenewalBlocker {
        private var started = 0
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func enterAndWait() async {
            self.started += 1
            self.startedWaiters.forEach { $0.resume() }
            self.startedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                self.releaseWaiters.append(continuation)
            }
        }

        func waitForStarted(_ expected: Int) async {
            while self.started < expected {
                await withCheckedContinuation { continuation in
                    self.startedWaiters.append(continuation)
                }
            }
        }

        func release() {
            self.releaseWaiters.forEach { $0.resume() }
            self.releaseWaiters.removeAll()
        }
    }

    private actor Calls {
        var renewals = 0
        var retries = 0

        func renewed() { self.renewals += 1 }
        func retried() { self.retries += 1 }

        nonisolated var renew: @Sendable () async throws -> Void {
            { await self.renewed() }
        }

        nonisolated var retry: @Sendable (CodexOAuthCredentials) async throws -> ProviderFetchResult {
            { _ in
                await self.retried()
                return CodexManagedCredentialRenewalTests.result()
            }
        }
    }

    private struct Fixture: Sendable {
        static let workspace = "fixture-workspace"
        let home: URL
        let state: URL
        let originalToken: String
        let email: String
        let subject = "fixture-subject"

        var env: [String: String] {
            ["CODEX_HOME": self.home.path, "HOME": self.home.deletingLastPathComponent().path, "PATH": ""]
        }

        var stateFiles: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: self.state.path)) ?? []
        }

        init(expired: Bool = true, owner: String = Self.workspace, email: String = "fixture@example.test") throws {
            let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
            self.home = root.appendingPathComponent("home")
            self.state = root.appendingPathComponent("state")
            self.originalToken = Self.token("original", expired: expired)
            self.email = email
            try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
            try self.rotate(generation: "original", owner: owner, email: email, expired: expired)
        }

        func coordinator() -> CodexManagedWorkspaceRefresh {
            CodexManagedWorkspaceRefresh(stateDirectory: self.state)
        }

        func snapshot() throws -> CodexManagedWorkspaceRefresh.Snapshot {
            try .read(env: self.env)
        }

        func recover(
            _ coordinator: CodexManagedWorkspaceRefresh? = nil,
            failed: CodexManagedWorkspaceRefresh.Snapshot? = nil,
            now: Date = Date(),
            expectedEmail: String? = nil,
            renew: @escaping @Sendable () async throws -> Void = {},
            retry: @escaping @Sendable (CodexOAuthCredentials) async throws -> ProviderFetchResult = { _ in
                CodexManagedCredentialRenewalTests.result()
            }) async throws -> ProviderFetchResult
        {
            try await (coordinator ?? self.coordinator()).recover(
                home: self.home,
                workspace: Self.workspace,
                failed: failed ?? self.snapshot(),
                env: self.env,
                now: now,
                expectedEmail: expectedEmail,
                renew: renew,
                retry: retry)
        }

        func rotate(
            generation: String = "rotated",
            owner: String = Self.workspace,
            email: String = "fixture@example.test",
            subject: String = "fixture-subject",
            expired: Bool = false) throws
        {
            let data = try JSONSerialization.data(withJSONObject: [
                "tokens": [
                    "access_token": Self.token(generation, expired: expired),
                    "refresh_token": "fixture-refresh-\(generation)",
                    "id_token": Self.encode(#"{"email":"\#(email)","sub":"\#(subject)"}"#, suffix: "signature"),
                    "account_id": owner,
                ],
                "last_refresh": "2000-01-01T00:00:00Z",
            ])
            try data.write(to: self.home.appendingPathComponent("auth.json"), options: .atomic)
        }

        static func token(_ generation: String, expired: Bool = false) -> String {
            self.encode(#"{"exp":\#(expired ? 1 : 4_102_444_800)}"#, suffix: generation)
        }

        private static func encode(_ payload: String, suffix: String) -> String {
            let encoded = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "fixture.\(encoded).\(suffix)"
        }
    }

    private struct ManagedStrategy: ProviderFetchStrategy {
        let fixture: Fixture
        let recovery: CodexManagedWorkspaceRefresh
        let renew: @Sendable () async throws -> Void
        let id = "codex.oauth"
        let kind: ProviderFetchKind = .oauth

        func isAvailable(_ context: ProviderFetchContext) async -> Bool {
            await CodexOAuthFetchStrategy().isAvailable(context)
        }

        func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
            try await CodexOAuthFetchStrategy.fetchManagedWorkspace(
                context,
                home: self.fixture.home,
                workspace: Fixture.workspace,
                recovery: self.recovery,
                renew: self.renew)
        }

        func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
            CodexOAuthFetchStrategy().shouldFallback(on: error, context: context)
        }
    }

    private struct UnavailableStrategy: ProviderFetchStrategy {
        let id: String
        let kind: ProviderFetchKind = .cli

        func isAvailable(_: ProviderFetchContext) async -> Bool { false }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            Issue.record("Managed credential recovery must not use an unscoped fallback")
            throw CodexOAuthFetchError.unauthorized
        }

        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
    }

    private static func context(
        mode: ProviderSourceMode,
        fixture: Fixture,
        workspace: String = Fixture.workspace) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: mode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: fixture.env,
            settings: ProviderSettingsSnapshot.make(codex: CodexProviderSettings(
                usageDataSource: mode == .auto ? .auto : .oauth,
                cookieSource: .off,
                manualCookieHeader: nil,
                managedWorkspaceAccountID: workspace)),
            fetcher: UsageFetcher(environment: fixture.env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    fileprivate static func result() -> ProviderFetchResult {
        ProviderFetchResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            credits: nil,
            dashboard: nil,
            sourceLabel: "oauth",
            strategyID: "codex.oauth",
            strategyKind: .oauth)
    }

    private static func response(_ request: URLRequest, code: Int = 200) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
        let body = #"{"plan_type":"pro","rate_limit":{"primary_window":"#
            + #"{"used_percent":22,"reset_at":4102444800,"limit_window_seconds":18000}}}"#
        return (Data(body.utf8), response)
    }

    private static func expectUnauthorized(_ operation: () async throws -> ProviderFetchResult) async {
        await #expect {
            try await operation()
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired
                && !error.localizedDescription.contains("fixture-refresh")
                && !error.localizedDescription.contains("Bearer")
        }
    }

    private static func expectTransient(_ operation: () async throws -> ProviderFetchResult) async {
        await #expect(throws: CodexManagedWorkspaceRefresh.RecoveryError.self) { try await operation() }
    }
}
