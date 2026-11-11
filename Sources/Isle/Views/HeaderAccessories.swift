import SwiftUI

/// Small glyphs in the open island's header, left of the battery. One row shared by every
/// feature, so the header never grows a second line. Rules for anything added here:
///  - show only when it has something to say (no permanent placeholders), except a feature's
///    single entry point that is scoped to one tab (e.g. a timer button on Home)
///  - one glyph or one short value at most (≈ 60 pt), white at 0.55 when idle, tinted when live
///  - details go in `.help(…)`, not in more pixels
struct HeaderAccessories: View {
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            // Ambient status first, then this tab's glance, then controls next to the gear.
            CaptureHeaderIndicator(env: env)
            UsageAccessory(env: env)
            WeatherAccessory(env: env)
            TimerAccessory(env: env)
            QuietButton(env: env) // on every tab, faint when off: quiet mode's only entry point
        }
        // Accessories never wrap or squeeze; the battery gives up its percentage instead.
        .fixedSize()
        .animation(Anim.micro, value: env.vm.tab)
    }
}
