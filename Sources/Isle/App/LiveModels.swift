import AppKit
import SwiftUI

/// A one-off banner that drops below the notch. Features raise these with `vm.notify(_:)`
/// instead of adding their own banner layouts, so every banner looks and behaves the same:
/// tinted glyph (or image) on the left, title + one line of context, an optional short
/// accent on the right. Hovering opens the island on `tab`.
struct Notice: Equatable {
    var id = UUID()
    /// SF Symbol shown in a tinted circle.
    var icon: String
    var tint: Color
    /// Optional image used instead of the glyph (file icon, app icon…).
    var image: NSImage? = nil
    var title: String
    var subtitle: String
    /// Short accent on the right, e.g. "3m 12s" or "in 5m". Drawn in `tint`.
    var trailing: String? = nil
    var tab: IslandTab? = nil

    static func == (a: Notice, b: Notice) -> Bool { a.id == b.id }
}

/// Something ongoing that can occupy the compact slot beside the notch while the island is
/// closed (a running timer, a download…). Only the highest-priority item is shown; when music
/// or agents already hold the left side, the item takes the right side.
///
/// Priorities (keep to these so features rank sensibly against each other):
///   90 urgent & time-boxed (timer about to end) · 60 user-started (timer, mirror)
///   40 progress of something (download) · 10 ambient status (mic / camera in use)
struct LiveItem: Identifiable, Equatable {
    let id: String
    var priority: Int
    /// SF Symbol, shown on the left when nothing else (music / agents) is.
    var icon: String
    var tint: Color
    /// 0…1 draws a ring; nil draws no ring.
    var progress: Double? = nil
    /// Short text on the right, e.g. "68%". Ignored while `countdown` is set.
    var text: String? = nil
    /// Live "mm:ss" until `countdown.end`, with the ring draining over the interval.
    var countdown: DateInterval? = nil
    /// Tab to open when the person hovers the island while this is the top item.
    var tab: IslandTab? = nil
    /// How the item draws beside the notch (see `Style`).
    var style: Style = .glyph

    enum Style: Equatable {
        /// `icon` on the left, ring / text (or the icon again) on the right.
        case glyph
        /// Only a small dot in `tint` on the right, like iOS's mic / camera indicator, and a
        /// slimmer island. For ambient "something is on" status; text and progress are ignored.
        case dot
    }

    var hasText: Bool { countdown != nil || (text?.isEmpty == false) }
}
