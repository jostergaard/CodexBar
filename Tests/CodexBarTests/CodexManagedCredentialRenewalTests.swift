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
        let context = Self.context(mode: mode, fixture: fixture)
        let recovery = fixture.coordinator()
        let pipeline = ProviderFetchPipeline { context in
            let strategies = await CodexProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
            return strategies.map { strategy -> any ProviderFetchStrategy in
                if strategy.id == "codex.oauth" {
                    return ManagedStrategy(fixture: fixture, recovery: recovery, renew: {
                        await calls.renewed()
                        try fixture.rotate()
                    })
                }
                return UnavailableStrategy(id: strategy.id, kind: strategy.kind)
            }
        }
        let outcome = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await pipeline.fetch(context: context, provider: .codex)
        }
        let result = try outcome.result.get()
        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.primary?.usedPercent == 22)
        #expect(outcome.attempts.filter(\.wasAvailable).map(\.strategyID) == ["codex.oauth"])
        #expect(await calls.renewals == 1)
        #expect(await transport.requests().count == (expired ? 1 : 2))
        #expect(try fixture.snapshot().credentials.accessToken == Fixture.token("rotated"))
    }

    @Test
    func `alternate selected workspace recovers while preserving selected usage header`() async throws {
        let fixture = try Fixture(expired: false)
        try fixture.rotate(
            generation: "original", owner: "native-default", email: "fixture@example.test", expired: false)
        let calls = Calls()
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "selected-workspace")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fixture.originalToken)" {
                return try Self.response(request, code: 401)
            }
            return try Self.response(request)
        }
        let context = Self.context(mode: .oauth, fixture: fixture, workspace: "selected-workspace")
        let result = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await CodexOAuthFetchStrategy.fetchManagedWorkspace(
                context, home: fixture.home, workspace: "selected-workspace", recovery: fixture.coordinator(), renew: {
                    await calls.renewed()
                    try fixture.rotate(owner: "native-default", email: "fixture@example.test")
                })
        }
        #expect(result.sourceLabel == "oauth")
        #expect(await calls.renewals == 1)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `each selected account with a shared workspace renews its own email`() async throws {
        let fixtures = try (0..<5).map { index in
            try Fixture(email: "account\(index)@example.test")
        }
        for fixture in fixtures {
            let failed = try fixture.snapshot()
            let calls = Calls()
            _ = try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: failed,
                env: fixture.env,
                expectedEmail: fixture.email,
                renew: { await calls.renewed() },
                retry: { credentials in
                    await calls.retried()
                    #expect(credentials.accessToken == fixture.originalToken)
                    return Self.result()
                })
            #expect(await calls.renewals == 1)
            #expect(await calls.retries == 1)
        }
    }

    @Test(arguments: [false, true])
    func `renewal rejects a changed email or subject before usage retry`(changedSubject: Bool) async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        await Self.expectUnauthorized {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: failed,
                env: fixture.env,
                expectedEmail: fixture.email,
                renew: {
                    await calls.renewed()
                    try fixture.rotate(
                        email: changedSubject ? fixture.email : "different@example.test",
                        subject: changedSubject ? "different-subject" : fixture.subject)
                },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 0)
    }

    @Test
    func `email mismatch before launch rejects without renewal or retry`() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        await Self.expectUnauthorized {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: fixture.snapshot(),
                env: fixture.env,
                expectedEmail: "not-the-selected-account@example.test",
                renew: { await calls.renewed() },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 0)
    }

    @Test
    func `cancelled renewal does not write state and next recovery proceeds`() async throws {
        let fixture = try Fixture()
        let renewalBlocker = RenewalBlocker()
        let renewalStarted = AsyncStream<Void>.makeStream()
        let task = Task {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: fixture.snapshot(),
                env: fixture.env,
                renew: {
                    renewalStarted.continuation.yield()
                    await renewalBlocker.enterAndWait()
                    try fixture.rotate()
                },
                retry: { _ in Self.result() })
        }
        var iterator = renewalStarted.stream.makeAsyncIterator()
        _ = await iterator.next()
        await renewalBlocker.waitForStarted(1)
        task.cancel()
        await renewalBlocker.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.snapshot().credentials.accessToken == Fixture.token("rotated"))
        let stateFiles = (try? FileManager.default.contentsOfDirectory(
            at: fixture.state,
            includingPropertiesForKeys: nil)) ?? []
        #expect(stateFiles.isEmpty)
        _ = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: fixture.snapshot(),
            env: fixture.env,
            renew: {},
            retry: { _ in Self.result() })
    }

    @Test
    func `cancelling one joined waiter leaves the other successful`() async throws {
        let fixture = try Fixture()
        let blocker = RenewalBlocker()
        let started = AsyncStream<Void>.makeStream()
        let calls = Calls()
        let coordinator = fixture.coordinator()
        let first = Task {
            try await coordinator.recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: fixture.snapshot(),
                env: fixture.env,
                renew: {
                    started.continuation.yield()
                    await blocker.enterAndWait()
                    try fixture.rotate()
                },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task {
            try await coordinator.recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: fixture.snapshot(),
                env: fixture.env,
                renew: { await calls.renewed() },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        await coordinator.waitForFlightWaitersForTesting(home: fixture.home, count: 2)
        first.cancel()
        await blocker.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        _ = try await second.value
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test
    func `cancelling only queued waiter prevents renewal and state`() async throws {
        let blockers = try (0..<2).map { _ in try Fixture() }
        let queued = try Fixture()
        let blocker = RenewalBlocker()
        let blockerTasks = blockers.map { fixture in
            Task {
                try await fixture.coordinator().recover(
                    home: fixture.home,
                    workspace: Fixture.workspace,
                    failed: fixture.snapshot(),
                    env: fixture.env,
                    renew: { await blocker.enterAndWait() },
                    retry: { _ in Self.result() })
            }
        }
        await blocker.waitForStarted(2)
        let calls = Calls()
        let queuedTask = Task {
            try await queued.coordinator().recover(
                home: queued.home,
                workspace: Fixture.workspace,
                failed: queued.snapshot(),
                env: queued.env,
                renew: { await calls.renewed() },
                retry: { _ in Self.result() })
        }
        await CodexManagedWorkspaceRefresh.waitForRenewalGateQueueForTesting()
        queuedTask.cancel()
        await #expect(throws: CancellationError.self) { try await queuedTask.value }
        await blocker.release()
        for task in blockerTasks {
            _ = try await task.value
        }
        #expect(await calls.renewals == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: queued.state.path).isEmpty)
    }

    @Test
    func `already cancelled recovery does not renew retry or write state`() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        let task = Task {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: fixture.snapshot(),
                env: fixture.env,
                renew: { await calls.renewed() },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.renewals == 0)
        #expect(await calls.retries == 0)
        let stateFiles = (try? FileManager.default.contentsOfDirectory(
            at: fixture.state,
            includingPropertiesForKeys: nil)) ?? []
        #expect(stateFiles.isEmpty)
    }

    @Test
    func `queued renewal rechecks ownership after both gate slots are released`() async throws {
        let blockers = try (0..<2).map { _ in try Fixture() }
        let queued = try Fixture()
        let blocker = RenewalBlocker()
        let blockerTasks = blockers.map { fixture in
            Task {
                try await fixture.coordinator().recover(
                    home: fixture.home,
                    workspace: Fixture.workspace,
                    failed: fixture.snapshot(),
                    env: fixture.env,
                    renew: { await blocker.enterAndWait() },
                    retry: { _ in Self.result() })
            }
        }
        await blocker.waitForStarted(2)
        let queuedCalls = Calls()
        let queuedTask = Task {
            try await queued.coordinator().recover(
                home: queued.home,
                workspace: Fixture.workspace,
                failed: queued.snapshot(),
                env: queued.env,
                expectedEmail: queued.email,
                renew: { await queuedCalls.renewed() },
                retry: { _ in
                    await queuedCalls.retried()
                    return Self.result()
                })
        }
        await CodexManagedWorkspaceRefresh.waitForRenewalGateQueueForTesting()
        try queued.rotate(owner: "different-owner")
        await blocker.release()
        for task in blockerTasks {
            _ = try await task.value
        }
        do {
            _ = try await queuedTask.value
            Issue.record("Queued ownership mismatch must fail")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .authenticationExpired)
            #expect(error.message.contains("ownershipMismatch"))
        } catch {
            Issue.record("Queued ownership mismatch must remain terminal")
        }
        #expect(await queuedCalls.renewals == 0)
        #expect(await queuedCalls.retries == 0)
    }

    @Test
    func `ownership mismatch state clears when the correct login is restored`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        await Self.expectUnauthorized {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: failed,
                env: fixture.env,
                expectedEmail: fixture.email,
                renew: {
                    await calls.renewed()
                    try fixture.rotate(owner: "different-owner")
                },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 0)

        try fixture.rotate(generation: "new-login")
        let restored = try fixture.snapshot()
        _ = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: restored,
            env: fixture.env,
            renew: { await calls.renewed() },
            retry: { _ in
                await calls.retried()
                return Self.result()
            })
        #expect(await calls.renewals == 2)
        #expect(await calls.retries == 1)
    }

    @Test
    func `completed flights are removed for subsequent recovery on the same coordinator`() async throws {
        let fixture = try Fixture()
        let coordinator = fixture.coordinator()
        let calls = Calls()
        for _ in 0..<2 {
            _ = try await coordinator.recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: fixture.snapshot(),
                env: fixture.env,
                renew: { await calls.renewed() },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 2)
        #expect(await calls.retries == 2)
    }

    @Test
    func `camel case account identity remains eligible for renewal`() async throws {
        let fixture = try Fixture()
        try fixture.rotate(camelCaseAccountID: true)
        let calls = Calls()
        _ = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: fixture.snapshot(),
            env: fixture.env,
            renew: { await calls.renewed() },
            retry: { _ in
                await calls.retried()
                return Self.result()
            })
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 1)
    }

    @Test
    func `renewal rejects a credential belonging to another workspace before usage retry`() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        let failed = try fixture.snapshot()
        await Self.expectUnauthorized {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: failed,
                env: fixture.env,
                renew: {
                    await calls.renewed()
                    try fixture.rotate(owner: "other-workspace")
                }, retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 0)
        #expect(try fixture.snapshot().owner == "other-workspace")
    }

    @Test
    func `a changed credential on disk skips renewal and retries the replacement`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        try fixture.rotate()
        let calls = Calls()
        _ = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: failed,
            env: fixture.env,
            renew: { await calls.renewed() },
            retry: { credentials in
                await calls.retried()
                #expect(credentials.accessToken == Fixture.token("rotated"))
                return Self.result()
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
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let recovery = separateCoordinators ? fixture.coordinator() : shared
                    let result = try await recovery.recover(
                        home: fixture.home,
                        workspace: Fixture.workspace,
                        failed: failed,
                        env: fixture.env,
                        renew: {
                            await calls.renewed()
                            try await Task.sleep(for: .milliseconds(25))
                            try fixture.rotate()
                        }, retry: { credentials in
                            #expect(credentials.accessToken == Fixture.token("rotated"))
                            return Self.result()
                        })
                    return result.sourceLabel
                }
            }
            var results: [String] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        #expect(results == Array(repeating: "oauth", count: 8))
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
                try await fixture.coordinator().recover(
                    home: fixture.home,
                    workspace: Fixture.workspace,
                    failed: failed,
                    env: fixture.env,
                    now: now.addingTimeInterval(elapsed),
                    renew: { await calls.renewed() },
                    retry: { _ in
                        await calls.retried()
                        throw CodexOAuthFetchError.unauthorized
                    })
            }
            if index < 2 {
                await Self.expectTransient(operation)
            } else {
                await Self.expectUnauthorized(operation)
            }
            #expect(await calls.renewals == min(index + 1, 3))
            #expect(await calls.retries == min(index + 1, 3))
        }
        #expect(try fixture.snapshot().fingerprint == failed.fingerprint)
    }

    @Test
    func `unchanged renewal succeeds when the scoped usage retry accepts the credential`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let result = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: failed,
            env: fixture.env,
            renew: { await calls.renewed() },
            retry: { credentials in
                await calls.retried()
                #expect(credentials.accessToken == fixture.originalToken)
                return Self.result()
            })
        #expect(result.sourceLabel == "oauth")
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 1)
        #expect(try fixture.snapshot().fingerprint == failed.fingerprint)
    }
}

extension CodexManagedCredentialRenewalTests {
    @Test(arguments: ["timeout", "server", "lost-rpc-reply"])
    func `post renewal transient failures retain the CLI credential without rollback`(failure: String) async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let recovery = fixture.coordinator()
        await Self.expectTransient {
            try await recovery.recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: failed,
                env: fixture.env,
                renew: {
                    await calls.renewed()
                    try fixture.rotate()
                    if failure == "lost-rpc-reply" { throw URLError(.timedOut) }
                }, retry: { _ in
                    await calls.retried()
                    if failure == "server" { throw CodexOAuthFetchError.serverError(503, "synthetic failure") }
                    throw URLError(.timedOut)
                })
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == (failure == "lost-rpc-reply" ? 0 : 1))
        let rotated = try fixture.snapshot()
        #expect(rotated.credentials.accessToken == Fixture.token("rotated"))
        #expect(rotated.credentials.refreshToken == "fixture-refresh-rotated")
        #expect(rotated.fingerprint != failed.fingerprint)
        await Self.expectTransient {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: rotated,
                env: fixture.env,
                renew: { await calls.renewed() },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 1)
    }

    @Test
    func `terminal authentication failure stops future renewal and usage retries until a new login`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let now = Date()
        await Self.expectUnauthorized {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: failed,
                env: fixture.env,
                now: now,
                renew: {
                    await calls.renewed()
                    try fixture.rotate()
                }, retry: { _ in
                    await calls.retried()
                    throw CodexOAuthFetchError.unauthorized
                })
        }
        let rotated = try fixture.snapshot()
        await Self.expectUnauthorized {
            try await fixture.coordinator().recover(
                home: fixture.home,
                workspace: Fixture.workspace,
                failed: rotated,
                env: fixture.env,
                now: now.addingTimeInterval(7200),
                renew: { await calls.renewed() },
                retry: { _ in
                    await calls.retried()
                    return Self.result()
                })
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 1)

        try fixture.rotate(generation: "new-login")
        let login = try fixture.snapshot()
        _ = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: login,
            env: fixture.env,
            now: now.addingTimeInterval(7201),
            renew: {
                await calls.renewed()
                try fixture.rotate(generation: "renewed-login")
            }, retry: { _ in
                await calls.retried()
                return Self.result()
            })
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
            do {
                _ = try await fixture.coordinator().recover(
                    home: fixture.home,
                    workspace: Fixture.workspace,
                    failed: failed,
                    env: fixture.env,
                    now: now.addingTimeInterval(elapsed),
                    renew: {
                        await calls.renewed()
                        throw CodexCredentialRefreshError.authentication(.invalidGrant)
                    }, retry: { _ in
                        await calls.retried()
                        return Self.result()
                    })
                Issue.record("Invalid grant must require a new login")
            } catch {
                let classified = try #require(error as? ProviderFetchClassifiedError)
                #expect(classified.kind == .authenticationExpired)
                #expect(classified.message.contains(CodexCredentialRefreshAuthReason.invalidGrant.rawValue))
                #expect(!classified.message.contains(fixture.originalToken))
                #expect(!classified.message.contains("fixture-refresh"))
                #expect(!classified.message.contains(fixture.home.path))
            }
        }
        #expect(await calls.renewals == 1)
        #expect(await calls.retries == 0)
        #expect(try fixture.snapshot().fingerprint == failed.fingerprint)
    }

    @Test(arguments: [false, true])
    func `unknown RPC rejection and invalid response remain transient after restart`(
        invalidResponse: Bool) async throws
    {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let now = Date()
        for elapsed in [0.0, 1.0, 31.0] {
            await Self.expectTransient {
                try await fixture.coordinator().recover(
                    home: fixture.home,
                    workspace: Fixture.workspace,
                    failed: failed,
                    env: fixture.env,
                    now: now.addingTimeInterval(elapsed),
                    renew: {
                        await calls.renewed()
                        throw invalidResponse
                            ? CodexCredentialRefreshError.invalidResponse
                            : CodexCredentialRefreshError.requestRejected
                    }, retry: { _ in
                        await calls.retried()
                        return Self.result()
                    })
            }
            #expect(await calls.renewals == (elapsed < 31 ? 1 : 2))
        }
        #expect(await calls.retries == 0)
        #expect(try fixture.snapshot().fingerprint == failed.fingerprint)
    }

    @Test
    func `transient backoff persists across instances and a new login fingerprint resets it`() async throws {
        let fixture = try Fixture()
        let failed = try fixture.snapshot()
        let calls = Calls()
        let now = Date()
        for elapsed in [0.0, 1.0, 29.0, 31.0, 32.0, 90.0] {
            await Self.expectTransient {
                try await fixture.coordinator().recover(
                    home: fixture.home,
                    workspace: Fixture.workspace,
                    failed: failed,
                    env: fixture.env,
                    now: now.addingTimeInterval(elapsed),
                    renew: {
                        await calls.renewed()
                        throw URLError(.timedOut)
                    }, retry: { _ in
                        await calls.retried()
                        return Self.result()
                    })
            }
            #expect(await calls.renewals == (elapsed < 31 ? 1 : 2))
        }
        #expect(await calls.retries == 0)
        try fixture.rotate(generation: "new-login")
        let login = try fixture.snapshot()
        _ = try await fixture.coordinator().recover(
            home: fixture.home,
            workspace: Fixture.workspace,
            failed: login,
            env: fixture.env,
            now: now.addingTimeInterval(90),
            renew: {
                await calls.renewed()
                try fixture.rotate(generation: "renewed-login")
            }, retry: { _ in
                await calls.retried()
                return Self.result()
            })
        #expect(await calls.renewals == 3)
        #expect(await calls.retries == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.state.path).isEmpty)
    }

    @Test(arguments: [ProviderSourceMode.auto, .oauth])
    func `managed OAuth retries a renewed token only once when usage still returns 401`(
        mode: ProviderSourceMode) async throws
    {
        let fixture = try Fixture(expired: false)
        let calls = Calls()
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == Fixture.workspace)
            return try Self.response(request, code: 401)
        }
        await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            for _ in 0..<2 {
                await Self.expectUnauthorized {
                    try await CodexOAuthFetchStrategy.fetchManagedWorkspace(
                        Self.context(
                            mode: mode,
                            fixture: fixture),
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
        #expect(try fixture.snapshot().credentials.accessToken == Fixture.token("rotated"))
    }

    @Test
    func `simultaneous workspace 401 failures cap renewal concurrency across separate homes`() async throws {
        let fixtures = try (0..<6).map { _ in try Fixture(expired: false) }
        for (index, fixture) in fixtures.enumerated() {
            try fixture.rotate(generation: "original-\(index)", owner: "workspace-\(index)")
        }
        let calls = Calls()
        let transport = ProviderHTTPTransportStub { request in
            let owner = try #require(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
            let index = try #require(Int(owner.replacingOccurrences(of: "workspace-", with: "")))
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer \(Fixture.token("original-\(index)"))" {
                return try Self.response(request, code: 401)
            }
            #expect(authorization == "Bearer \(Fixture.token("rotated-\(index)"))")
            return try Self.response(request)
        }
        let results = try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try await withThrowingTaskGroup(of: Double?.self) { group in
                for (index, fixture) in fixtures.enumerated() {
                    group.addTask {
                        let workspace = "workspace-\(index)"
                        let context = Self.context(mode: .auto, fixture: fixture, workspace: workspace)
                        let result = try await CodexOAuthFetchStrategy.fetchManagedWorkspace(
                            context,
                            home: fixture.home,
                            workspace: workspace,
                            recovery: fixture.coordinator(),
                            renew: {
                                await calls.beganRenewal()
                                try await Task.sleep(for: .milliseconds(40))
                                try fixture.rotate(generation: "rotated-\(index)", owner: workspace)
                                await calls.finishedRenewal()
                            })
                        return result.usage.primary?.usedPercent
                    }
                }
                var results: [Double?] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }
        }
        #expect(results == Array(repeating: 22, count: fixtures.count))
        #expect(await calls.renewals == fixtures.count)
        #expect(await calls.maximumConcurrentRenewals <= 2)
        #expect(await transport.requests().count == fixtures.count * 2)
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
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.releaseWaiters.append(continuation)
                }
            } onCancel: {
                Task { await self.release() }
            }
        }

        func waitForStarted(_ expected: Int) async {
            if self.started >= expected { return }
            await withCheckedContinuation { continuation in
                self.startedWaiters.append(continuation)
            }
            await self.waitForStarted(expected)
        }

        func release() {
            self.releaseWaiters.forEach { $0.resume() }
            self.releaseWaiters.removeAll()
        }
    }

    private actor Calls {
        var renewals = 0
        var retries = 0
        var activeRenewals = 0
        var maximumConcurrentRenewals = 0

        func beganRenewal() {
            self.renewals += 1
            self.activeRenewals += 1
            self.maximumConcurrentRenewals = max(self.maximumConcurrentRenewals, self.activeRenewals)
        }

        func finishedRenewal() { self.activeRenewals -= 1 }

        func renewed() { self.renewals += 1 }
        func retried() { self.retries += 1 }
    }

    private struct Fixture: Sendable {
        static let workspace = "fixture-workspace"
        let home: URL
        let state: URL
        let originalToken: String
        let email: String
        let subject: String

        var env: [String: String] {
            ["CODEX_HOME": self.home.path, "HOME": self.home.deletingLastPathComponent().path, "PATH": ""]
        }

        init(expired: Bool = true, email: String = "fixture@example.test", subject: String = "fixture-subject") throws {
            let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
            self.home = root.appendingPathComponent("home")
            self.state = root.appendingPathComponent("state")
            self.originalToken = Self.token("original", expired: expired)
            self.email = email
            self.subject = subject
            try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
            try self.rotate(generation: "original", email: email, subject: subject, expired: expired)
        }

        func coordinator() -> CodexManagedWorkspaceRefresh {
            CodexManagedWorkspaceRefresh(stateDirectory: self.state)
        }

        func snapshot() throws -> CodexManagedWorkspaceRefresh.Snapshot {
            try .read(env: self.env)
        }

        func rotate(
            generation: String = "rotated",
            owner: String = Self.workspace,
            email: String = "fixture@example.test",
            subject: String = "fixture-subject",
            expired: Bool = false,
            camelCaseAccountID: Bool = false) throws
        {
            let tokenFields: [String: String] = [
                "access_token": Self.token(generation, expired: expired),
                "refresh_token": "fixture-refresh-\(generation)",
                "id_token": Self.idToken(email: email, subject: subject),
            ]
            var tokens = tokenFields
            tokens[camelCaseAccountID ? "accountId" : "account_id"] = owner
            let data = try JSONSerialization.data(withJSONObject: [
                "tokens": tokens,
                "last_refresh": "2000-01-01T00:00:00Z",
            ], options: .sortedKeys)
            try data.write(to: self.home.appendingPathComponent("auth.json"), options: .atomic)
        }

        static func token(_ generation: String, expired: Bool = false) -> String {
            let payload = Data(#"{"exp":\#(expired ? 1 : 4_102_444_800)}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "fixture.\(payload).\(generation)"
        }

        static func idToken(email: String, subject: String) -> String {
            let payload = Data(#"{"email":"\#(email)","sub":"\#(subject)"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "fixture.\(payload).signature"
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
        let kind: ProviderFetchKind

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

    private static func result() -> ProviderFetchResult {
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
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: code, httpVersion: nil, headerFields: nil))
        let body = #"""
        {"plan_type":"pro","rate_limit":{
          "primary_window":{"used_percent":22,"reset_at":4102444800,"limit_window_seconds":18000}
        }}
        """#
        return (Data(body.utf8), response)
    }

    private static func expectUnauthorized(_ operation: () async throws -> ProviderFetchResult) async {
        do {
            _ = try await operation()
            Issue.record("Expected terminal authentication failure")
        } catch {
            #expect((error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired)
            #expect(!error.localizedDescription.contains("fixture-refresh"))
            #expect(!error.localizedDescription.contains("Bearer"))
        }
    }

    private static func expectTransient(_ operation: () async throws -> ProviderFetchResult) async {
        do {
            _ = try await operation()
            Issue.record("Expected transient credential recovery failure")
        } catch {
            #expect(error is CodexManagedWorkspaceRefresh.RecoveryError)
        }
    }
}
