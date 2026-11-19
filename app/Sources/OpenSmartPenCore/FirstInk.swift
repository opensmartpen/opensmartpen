import Foundation

/// Decides when paper the app has never seen has shown enough ink to be a notebook.
///
/// The pen finds its place from the pattern printed on the paper, and the pattern also says which
/// notebook it is. Near the edge of a sheet the pen sees only part of the pattern, and now and
/// then it reads the wrong notebook for one sample: the right page number, in a book that does
/// not exist. A notebook made from that is a notebook of one dot, with a picture of it sent to
/// the bucket (seen 2026-11-16, three in two seconds).
///
/// So one sample is not a notebook. A run of them on the same unknown paper is: a hand writes
/// about 120 samples a second, and a misreading does not repeat itself. Paper that is already a
/// notebook is never asked about here.
public struct FirstInk {
    /// A twentieth of a second of writing. Far more than a misreading, far less than a letter.
    public static let samplesNeeded = 6

    private var surface: String?
    private var samples = 0

    public init() {}

    /// Call for each sample on paper that has no notebook yet. True once that paper has shown
    /// enough in a row to be one.
    public mutating func isNotebook(_ surface: String) -> Bool {
        if self.surface != surface {
            self.surface = surface
            samples = 0
        }
        samples += 1
        return samples >= Self.samplesNeeded
    }
}
