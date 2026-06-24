import Foundation

// Persistence for the user's PresentationConfig (slots + overrides). UI-free; mirrors
// UserDefaultsIntegrationRegistry. Decode is graceful — a corrupt or missing payload yields
// .empty rather than throwing, so a bad save never bricks launch.

public protocol PresentationConfigStore: Sendable {
    func load() -> PresentationConfig
    func save(_ config: PresentationConfig)
}

public struct UserDefaultsPresentationConfigStore: PresentationConfigStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "presentationConfig"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PresentationConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(PresentationConfig.self, from: data)
        else { return .empty }
        return config
    }

    public func save(_ config: PresentationConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
