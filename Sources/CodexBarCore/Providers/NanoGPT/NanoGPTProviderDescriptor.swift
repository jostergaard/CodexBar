import Foundation

public enum NanoGPTProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .nanogpt,
        displayName: "NanoGPT",
        sessionLabel: "Daily tokens",
        weeklyLabel: "Weekly tokens",
        toggleTitle: "Show NanoGPT balance",
        dashboardURL: "https://nano-gpt.com/balance",
        color: .init(hex: 0x3B82F6),
        confetti: [0x3B82F6, 0x93C5FD],
        noDataMessage: "No cost history data.",
        environmentKey: "NANOGPT_API_KEY",
        missingCredentialMessage: { _ in "Set a NanoGPT API key in Settings or NANOGPT_API_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["USD balance"]),
        aliases: ["nano-gpt"],
        apiKeyField: .init(
            id: "nanogpt-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."))
}
