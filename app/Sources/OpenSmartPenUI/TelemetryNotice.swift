import AppKit
import OpenSmartPenCore
import SwiftUI

/// Where a person reads what the app reports. One address, used by the notice and by Settings.
public enum TelemetryInfo {
    public static let url = URL(string: "https://github.com/opensmartpen/opensmartpen/blob/main/docs/telemetry.md")!

    /// What is sent, in one paragraph. The notice and Settings say the same words.
    static let summary = "Open Smart Pen sends its makers how the app is used and what goes wrong: "
        + "which buttons are clicked, how many pages are synced, the address of each pen, errors and crashes."
    /// What is not.
    static let never = "It never sends what you write, your pages, their text, the names of your "
        + "notebooks and pens, or anything about your bucket."
}

/// The window that tells a person, once, that the app reports to its makers.
///
/// A window and not a notification, which can be missed, and not an alert, which stops the app
/// until it is answered: the app may have been started at login with nobody there, and the pen
/// must be taken care of meanwhile. Nothing is sent while this is unanswered.
public final class TelemetryNoticeController: NSWindowController, NSWindowDelegate {
    /// True to keep telemetry on, false to turn it off. Closing the window keeps it on: the
    /// person has seen it, and Settings → General has the switch.
    public var onAnswer: ((Bool) -> Void)?
    private var answered = false

    public init(installId: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Open Smart Pen"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        let view = TelemetryNoticeView(installId: installId) { [weak self] keep in self?.answer(keep) }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func answer(_ keep: Bool) {
        guard !answered else { return }
        answered = true
        close()
        onAnswer?(keep)
    }

    public func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        onAnswer?(true)
    }
}

struct TelemetryNoticeView: View {
    let installId: String
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Smart Pen reports how it is used")
                .font(.headline)
            Text(TelemetryInfo.summary)
                .fixedSize(horizontal: false, vertical: true)
            Text(TelemetryInfo.never)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing was sent yet. You can turn this off now, or later in Settings → General.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Link("What is sent", destination: TelemetryInfo.url)
                Spacer()
                Button("Turn Off") { answer(false) }
                Button("OK") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
    }
}
