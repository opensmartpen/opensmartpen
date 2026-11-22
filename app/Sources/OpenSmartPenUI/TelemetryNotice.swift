import AppKit
import OpenSmartPenCore
import SwiftUI

/// Where a person reads what the app reports. One address, used by the question and by Settings.
public enum TelemetryInfo {
    public static let url = URL(string: "https://github.com/opensmartpen/opensmartpen/blob/main/docs/telemetry.md")!

    /// What is sent, in one paragraph. The question and Settings say the same words.
    static let summary = "Open Smart Pen sends its makers how the app is used and what goes wrong: "
        + "which buttons are clicked, how many pages are synced, the Bluetooth address of each pen, errors and crashes."
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
    /// Where it is kept. Said only when the app sends to the collector of the project, and
    /// nowhere else: it is a promise about that one place. The host of the collector must be
    /// chosen so that this is true, with the certificate and the contract to show for it.
    static let storage = "We keep it in certified storage that meets the GDPR."
}

/// The first window a person sees: two things to decide, one time.
///
/// Whether the app starts at login, and whether the app reports to its makers. Both are switches,
/// and both are on when the window opens. Nothing is sent before the person
/// presses "Get Started": they see the switch, and what is sent, first, and can turn it off there.
///
/// A window and not a notification, which can be missed, and not an alert, which stops the app
/// until it is answered: the app may have been started at login with nobody there, and a pen
/// that is paired already is taken care of meanwhile. What waits for "Get Started" is what a
/// person does with the app: the panel does not open until then.
public final class TelemetryNoticeController: NSWindowController, NSWindowDelegate {
    /// The first is whether the app may report, the second whether it is to start at login, each
    /// as its switch stood at "Get Started". The window has no close button: the only way on is
    /// "Get Started", so a person always passes the two switches before they use the app. When the
    /// app itself closes the window, the switches count as they stand.
    public var onAnswer: ((Bool, Bool) -> Void)?
    private var answered = false
    private let choices: WelcomeChoices

    /// `encrypted` is whether what is sent goes over `https` only; the window says so when it is.
    /// `ours` is whether it goes to the collector of the project and nowhere else; the window
    /// says where it is kept only then. `startAtLogin` is how the switch stands when it opens.
    public init(installId: String, encrypted: Bool, ours: Bool, startAtLogin: Bool = true) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Open Smart Pen"
        window.isReleasedWhenClosed = false
        window.level = .floating
        choices = WelcomeChoices(startAtLogin: startAtLogin)
        super.init(window: window)
        let view = TelemetryNoticeView(choices: choices, installId: installId, encrypted: encrypted, ours: ours) { [weak self] yes in
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
        onAnswer?(yes, choices.startAtLogin)
    }

    public func windowWillClose(_ notification: Notification) {
        guard !answered else { return }
        answered = true
        onAnswer?(choices.helpImprove, choices.startAtLogin)
    }

    /// Bring the window back in front, for a person who clicked something else of the app first.
    public func comeForward() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the switches in the window stand at. Held outside the view, so the window can read it
/// when it is closed with no button.
final class WelcomeChoices: ObservableObject {
    @Published var startAtLogin: Bool
    /// On when the window opens. A person who does not want it turns it off before "Get Started".
    @Published var helpImprove = true
    init(startAtLogin: Bool) { self.startAtLogin = startAtLogin }
}

struct TelemetryNoticeView: View {
    @ObservedObject var choices: WelcomeChoices
    let installId: String
    let encrypted: Bool
    let ours: Bool
    let answer: (Bool) -> Void
    @State private var showsWhatIsSent = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                // The icon of the app itself, which is the logo.
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome").font(.title2.weight(.semibold))
            }
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    glyph("power", .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start at login").font(.body.weight(.medium))
                        Text("Always ready when you write").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Start at login", isOn: $choices.startAtLogin).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                HStack(spacing: 12) {
                    glyph("heart.fill", .pink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Help us improve").font(.body.weight(.medium))
                        Text("Share usage and error data").font(.callout).foregroundStyle(.secondary)
                        // Under the question, and in the window: what a person agrees to is one
                        // click away from the switch that agrees to it, with no browser in between.
                        Button("What is sent") { showsWhatIsSent.toggle() }
                            .buttonStyle(.link)
                            .font(.callout)
                            .padding(.top, 1)
                            .popover(isPresented: $showsWhatIsSent, arrowEdge: .bottom) { whatIsSent }
                    }
                    Spacer(minLength: 8)
                    Toggle("Help us improve", isOn: $choices.helpImprove).labelsHidden().toggleStyle(.switch)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack(alignment: .top, spacing: 8) {
                // Three short facts, and each says what the app is, not what it lacks: a row of
                // "no" read as a list of warnings. The notes are in a folder on this Mac first,
                // nobody else gets them, and the code is there to read.
                promise("internaldrive.fill", "Local first", "No server")
                promise("lock.fill", "Private", "No account")
                promise("chevron.left.forwardslash.chevron.right", "Open source", "Auditable code")
            }
            HStack {
                Spacer()
                Button("Get Started") { answer(choices.helpImprove) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    /// The same words Settings has, and all of them: what is sent, what never is, what it is
    /// for, and the two ids that go with it.
    private var whatIsSent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TelemetryInfo.summary + " " + TelemetryInfo.purpose)
            Text(TelemetryInfo.never)
            Text(([TelemetryInfo.ids] + (encrypted ? [TelemetryInfo.transit] : [])
                  + (ours ? [TelemetryInfo.storage] : [])).joined(separator: " "))
            Text("Nothing is sent before you press Get Started. Turn it off here, or at any time in Settings → General.")
                .foregroundStyle(.secondary)
            Link("The full list", destination: TelemetryInfo.url)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 340)
    }

    /// The two rows have a sign in a colour of their own, so the eye finds them. The switches,
    /// the link and the button keep the colour macOS gives every app, which is the one a person
    /// chose for their Mac. The three facts below have no colour: they are read, not pressed.
    private func glyph(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
    }

    /// A fact in one or two bold words, and under it the plain thing that makes it true.
    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 4) {
            // One height for each sign, so the three lines of words stand on one line.
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                .frame(height: 24)
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
