import AppKit

/// The logo of the app, for a window that shows it.
///
/// Not `NSApp.applicationIconImage`: macOS draws the icon of an app again in its own style, and
/// the pencil then comes out grey and embossed. The picture in the bundle is the logo as it was
/// drawn. A build with no bundle, such as the design window, has only the icon macOS gives.
enum AppLogo {
    static let image: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage
}
