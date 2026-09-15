import BrainioPenCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `brainio-pen --check-dam` — the round trip, on its own, with nothing else running.
///
/// It exists because the parts it exercises cannot be tested against a stub and be worth anything:
/// whether this key opens that agent, whether an upload wakes it, and whether the relay on that
/// deployment speaks the prompt extension. Three answers, before a pen is ever involved.
enum DamCheck {
    static func run() -> Never {
        let config = (try? Config.loadOrCreate(at: Config.defaultLocation)) ?? Config()
        guard let account = config.damAccount() else {
            say("no DAM agent configured. Set one in Settings → Reading.")
            exit(1)
        }
        say("agent \(account.agentId) at \(account.host)")

        var ok = false
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                let client = try DamClient(account: account)

                let stamp = ISO8601DateFormatter().string(from: Date())
                let probe = "work/pen/_check.md"
                say("uploading \(probe) …")
                try await client.upload(path: probe, data: Data("checked at \(stamp)\n".utf8),
                                        contentType: "text/markdown", overwrite: true)
                let back = try await client.read(path: probe)
                guard back.text?.contains(stamp) == true else {
                    say("the file came back different from the one that went up")
                    done.signal()
                    return
                }
                say("upload and download work")

                // Uploaded and read at `work/…`; named to the agent without it, because a session
                // starts in `work`.
                let answer = "work/pen/_check-answer.md"
                let answerForAgent = "pen/_check-answer.md"
                say("prompting the agent (this wakes it, and can take a minute) …")
                let runner = try DamRunner(account: account)
                // The prompt carries a picture, and the answer proves the picture arrived. A page
                // is sent the same way, and if the attachment were dropped the agent would quietly
                // fall back to opening the file — working, slowly, for a reason nobody could see.
                let result = try await runner.run(prompt: """
                    The image attached to this message is a plain square of one colour. Write that \
                    colour, as one lower-case word, into `\(answerForAgent)`. Say nothing else, and \
                    do not open or process any file to answer. This is a connection check from \
                    Brainio Pen.
                    """, image: DamImage(data: probeImage(), mimeType: "image/png"), timeout: 300)
                say("the turn ended: \(result.stopReason ?? "no stop reason")")
                if !result.text.isEmpty { say("the agent said: \(result.text.prefix(200))") }

                let written = try await client.read(path: answer)
                let text = (written.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                say(text.lowercased().contains("purple")
                    ? "the agent saw the attached picture and wrote the file. Reading pages will work."
                    : "the agent wrote \(answerForAgent), but it says '\(text)' rather than the "
                        + "colour of the attached square — the picture may not be reaching it")
                ok = true
            } catch {
                say("failed: \(error.localizedDescription)")
            }
            done.signal()
        }

        // There is no run loop in this mode, so the answer is waited for here.
        done.wait()
        exit(ok ? 0 : 1)
    }

    /// A square of one unmistakable colour. Small, but not so small that a reader has to squint:
    /// the question is only whether the picture arrives at all.
    private static func probeImage() -> Data {
        let side = 96
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.42, green: 0.16, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let out = NSMutableData()
        let sink = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, context.makeImage()!, nil)
        CGImageDestinationFinalize(sink)
        return out as Data
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
