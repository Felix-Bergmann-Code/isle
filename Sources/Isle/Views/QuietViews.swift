import SwiftUI

/// The moon in the open island's header, on every tab: quiet mode's one entry point.
/// Faint while off (it's permanent, so it mustn't draw the eye), indigo while on.
/// Click toggles; right-click offers a duration.
struct QuietButton: View {
    let env: AppEnvironment

    var body: some View {
        let quiet = env.quiet
        if env.settings.quietMode {
            IslandIconButton(systemName: "moon.fill", size: 11, padding: 5,
                             tint: quiet.isActive ? QuietMode.tint : .islandTertiary) { quiet.toggle() }
                .help(quiet.help)
                .contextMenu {
                    Button("Quiet for 1 hour") { quiet.turnOn(until: Date().addingTimeInterval(3600)) }
                    Button("Quiet until tomorrow") { quiet.turnOn(until: QuietMode.tomorrowMorning) }
                    if quiet.isOn { Button("Turn off") { quiet.turnOff() } }
                }
                .transition(.opacity)
        }
    }
}
