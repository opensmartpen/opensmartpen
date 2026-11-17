import Foundation

/// Whether this is a moment at which the app can restart itself to install an update.
///
/// An update is installed with no window and no question, so the moment has to be one that nobody
/// notices: no pen is writing, nothing waits to be uploaded, and nobody is looking at a window of
/// the app. A restart drops the link to the pen for some seconds, and a pen that is writing then
/// is the one case that must not happen.
public struct UpdateMoment: Equatable {
    /// How long every pen must have been silent. Longer than a pause in a meeting, shorter than
    /// the gap between two sittings.
    public static let silence: TimeInterval = 10 * 60

    /// When a pen last reported anything at all.
    public var lastPenActivity: Date
    /// Pages that are written and not yet uploaded.
    public var pendingPages: Int
    /// An upload is running.
    public var isPublishing: Bool
    /// A pen is connecting, or its memory is being copied.
    public var isCopyingFromPen: Bool
    /// The panel, the settings or the viewer is open.
    public var windowIsOpen: Bool

    public init(lastPenActivity: Date, pendingPages: Int, isPublishing: Bool,
                isCopyingFromPen: Bool, windowIsOpen: Bool) {
        self.lastPenActivity = lastPenActivity
        self.pendingPages = pendingPages
        self.isPublishing = isPublishing
        self.isCopyingFromPen = isCopyingFromPen
        self.windowIsOpen = windowIsOpen
    }

    public func isQuiet(at now: Date = Date()) -> Bool {
        guard pendingPages == 0, !isPublishing, !isCopyingFromPen, !windowIsOpen else { return false }
        return now.timeIntervalSince(lastPenActivity) >= Self.silence
    }
}
