import AppKit
import OpenSmartPenCore
import SwiftUI

/// Where a person reads what the app reports. One address, used by the question and by Settings.
public enum TelemetryInfo {
    public static let url = URL(string: "https://github.com/opensmartpen/opensmartpen/blob/main/docs/telemetry.md")!

    /// What is sent, in one paragraph. The question and Settings say the same words.
    static let summary = "Open Smart Pen sends its makers how the app is used and what goes wrong: "
        + "which buttons are clicked, how many pages are synced, the address of each pen, errors and crashes."
    /// What is not.
    static let never = "It never sends what you write, your pages, their text, the names of your "
        + "notebooks and pens, or anything about your bucket."
    /// What it is for. Nothing else is done with it.
    static let purpose = "We use it only to find problems and to decide what to improve."
    /// The two ids that go with it, said plainly: they are what makes this more than counting.
    static let ids = "It carries a random id of this install and the Bluetooth address of your pen, "
        + "so that we can tell one install and one pen from another. It carries no name and no account."
    /// Said only when the plan sends to `https` addresses and nowhere else.
    static let transit = "It is encrypted on its way to us."
    /// Where it is kept and for how long. Nil until the project has a collector: this sentence
    /// is a promise about a real place, so it is written when the place is chosen and not before.
    static let storage: String? = nil
}

/// The window that asks a person, one time, whether the app may report to its makers.
///
/// A question and not a notice: nothing is sent unless the person says yes. A window and not a
/// notification, which can be missed, and not an alert, which stops the app until it is answered:
/// the app may have been started at login with nobody there, and the pen must be taken care of
/// meanwhile.
public final class TelemetryNoticeController: NSWindowController, NSWindowDelegate {
    /// True for yes, false for no. Closing the window is a no: a yes has to be given.
    public var onAnswer: ((Bool) -> Void)?
    private var answered = false

    /// `encrypted` is whether what is sent goes over `https` only; the window says so when it is.
    public init(installId: String, encrypted: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Open Smart Pen"
        window.isReleasedWhenClosed = false
        window.level = .floating
        super.init(window: window)
        let view = TelemetryNoticeView(installId: installId, encrypted: encrypted) { [weak self] yes in
            self?.answer(yes)
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func answer(_ yes: Bool) {
        guard !answered else { return }
        answered = true
        close()
        onAnswer?(yes)
    }

    public func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        onAnswer?(false)
    }
}

struct TelemetryNoticeView: View {
    let installId: String
    let encrypted: Bool
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Help improve Open Smart Pen?")
                .font(.headline)
            Text("Open Smart Pen can send its makers how the app is used and what goes wrong: which "
                 + "buttons are clicked, how many pages are synced, errors and crashes. " + TelemetryInfo.purpose)
                .fixedSize(horizontal: false, vertical: true)
            Text(TelemetryInfo.never)
                .fixedSize(horizontal: false, vertical: true)
            Text(([TelemetryInfo.ids] + (encrypted ? [TelemetryInfo.transit] : [])
                  + [TelemetryInfo.storage].compactMap { $0 }).joined(separator: " "))
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is sent unless you say yes. You can change your answer at any time in Settings → General.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Link("What is sent", destination: TelemetryInfo.url)
                Spacer()
                Button("Not Now") { answer(false) }
                Button("Send") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 460)
    }
}
