import Foundation

public enum CrowbotProviderDescriptor {
    public static let descriptor = Self.spec.makeDescriptor()
    public static let spec = PluginProviderSpec(
        id: .crowbot,
        displayName: "crowbot",
        sessionLabel: "Pass allowance",
        weeklyLabel: "Weekly",
        toggleTitle: "Show crowbot balance",
        dashboardURL: "https://crowbot.sh",
        color: .init(hex: 0x475569),
        confetti: [0x475569, 0x94A3B8],
        noDataMessage: "No cost history data.",
        environmentKey: "CROWBOT_API_KEY",
        missingCredentialMessage: { _ in "Set a Crowbot API key in Settings or CROWBOT_API_KEY." },
        presentation: ProviderUsagePresentation(menuBarBalanceDetailLabels: ["USD balance"]),
        apiKeyField: .init(
            id: "crowbot-api-key",
            title: "API key",
            subtitle: "Stored in the CodexBar config file."))
}
