import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NanoGPTPluginTests {
    static let balance = """
    {"usd_balance":"129.46956147","nano_balance":"26.71801147","nanoDepositAddress":"nano_private-response"}
    """

    static let activeSubscription = """
    {"active":true,"state":"active",
     "limits":{"dailyInputTokens":2000000,"weeklyInputTokens":10000000,"dailyImages":null},
     "dailyInputTokens":{"used":500000,"remaining":1500000,"percentUsed":0.25,
       "resetAt":1788000000000,"degraded":false},
     "weeklyInputTokens":{"used":1000000,"remaining":9000000,"percentUsed":0.1,
       "resetAt":1788500000000,"degraded":false},
     "dailyImages":null,"period":{"currentPeriodEnd":"2026-11-20T00:00:00Z"}}
    """

    @Test(arguments: BundledPluginTestSupport.engines)
    func `balance only shows USD headline and Nano detail without the deposit address`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine, subscription: .status(404, "{}"))
        #expect(snapshot.details.first?.rows.map(\.label) == ["USD balance", "Nano balance"])
        #expect(snapshot.details.first?.rows.map(\.value) == ["$129.47", "26.718 XNO"])
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Pay as you go")
        #expect(snapshot.dataConfidence == .exact)
        #expect(!String(describing: snapshot).contains("private-response"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `active subscription adds daily and weekly token windows`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, subscription: .status(200, Self.activeSubscription))
        #expect(snapshot.details.first?.rows.first?.value == "$129.47")
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.windowMinutes == 1440)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_000_000))
        #expect(snapshot.secondary?.usedPercent == 10)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.identity?.loginMethod == "Subscription")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `degraded and null quotas stay unknown instead of full`(engine: ProviderPluginEngineKind) async throws {
        let body = """
        {"active":true,"state":"grace",
         "dailyInputTokens":{"used":0,"remaining":0,"percentUsed":100,"resetAt":null,"degraded":true},
         "weeklyInputTokens":null,"dailyImages":null}
        """
        let snapshot = try await Self.fetch(engine: engine, subscription: .status(200, body))
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Subscription (grace)")
        #expect(snapshot.details.first?.rows.first?.value == "$129.47")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `inactive subscription shows the balance only`(engine: ProviderPluginEngineKind) async throws {
        let body = """
        {"active":false,"state":"inactive",
         "dailyInputTokens":{"used":1,"remaining":1,"percentUsed":50,"resetAt":null,"degraded":false},
         "weeklyInputTokens":null,"dailyImages":null}
        """
        let snapshot = try await Self.fetch(engine: engine, subscription: .status(200, body))
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.identity?.loginMethod == "Pay as you go")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `subscription endpoint failures keep the balance`(engine: ProviderPluginEngineKind) async throws {
        for subscription in [Subscription.status(500, "private-response"), .status(200, "not json"), .failure] {
            let snapshot = try await Self.fetch(engine: engine, subscription: subscription)
            #expect(snapshot.details.first?.rows.first?.value == "$129.47")
            #expect(snapshot.primary == nil)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `string and numeric balances parse including zero and negative values`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (raw, expected) in [(#""0""#, "$0.00"), ("12.5", "$12.50"), (#""-1.25""#, "-$1.25"), (#"" 3 ""#, "$3.00")] {
            let snapshot = try await Self.fetch(
                #"{"usd_balance":\#(raw)}"#, engine: engine, subscription: .status(404, "{}"))
            #expect(snapshot.details.first?.rows.map(\.value) == [expected])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing or malformed balances fail closed`(engine: ProviderPluginEngineKind) async {
        let bodies = [
            "private-response",
            "null",
            "[]",
            "{}",
            #"{"usd_balance":"abc"}"#,
            #"{"usd_balance":null}"#,
            #"{"usd_balance":"1e400x"}"#,
        ]
        for body in bodies {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid keys and transient errors are classified without echoing bodies`(
        engine: ProviderPluginEngineKind) async
    {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .authenticationExpired),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            await Self.expectFailure(
                #"{"error":401,"message":"private-response"}"#, engine: engine, code: code, kind: kind)
        }
    }

    @Test
    func `credentials stay explicit and provider defaults off`() throws {
        let descriptor = NanoGPTProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        #expect(!descriptor.metadata.defaultEnabled)
        #expect(descriptor.metadata.dashboardURL == "https://nano-gpt.com/balance")
        #expect(credentials.resolveToken(environment: ["NANOGPT_API_KEY": "fixture-key"])?.token == "fixture-key")
        #expect(credentials.resolveToken(environment: ["NANOGPT_API_KEY": "  "]) == nil)
        #expect(ProviderDescriptorRegistry.descriptor(for: .nanogpt).cli.aliases == ["nano-gpt"])
    }

    enum Subscription {
        case status(Int, String)
        case failure
    }

    private struct TransportFailure: Error {}

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code, subscription: .status(404, "{}"))
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        _ body: String = Self.balance,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        subscription: Subscription) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "nanogpt",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let url = try #require(request.url)
                func respond(_ status: Int, _ text: String) throws -> (Data, HTTPURLResponse) {
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                    return (Data(text.utf8), response)
                }
                if url.absoluteString == "https://nano-gpt.com/api/check-balance" {
                    #expect(request.httpMethod == "POST")
                    return try respond(code, body)
                }
                #expect(url.absoluteString == "https://nano-gpt.com/api/subscription/v1/usage")
                #expect(request.httpMethod == "GET")
                switch subscription {
                case let .status(status, text): return try respond(status, text)
                case .failure: throw TransportFailure()
                }
            })
        return try await runtime.fetchUsage(secrets: ["NANOGPT_API_KEY": "fixture-key"])
    }
}
