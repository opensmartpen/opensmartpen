import OpenSmartPenCore
import OpenSmartPenUI
import Foundation
import ImageIO

/// Draws a captured page as a PNG, kept in the notes folder beside its strokes and sent to the
/// bucket with them.
///
/// It reads the strokes back off disk rather than holding them: the page being drawn went quiet a
/// minute ago, so the file is the whole of it, and nothing here has to be kept in step with what
/// the pen is doing now.
///
/// The ink is resolved the same way the viewer resolves it — the pen always reports black, and the
/// colour in force at a stroke's own time comes from the mode log.
final class PageImager: PageImaging {
    private let books: BookRegistry
    private let root: URL
    private let modeLog: ModeLog?
    /// Paper that is tapped, not written on. Its taps go to the bucket as the record they are,
    /// but a picture of them is a picture of dots, and whatever reads the bucket would try to
    /// read it as a page.
    private let controlBooks: Set<String>

    init(books: BookRegistry, root: URL, modeLog: ModeLog?, controlBooks: Set<String>) {
        self.books = books
        self.root = root
        self.modeLog = modeLog
        self.controlBooks = controlBooks
    }

    func png(for ref: PageRef) -> Data? {
        guard !controlBooks.contains(ref.folder.surface) else { return nil }
        // A photo is its own picture. It is only made the size an agent reads best, and turned
        // the way the camera says is up.
        if let photo = PhotoPages.image(of: ref, root: root) { return Self.png(fromPhoto: photo) }
        let strokes = RawReader.strokes(at: books.rawFile(for: ref), page: ref.page)
        guard !strokes.isEmpty else { return nil }
        // Read fresh: a colour added to palette.json takes effect on the next page drawn, without
        // a restart, exactly as it does for the renderer on the processing side.
        let palette = Palette.load(root: root)
        guard let raster = PageRaster.make(strokes: strokes, palette: palette,
                                           state: { [modeLog] ms in
                                               modeLog?.state(at: ms) ?? (ink: .black, width: .default)
                                           })
        else { return nil }
        return PageImage.png(raster)
    }

    /// The longest side a page picture is given. A model scales anything longer back down.
    static let longestSide = 1568

    static func png(fromPhoto url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
