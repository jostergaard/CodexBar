import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NanoGPTPluginTests {
    private static let balance =
        #"{"usd_balance":"129.46956147","nano_balance":"26.71801147","nanoDepositAddress":"private-response"}"#
    private static let subscription = """
    {"active":true,"state":"active",
     "dailyInputTokens":{"used":500000,"remaining":1500000,"percentUsed":0.25,"resetAt":1788000000000},
     "weeklyInputTokens":{"used":1000000,"remaining":9000000,"percentUsed":0.1,"resetAt":1788500000000}}
    """

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance only shows USD headline and Nano detail`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(engine)
        #expect(usage.details.first?.rows.map(\.value) == ["$129.47", "26.718 XNO"])
        #expect(usage.primary == nil)
        #expect(usage.identity?.loginMethod == "Pay as you go")
        #expect(!String(describing: usage).contains("private-response"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `active subscription adds daily and weekly token windows`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(engine, subscription: .status(200, Self.subscription))
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 1440)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_000_000))
        #expect(usage.secondary?.usedPercent == 10)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.identity?.loginMethod == "Subscription")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unusable subscriptions keep only the balance`(engine: ProviderPluginEngineKind) async throws {
        let degraded = #"{"active":true,"state":"grace","dailyInputTokens":{"used":0,"remaining":0,"degraded":true}}"#
        let inactive = Self.subscription.replacingOccurrences(of: #""active":true"#, with: #""active":false"#)
        for subscription in [
            Subscription.status(200, degraded), .status(200, inactive), .status(500, "private-response"),
            .status(200, "not json"), .failure,
        ] {
            let usage = try await Self.fetch(engine, subscription: subscription)
            #expect(usage.details.first?.rows.first?.value == "$129.47")
            #expect(usage.primary == nil)
            #expect(usage.secondary == nil)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balances parse zero and negative values but malformed ones fail`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (raw, expected) in [(#""0""#, "$0.00"), ("12.5", "$12.50"), (#""-1.25""#, "-$1.25")] {
            let usage = try await Self.fetch(engine, body: #"{"usd_balance":\#(raw)}"#)
            #expect(usage.details.first?.rows.map(\.value) == [expected])
        }
        for body in ["private-response", "[]", "{}", #"{"usd_balance":"abc"}"#, #"{"usd_balance":null}"#] {
            await Self.expectFailure(engine, body: body, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures are classified without echoing bodies`(engine: ProviderPluginEngineKind) async {
        for (status, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .authenticationExpired),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure(engine, body: "private-response", status: status, kind: kind)
        }
    }

    private enum Subscription {
        case status(Int, String)
        case failure
    }

    private struct TransportFailure: Error {}

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
        body: String = Self.balance,
        status: Int = 200,
        subscription: Subscription = .status(404, "{}")) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "nanogpt", engine: engine, transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
                let url = try #require(request.url)
                var reply = (status, body)
                if url.absoluteString == "https://nano-gpt.com/api/check-balance" {
                    #expect(request.httpMethod == "POST")
                } else {
                    #expect(url.absoluteString == "https://nano-gpt.com/api/subscription/v1/usage")
                    guard case let .status(code, text) = subscription else { throw TransportFailure() }
                    reply = (code, text)
                }
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: reply.0, httpVersion: nil, headerFields: nil))
                return (Data(reply.1.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["NANOGPT_API_KEY": "fixture-key"])
    }
}
