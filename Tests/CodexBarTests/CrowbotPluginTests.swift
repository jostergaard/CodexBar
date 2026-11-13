import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CrowbotPluginTests {
    static let payAsYouGo = """
    {"balance_microdollars":12500000,"spent_microdollars":3250000,"request_count":1234,"can_spend":true,
     "key_hint":"private-response","pass":null,"balance_fallback":true,
     "site":"https://chat.crowbot.sh","api":"https://api.crowbot.sh"}
    """

    static func passBody(_ pass: String, extra: String = "") -> String {
        #"{"balance_microdollars":"4000000"\#(extra),"pass":\#(pass)}"#
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pay as you go shows balance spend and requests without a pass window`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.payAsYouGo, engine: engine)
        #expect(snapshot.details.count == 1)
        #expect(snapshot.details.first?.title == "Account balance")
        #expect(snapshot.details.first?.rows.map(\.label) == ["USD balance", "Total spent", "Requests"])
        #expect(snapshot.details.first?.rows.map(\.value) == ["$12.50", "$3.25", "1,234"])
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Pay as you go")
        #expect(snapshot.dataConfidence == .exact)
        #expect(!String(describing: snapshot).contains("private-response"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `spend and request aliases are accepted`(engine: ProviderPluginEngineKind) async throws {
        let bodies: [(String, [String])] = [
            (#"{"balance_microdollars":1000000,"total_spent_microdollars":500000,"requests":7}"#, ["$0.50", "7"]),
            (#"{"balance_microdollars":1000000,"spent_usd":2.5,"requests":"8"}"#, ["$2.50", "8"]),
            (#"{"balance_microdollars":1000000,"total_spent_usd":"1.75"}"#, ["$1.75"]),
        ]
        for (body, expected) in bodies {
            let snapshot = try await Self.fetch(body, engine: engine)
            #expect(Array(snapshot.details.first?.rows.dropFirst().map(\.value) ?? []) == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing optional fields stay absent`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"{"balance_microdollars":-250000}"#, engine: engine)
        #expect(snapshot.details.first?.rows.map(\.label) == ["USD balance"])
        #expect(snapshot.details.first?.rows.first?.value == "-$0.25")
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "Pay as you go")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `blocked spending adds a warning detail`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(#"{"balance_microdollars":0,"can_spend":false}"#, engine: engine)
        let row = try #require(snapshot.details.first?.rows.last)
        #expect(row.label == "Status")
        #expect(row.value == "Spending blocked")
        #expect(row.severity == .warning)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `active pass maps allowance refill and end date`(engine: ProviderPluginEngineKind) async throws {
        let pass = #"{"plan":"starter","scope":["frontier"],"allowance_bp":2500,"#
            + #""refills":"2026-11-14T03:00:00Z","ends_at":"2026-12-01T12:00:00Z"}"#
        let snapshot = try await Self.fetch(Self.passBody(pass), engine: engine)
        #expect(snapshot.primary?.usedPercent == 75)
        #expect(snapshot.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-14T03:00:00Z"))
        #expect(snapshot.identity?.loginMethod == "Starter pass")
        #expect(snapshot.details.first?.rows.first?.value == "$4.00")
        let passSection = try #require(snapshot.details.last)
        #expect(passSection.title == "Pass")
        #expect(passSection.rows.map(\.label) == ["Pass ends"])
        #expect(passSection.rows.first?.value == "Dec 1")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pass refills accept epoch seconds and milliseconds`(engine: ProviderPluginEngineKind) async throws {
        for refills in ["1794003600", "1794003600000", #""1794003600""#] {
            let pass = #"{"plan_id":"hyperscaler","allowance_bp":10000,"refills":\#(refills)}"#
            let snapshot = try await Self.fetch(Self.passBody(pass), engine: engine)
            #expect(snapshot.primary?.usedPercent == 0)
            #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_794_003_600))
            #expect(snapshot.identity?.loginMethod == "Hyperscaler pass")
            #expect(snapshot.details.count == 1)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `pass labels and textual refills are shown without invented values`(
        engine: ProviderPluginEngineKind) async throws
    {
        let cases: [(String, String)] = [
            (#"{"plan":"vibecoder","refills":"in about 4 hours"}"#, "Vibecoder pass"),
            (#"{"plan":"raven","refills":"in about 4 hours"}"#, "Raven pass"),
            (#"{"plan":"fixture-plan","label":"Fixture Plan","refills":"in about 4 hours"}"#, "Fixture Plan pass"),
        ]
        for (pass, login) in cases {
            let snapshot = try await Self.fetch(Self.passBody(pass), engine: engine)
            #expect(snapshot.identity?.loginMethod == login)
            #expect(snapshot.primary == nil)
            #expect(snapshot.details.last?.rows.map(\.label) == ["Refills"])
            #expect(snapshot.details.last?.rows.map(\.value) == ["in about 4 hours"])
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `allowance percentages are clamped`(engine: ProviderPluginEngineKind) async throws {
        for (basisPoints, used) in [("12000", 0.0), ("-50", 100.0), (#""5000""#, 50.0)] {
            let snapshot = try await Self.fetch(
                Self.passBody(#"{"plan":"starter","allowance_bp":\#(basisPoints)}"#), engine: engine)
            #expect(snapshot.primary?.usedPercent == used)
            #expect(snapshot.primary?.resetsAt == nil)
            #expect(snapshot.details.count == 1)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing or malformed balances fail closed`(engine: ProviderPluginEngineKind) async {
        let bodies = [
            "private-response",
            "null",
            "[]",
            "{}",
            #"{"balance_microdollars":null}"#,
            #"{"balance_microdollars":"12.5"}"#,
            #"{"balance_microdollars":1.5}"#,
            #"{"balance_usd":12.5}"#,
        ]
        for body in bodies {
            await Self.expectFailure(body, engine: engine, kind: .parseFailure)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `errors are classified without echoing bodies or keys`(engine: ProviderPluginEngineKind) async {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (500, .providerUnavailable), (524, .providerUnavailable), (404, .apiFailure),
        ] {
            await Self.expectFailure(
                #"{"error":{"message":"private-response","type":"x"}}"#, engine: engine, code: code, kind: kind)
        }
    }

    private static func expectFailure(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200,
        kind: ProviderFetchClassifiedError.Kind) async
    {
        do {
            _ = try await self.fetch(body, engine: engine, code: code)
            Issue.record("Expected classified failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-key"))
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        code: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "crowbot",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                #expect(url.absoluteString == "https://api.crowbot.sh/api/me")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["CROWBOT_API_KEY": "fixture-key"])
    }
}
