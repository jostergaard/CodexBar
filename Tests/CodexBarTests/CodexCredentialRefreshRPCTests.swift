import Foundation
import Testing
@testable import CodexBarCore

struct CodexCredentialRefreshRPCTests {
    @Test
    func `credential refresh initializes and requests only account renewal in the supplied home`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try await fixture.fetcher().refreshCodexCredentials()

        let messages = try fixture.messages()
        #expect(messages.compactMap { $0["method"] as? String } == [
            "initialize", "initialized", "account/read",
        ])
        let params = try #require(messages.last?["params"] as? [String: Bool])
        #expect(params == ["refreshToken": true])
        let home = try String(contentsOf: fixture.root.appendingPathComponent("observed-home"), encoding: .utf8)
        #expect(home == fixture.root.appendingPathComponent("codex-home").path)
    }

    @Test
    func `ordinary account fetch preserves its empty parameters`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        _ = try await fixture.fetcher().loadLatestCLIAccountSnapshot()

        let messages = try fixture.messages()
        #expect(messages.compactMap { $0["method"] as? String } == [
            "initialize", "initialized", "account/rateLimits/read", "account/read",
        ])
        let params = try #require(messages.last?["params"] as? [String: Bool])
        #expect(params.isEmpty)
    }

    @Test(arguments: ["initialize-error", "account-error", "invalid-account", "closed-stdout"])
    func `credential refresh failures expose only sanitized categories`(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let error = await #expect(throws: CodexCredentialRefreshError.self) {
            try await fixture.fetcher(mode: mode).refreshCodexCredentials()
        }
        let failure = try #require(error)
        switch (mode, failure) {
        case ("initialize-error", .requestRejected), ("account-error", .requestRejected),
             ("invalid-account", .invalidResponse), ("closed-stdout", .transport):
            break
        default:
            Issue.record("Unexpected sanitized failure category: \(failure)")
        }
        #expect(!failure.localizedDescription.contains("fixture-token-do-not-leak"))
        #expect(!String(reflecting: failure).contains("fixture-token-do-not-leak"))
        #expect(try !fixture.messages().contains { ($0["method"] as? String) == "account/rateLimits/read" })
    }

    @Test(arguments: CodexCredentialRefreshAuthReason.allCases, ["structured-error", "message-error"])
    func `credential refresh recognizes only safe authentication reasons`(
        reason: CodexCredentialRefreshAuthReason,
        mode: String) async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let error = await #expect(throws: CodexCredentialRefreshError.self) {
            try await fixture.fetcher(mode: mode, errorCode: reason.rawValue).refreshCodexCredentials()
        }
        guard case let .authentication(actualReason) = error else {
            Issue.record("Expected a sanitized authentication reason, got \(String(describing: error))")
            return
        }
        #expect(actualReason == reason)
        #expect(error?.localizedDescription.contains("fixture-token-do-not-leak") == false)
        #expect(String(reflecting: error).contains("fixture-token-do-not-leak") == false)
    }

    @Test(arguments: ["not_invalid_grant_x", "invalid_grant_suffix", "prefix_invalid_grant", "HTTP_429", "HTTP_403"])
    func `near miss and unknown rejection codes remain transient`(code: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let error = await #expect(throws: CodexCredentialRefreshError.self) {
            try await fixture.fetcher(mode: "message-error", errorCode: code).refreshCodexCredentials()
        }
        guard case .requestRejected = error else {
            Issue.record("Expected an unclassified rejection, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `credential refresh distinguishes a timeout`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let error = await #expect(throws: CodexCredentialRefreshError.self) {
            try await fixture.fetcher(mode: "timeout", requestTimeout: 0.1).refreshCodexCredentials()
        }
        guard case .timeout = error else {
            Issue.record("Expected a sanitized timeout, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `credential refresh distinguishes an unavailable CLI`() async {
        let fetcher = UsageFetcher(
            environment: [:],
            initializeTimeoutSeconds: 1,
            requestTimeoutSeconds: 1,
            codexExecutableResolver: { _, _ in nil })
        let error = await #expect(throws: CodexCredentialRefreshError.self) {
            try await fetcher.refreshCodexCredentials()
        }
        guard case .unavailable = error else {
            Issue.record("Expected unavailable CLI, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `cancelled credential refresh does not resolve or launch a CLI`() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let fetcher = UsageFetcher(
                environment: [:],
                initializeTimeoutSeconds: 1,
                requestTimeoutSeconds: 1,
                codexExecutableResolver: { _, _ in
                    Issue.record("Cancelled credential refresh attempted executable resolution")
                    return nil
                })
            try await fetcher.refreshCodexCredentials()
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private struct Fixture {
        let root: URL
        let executable: URL

        init() throws {
            let checkout = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            self.root = checkout.appendingPathComponent(".build/credential-refresh-rpc-\(UUID().uuidString)")
            self.executable = self.root.appendingPathComponent("codex")
            try FileManager.default.createDirectory(
                at: self.root.appendingPathComponent("codex-home"), withIntermediateDirectories: true)
            try FakeExecutable.install(Self.script, at: self.executable)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }

        func fetcher(
            mode: String = "success",
            requestTimeout: TimeInterval = 2,
            errorCode: String = "") -> UsageFetcher
        {
            let executable = self.executable.path
            return UsageFetcher(
                environment: [
                    "PATH": "/usr/bin:/bin",
                    "HOME": self.root.path,
                    "CODEX_HOME": self.root.appendingPathComponent("codex-home").path,
                    "CODEXBAR_FIXTURE_ROOT": self.root.path,
                    "CODEXBAR_FIXTURE_MODE": mode,
                    "CODEXBAR_FIXTURE_ERROR_CODE": errorCode,
                ],
                initializeTimeoutSeconds: 5,
                requestTimeoutSeconds: requestTimeout,
                codexExecutableResolver: { _, _ in
                    CodexExecutableResolution(executable: executable, loginPATH: [])
                })
        }

        func messages() throws -> [[String: Any]] {
            let text = try String(contentsOf: self.root.appendingPathComponent("requests"), encoding: .utf8)
            return try text.split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }

        private static let script = #"""
        case " $* " in *" app-server "*) ;; *) exit 92 ;; esac
        printf '%s' "$CODEX_HOME" > "$CODEXBAR_FIXTURE_ROOT/observed-home"
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$CODEXBAR_FIXTURE_ROOT/requests"
          case "$line" in
            *'"initialized"'*) ;;
            *'"initialize"'*)
              if [ "$CODEXBAR_FIXTURE_MODE" = initialize-error ]; then
                printf '%s\n' '{"id":1,"error":{"message":"fixture-token-do-not-leak"}}'
              else
                printf '%s\n' '{"id":1,"result":{}}'
              fi
              ;;
            *'"method"'*account*rateLimits*read*)
              printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro"}}}'
              ;;
            *'"method"'*account*read*)
              printf '%s\n' 'fixture-token-do-not-leak' >&2
              case "$CODEXBAR_FIXTURE_MODE" in
                account-error)
                  printf '%s\n' '{"id":2,"error":{"message":"fixture-token-do-not-leak"}}' ;;
                structured-error)
                  printf '{"id":2,"error":{"data":{"code":"%s"},"message":"%s"}}\n' \
                    "$CODEXBAR_FIXTURE_ERROR_CODE" 'fixture-token-do-not-leak login_required' ;;
                message-error)
                  printf '{"id":2,"error":{"message":"fixture-token-do-not-leak (%s)"}}\n' \
                    "$CODEXBAR_FIXTURE_ERROR_CODE" ;;
                invalid-account)
                  printf '%s\n' '{"id":2,"result":{"account":{"type":"fixture-token-do-not-leak"}}}' ;;
                closed-stdout) exit 0 ;;
                timeout) ;;
                *)
                  for id in 2 3; do
                    printf '{"id":%s,"result":{"account":%s}}\n' "$id" \
                      '{"type":"chatgpt","email":"stub@example.com","planType":"pro"}'
                  done
                  ;;
              esac
              ;;
          esac
        done
        """#
    }
}
