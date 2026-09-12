import AppKit
import PenBridgeCore
import SwiftUI

/// Violet ink. The resting state carries no colour at all — ink on paper is the "everything is
/// fine" signal — so the accent only appears on work in flight, and red only when something wants
/// fixing. No green anywhere: this is a pen, not a router.
enum Ink {
    static let accent = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.357, green: 0.247, blue: 0.769, alpha: 1),
                                               dark: NSColor(srgbRed: 0.655, green: 0.592, blue: 0.941, alpha: 1)))
    static let critical = Color(nsColor: dynamic(light: NSColor(srgbRed: 0.651, green: 0.227, blue: 0.196, alpha: 1),
                                                 dark: NSColor(srgbRed: 0.886, green: 0.478, blue: 0.439, alpha: 1)))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// The panel says each thing once. A page's countdown is the only place its timing appears, the
/// battery is a number in the header rather than a labelled gauge, and nothing the header has
/// already said is repeated underneath it. Prose survives in exactly two states — a failure and a
/// first run — because those are the only ones where the next move is not obvious.
struct StatusPanel: View {
    @ObservedObject var model: PanelModel
    /// Ticks while the panel is open so the countdowns move.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.pending.isEmpty { section { pending } }
            if case let .failing(_, _, error) = model.status { section { failure(error) } }
            if case let .copying(_, _, percent) = model.status { section { copying(percent) } }
            if model.showsWakeHint { section { wakeHint } }
            if !model.recent.isEmpty { section { recent } }
            footer
        }
        .frame(width: 300)
    }

    // MARK: header — state, freshness and battery on one line

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(dotColour)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(headline)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            if let meta = headerMeta {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let battery = model.battery {
                Text("\(battery.percent)%")
                    .font(.system(size: 11, weight: battery.low ? .semibold : .regular))
                    .foregroundStyle(battery.low ? Ink.critical : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private var dotColour: Color {
        switch model.status {
        case .failing: return Ink.critical
        case .copying, .writing: return Ink.accent
        case .asleep, .bluetoothOff, .connecting: return Color.secondary.opacity(0.45)
        case .connected: return Color.primary
        }
    }

    private var headline: String {
        switch model.status {
        case .asleep: return "Asleep"
        case .bluetoothOff: return "Bluetooth off"
        case .connecting: return "Connecting"
        // One word for the whole journey. Pen-to-Mac and Mac-to-git are different legs of it, and
        // nobody watching a panel cares which leg — only whether the writing arrived.
        case let .copying(book, count, _): return count > 1 ? "Syncing \(book) of \(count)" : "Syncing"
        case .failing: return "Can't sync"
        case .writing: return "Writing"
        case .connected: return model.pending.isEmpty ? "All synced" : "Waiting to sync"
        }
    }

    /// Time since the last sync — the one thing the headline cannot carry on its own. While the pen
    /// is away it gives way to how long it has been away, but only once that is long enough to be
    /// odd: an absent pen may be holding pages, and nothing here can count them.
    private var headerMeta: String? {
        if case .asleep = model.status, let seen = model.lastSeen,
           now.timeIntervalSince(seen) > Self.staleAfter {
            return "seen \(Self.brief(since: seen, now: now))"
        }
        guard model.pending.isEmpty, let last = model.lastPublish else { return nil }
        return Self.brief(since: last.date, now: now)
    }

    /// A pen unseen for longer than this is worth mentioning. Shorter than this is an ordinary day.
    private static let staleAfter: TimeInterval = 36 * 3600

    // MARK: pending — one row per page, the countdown doing all the talking

    private var pending: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.pending.prefix(5)) { row in
                HStack(spacing: 7) {
                    Circle()
                        .fill(row.isLive ? Ink.accent : Color.clear)
                        .frame(width: 5, height: 5)
                    Text(row.label.oneLine)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if let deadline = row.deadline {
                        Text(Self.clock(to: deadline, from: now))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
            if model.pending.count > 5 {
                Text("+\(model.pending.count - 5)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Button(model.isPublishing ? "Syncing" : "Sync now", action: model.publishNow)
                .buttonStyle(InkButtonStyle(filled: true))
                .disabled(model.isPublishing)
                .padding(.top, 2)
        }
    }

    // MARK: recent — click to open the rendered page

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.system(size: 9.5))
                .tracking(0.7)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 1)
            ForEach(model.recent) { page in
                RecentRow(page: page) { model.open(page) }
            }
        }
    }

    // MARK: the two states that still need words

    private func failure(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // The one line that matters: nothing has been lost.
            Text("\(model.pending.count) page\(model.pending.count == 1 ? "" : "s") safe on disk.")
                .font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 7) {
                Button("Retry", action: model.publishNow)
                    .buttonStyle(InkButtonStyle(filled: true))
                Button("Log", action: model.openLog)
                    .buttonStyle(InkButtonStyle(filled: false))
            }
        }
    }

    private var wakeHint: some View {
        Text("Press the pen's button to wake it, and keep it near this Mac.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copying(_ percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Bar(fraction: Double(percent) / 100, tint: Ink.accent)
            if let pages = model.pagesOnPen {
                Text("\(pages) page\(pages == 1 ? "" : "s") left on the pen")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: chrome

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: model.isPinned ? "Unpin" : "Pin", action: model.togglePin)
            FooterButton(title: "Live", action: model.showLive)
            FooterButton(title: "Notes", action: model.openNotes)
            FooterButton(title: "Settings", action: model.openConfig)
            FooterButton(title: "Quit") { NSApp.terminate(nil) }
        }
        .padding(4)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { hairline }
    }

    /// Every section is a hairline plus the same padding, so the layout does not repeat either.
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hairline
            content()
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    // MARK: formatting

    /// "6:12" — the wait, with no word wrapped around it.
    static func clock(to deadline: Date, from now: Date) -> String {
        let remaining = Int(deadline.timeIntervalSince(now).rounded(.up))
        guard remaining > 0 else { return "now" }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    /// "4m", "2h", "3d" — freshness in the space of a word.
    static func brief(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

// MARK: - pieces

private struct RecentRow: View {
    let page: PanelModel.RecentPage
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(page.label.oneLine)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if page.file == nil {
                    // The processing side has not caught up with this page yet.
                    Text("not rendered")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                } else if hovering {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.accent)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(page.file == nil)
        .foregroundStyle(page.file == nil ? Color.secondary : Color.primary)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering && page.file != nil ? Color.primary.opacity(0.07) : Color.clear))
        .onHover { hovering = $0 }
    }
}

private struct Bar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.11))
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

private struct InkButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(filled ? (isEnabled ? Ink.accent : Color.primary.opacity(0.10)) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(filled ? Color.clear : Color.primary.opacity(0.15)))
            .foregroundStyle(filled ? (isEnabled ? Color.white : Color.secondary) : Color.primary)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.primary : Color.secondary)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .onHover { hovering = $0 }
    }
}
