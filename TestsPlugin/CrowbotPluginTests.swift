import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CrowbotPluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `pay as you go shows balance spend requests and blocked spending`(
        engine: ProviderPluginEngineKind) async throws
    {
        let body = #"{"balance_microdollars":12500000,"spent_microdollars":3250000,"request_count":1234,"#
            + #""can_spend":false,"key_hint":"private-response","pass":null}"#
        let usage = try await Self.fetch(engine, body: body)
        let rows = try #require(usage.details.first?.rows)
        #expect(rows.map(\.label) == ["USD balance", "Total spent", "Requests", "Status"])
        #expect(rows.map(\.value) == ["$12.50", "$3.25", "1,234", "Spending blocked"])
        #expect(rows.last?.severity == .warning)
        #expect(usage.primary == nil)
        #expect(usage.identity?.loginMethod == "Pay as you go")
        #expect(!String(describing: usage).contains("private-response"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `spend and request aliases are accepted`(engine: ProviderPluginEngineKind) async throws {
        for (body, expected) in [
            (#"{"balance_microdollars":1000000,"total_spent_microdollars":500000,"requests":7}"#, ["$0.50", "7"]),
            (#"{"balance_microdollars":1000000,"spent_usd":2.5,"requests":"8"}"#, ["$2.50", "8"]),
            (#"{"balance_microdollars":-250000,"total_spent_usd":"1.75"}"#, ["$1.75"]),
        ] {
            let usage = try await Self.fetch(engine, body: body)
            #expect(usage.details.first?.rows.dropFirst().map(\.value) == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `active pass maps allowance refill and end date`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(
            engine,
            pass: #"{"plan":"starter","allowance_bp":2500,"#
                + #""refills":"2026-11-14T03:00:00Z","ends_at":"2026-12-01T12:00:00Z"}"#)
        #expect(usage.primary?.usedPercent == 75)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-14T03:00:00Z"))
        #expect(usage.identity?.loginMethod == "Starter pass")
        #expect(usage.details.last?.title == "Pass")
        #expect(usage.details.last?.rows.map(\.value) == ["Dec 1"])
        for refills in ["1794003600", "1794003600000"] {
            let epoch = try await Self.fetch(
                engine, pass: #"{"plan_id":"hyperscaler","allowance_bp":12000,"refills":\#(refills)}"#)
            #expect(epoch.primary?.usedPercent == 0)
            #expect(epoch.primary?.resetsAt == Date(timeIntervalSince1970: 1_794_003_600))
            #expect(epoch.identity?.loginMethod == "Hyperscaler pass")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pass without allowance shows textual refills without inventing usage`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(
            engine, pass: #"{"plan":"fixture-plan","label":"Fixture Plan","refills":"in about 4 hours"}"#)
        #expect(usage.identity?.loginMethod == "Fixture Plan pass")
        #expect(usage.primary == nil)
        #expect(usage.details.last?.rows.map(\.value) == ["in about 4 hours"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing balances and HTTP failures are classified without echoing bodies`(
        engine: ProviderPluginEngineKind) async
    {
        for body in ["private-response", "[]", "{}", #"{"balance_microdollars":"12.5"}"#, #"{"balance_usd":1}"#] {
            await Self.expectFailure(engine, body: body, kind: .parseFailure)
        }
        for (status, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (500, .providerUnavailable), (404, .apiFailure),
        ] {
            await Self.expectFailure(engine, body: "private-response", status: status, kind: kind)
        }
    }

    private static func expectFailure(
        _ engine: ProviderPluginEngineKind,
        body: String,
        status: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        await #expect {
            try await Self.fetch(engine, body: body, status: status)
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == kind
                && !error.localizedDescription.contains("private-response")
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        body: String? = nil,
        pass: String = "null",
        status: Int = 200) async throws -> UsageSnapshot
    {
        let body = body ?? #"{"balance_microdollars":"4000000","pass":\#(pass)}"#
        let runtime = try BundledPluginTestSupport.runtime(
            "crowbot", engine: engine, transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                #expect(url.absoluteString == "https://api.crowbot.sh/api/me")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["CROWBOT_API_KEY": "fixture-key"])
    }
}
