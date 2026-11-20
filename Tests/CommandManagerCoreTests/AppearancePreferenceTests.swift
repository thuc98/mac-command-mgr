import CommandManagerCore
import Foundation
import Testing

@Suite struct AppearancePreferenceTests {
    private func defaults() -> UserDefaults {
        let name = "AppearancePreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func missingValueFollowsSystem() {
        #expect(AppearancePreference.stored(in: defaults()) == .system)
    }

    @Test func storedChoiceIsRead() {
        let d = defaults()
        d.set(AppearancePreference.dark.rawValue, forKey: AppearancePreference.defaultsKey)
        #expect(AppearancePreference.stored(in: d) == .dark)
    }

    @Test func unknownValueFallsBackToSystem() {
        let d = defaults()
        d.set("sepia", forKey: AppearancePreference.defaultsKey)
        #expect(AppearancePreference.stored(in: d) == .system)
    }
}
