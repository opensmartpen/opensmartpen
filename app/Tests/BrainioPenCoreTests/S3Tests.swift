import Foundation
@testable import BrainioPenCore
import XCTest

final class S3Tests: XCTestCase {
    /// The worked example from the AWS documentation ("Signature Calculations for the
    /// Authorization Header", GET Object). If this matches, the signing is right, and no bucket
    /// is needed to know it.
    func testSignatureMatchesTheAWSWorkedExample() throws {
        let url = try XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = try XCTUnwrap(utc.date(from: DateComponents(year: 2013, month: 5, day: 24)))
        XCTAssertEqual(SigV4.timestamp(date), "20130524T000000Z")

        let auth = SigV4.authorization(
            method: "GET", url: url,
            headers: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9",
                      "x-amz-content-sha256": empty, "x-amz-date": "20130524T000000Z"],
            payloadHash: empty, accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1", now: date)
        XCTAssertEqual(auth, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func settings(_ change: (inout S3Settings) -> Void = { _ in }) -> S3Settings {
        var s = S3Settings()
        s.bucket = "notes"
        s.accessKeyId = "AKIAEXAMPLE"
        change(&s)
        return s
    }

    func testAnAccountNeedsABucketAKeyAndASecret() {
        XCTAssertNotNil(S3Account(settings: settings(), secret: "s"))
        XCTAssertNil(S3Account(settings: settings(), secret: nil))
        XCTAssertNil(S3Account(settings: settings(), secret: "  "))
        XCTAssertNil(S3Account(settings: settings { $0.bucket = " " }, secret: "s"))
        XCTAssertNil(S3Account(settings: settings { $0.accessKeyId = "" }, secret: "s"))
    }

    func testWhereAFileGoes() throws {
        let aws = try XCTUnwrap(S3Account(settings: settings { $0.region = "eu-central-1" }, secret: "s"))
        XCTAssertEqual(aws.url(forKey: aws.key(for: "books/x/raw/p1.jsonl")).absoluteString,
                       "https://s3.eu-central-1.amazonaws.com/notes/books/x/raw/p1.jsonl")

        // Typed the way people type things: spaces, slashes at both ends, no scheme.
        let other = try XCTUnwrap(S3Account(settings: settings {
            $0.endpoint = " minio.local:9000/ "
            $0.prefix = "/my pen/"
        }, secret: "s"))
        XCTAssertEqual(other.url(forKey: other.key(for: "palette.json")).absoluteString,
                       "https://minio.local:9000/notes/my%20pen/palette.json")
        XCTAssertEqual(SigV4.host(of: other.endpoint), "minio.local:9000")
        XCTAssertNotEqual(aws.destination, other.destination)
    }

    func testAPutIsSignedAndSaysWhatItCarries() throws {
        let bucket = FakeBucket()
        let client = S3Client(account: try XCTUnwrap(S3Account(settings: settings(), secret: "s")),
                              transport: bucket)
        try client.put("books/x/raw/p1.jsonl", data: Data("{}\n".utf8), contentType: "application/x-ndjson")
        let request = try XCTUnwrap(bucket.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/x-ndjson")
        let auth = try XCTUnwrap(request.value(forHTTPHeaderField: "authorization"))
        XCTAssertTrue(auth.contains("Credential=AKIAEXAMPLE/"))
        XCTAssertTrue(auth.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"))
        XCTAssertNil(request.value(forHTTPHeaderField: "host"), "URLSession writes Host itself")
    }

    func testARefusalSaysWhatS3Said() throws {
        let bucket = FakeBucket()
        bucket.refusal = (403, "<?xml version=\"1.0\"?><Error><Code>SignatureDoesNotMatch</Code>"
            + "<Message>The request signature we calculated does not match.</Message></Error>")
        let client = S3Client(account: try XCTUnwrap(S3Account(settings: settings(), secret: "s")),
                              transport: bucket)
        XCTAssertThrowsError(try client.check(app: "Brainio Pen")) { error in
            XCTAssertEqual(error as? S3Error, .refused(status: 403, code: "SignatureDoesNotMatch",
                message: "The request signature we calculated does not match."))
            XCTAssertTrue(error.localizedDescription.hasPrefix("The bucket refused the keys."))
        }
    }

    func testTheSecretIsKeptInAFileOnlyItsOwnerCanRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-secret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s3-secret")
        XCTAssertNil(S3Secret.read(at: url))
        try S3Secret.write("  abc/123  ", to: url)
        XCTAssertEqual(S3Secret.read(at: url), "abc/123")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o600)
        try S3Secret.write("", to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Against a real bucket, when one is named. Skipped otherwise, so the suite needs no network.
    ///
    ///     BRAINIO_PEN_TEST_S3_BUCKET=… BRAINIO_PEN_TEST_S3_KEY_ID=… BRAINIO_PEN_TEST_S3_SECRET=… \
    ///     [BRAINIO_PEN_TEST_S3_REGION=…] [BRAINIO_PEN_TEST_S3_ENDPOINT=…] swift test --filter S3Tests
    func testARealBucketTakesAFile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bucket = env["BRAINIO_PEN_TEST_S3_BUCKET"], env["BRAINIO_PEN_TEST_S3_READ"] == nil else {
            throw XCTSkip("no bucket named; set BRAINIO_PEN_TEST_S3_BUCKET (and not _READ) to run this")
        }
        var s = S3Settings()
        s.bucket = bucket
        s.accessKeyId = env["BRAINIO_PEN_TEST_S3_KEY_ID"] ?? ""
        s.region = env["BRAINIO_PEN_TEST_S3_REGION"] ?? s.region
        s.endpoint = env["BRAINIO_PEN_TEST_S3_ENDPOINT"] ?? ""
        s.prefix = "brainio pen test"
        let account = try XCTUnwrap(S3Account(settings: s, secret: env["BRAINIO_PEN_TEST_S3_SECRET"]))
        let client = S3Client(account: account)
        try client.check(app: "Brainio Pen tests")
        try client.put("books/s3-o27-b450-abcdef/raw/p1.jsonl", data: Data("{\"v\":1}\n".utf8),
                       contentType: "application/x-ndjson")

        // And the wrong secret is refused, in words.
        let wrong = S3Client(account: try XCTUnwrap(S3Account(settings: s, secret: "not the secret")))
        XCTAssertThrowsError(try wrong.check(app: "Brainio Pen tests")) { error in
            guard case .refused(403, _, _) = error as? S3Error else { return XCTFail("\(error)") }
        }
    }

    // MARK: transcripts

    /// The one thing read from the bucket: what the other side wrote about a page.
    func testATranscriptIsFetchedKeptAndShownAgainOffline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainio-pen-tr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = FakeBucket()
        let client = S3Client(account: try XCTUnwrap(S3Account(settings: settings { $0.prefix = "pen" }, secret: "s")),
                              transport: bucket)
        var connected: S3Client? = client
        let store = TranscriptStore(root: root) { connected }
        let page = PageRef(folder: try XCTUnwrap(BookFolder(name: "s3-o1012-b3017-70ab24")),
                           page: PageID(section: 3, owner: 1012, book: 3017, page: 21))
        XCTAssertEqual(TranscriptStore.path(for: page), "transcripts/s3-o1012-b3017-70ab24/p21.md")

        // Nobody has transcribed it: that is an answer, not an error.
        XCTAssertEqual(store.load(page), .none)
        XCTAssertEqual(bucket.requests.last?.httpMethod, "GET")
        XCTAssertEqual(bucket.requests.last?.url?.path, "/notes/pen/transcripts/s3-o1012-b3017-70ab24/p21.md")

        bucket.place(Data("# Notebook\nhello".utf8), at: "/notes/pen/transcripts/s3-o1012-b3017-70ab24/p21.md")
        XCTAssertEqual(store.load(page), .text("# Notebook\nhello"))
        XCTAssertEqual(store.cached(for: page), .text("# Notebook\nhello"))

        // Offline, and with no bucket at all, the copy on this Mac is what is shown.
        bucket.offline = true
        XCTAssertEqual(store.load(page), .text("# Notebook\nhello"))
        connected = nil
        XCTAssertEqual(store.load(page), .text("# Notebook\nhello"))

        // A page never fetched, and a bucket that will not answer: say why.
        connected = client
        let other = PageRef(folder: page.folder, page: PageID(section: 3, owner: 1012, book: 3017, page: 22))
        guard case .unavailable = store.load(other) else { return XCTFail("expected a reason") }
        // Nothing was ever written to the bucket by any of this.
        XCTAssertTrue(bucket.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    /// Read one named file from a real bucket. Read only: it writes nothing.
    ///
    ///     BRAINIO_PEN_TEST_S3_READ=transcripts/<copy>/p<N>.md plus the bucket variables above.
    func testARealBucketGivesAFileBack() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bucket = env["BRAINIO_PEN_TEST_S3_BUCKET"], let key = env["BRAINIO_PEN_TEST_S3_READ"] else {
            throw XCTSkip("no file named; set BRAINIO_PEN_TEST_S3_READ to run this")
        }
        var s = S3Settings()
        s.bucket = bucket
        s.accessKeyId = env["BRAINIO_PEN_TEST_S3_KEY_ID"] ?? ""
        s.region = env["BRAINIO_PEN_TEST_S3_REGION"] ?? s.region
        s.endpoint = env["BRAINIO_PEN_TEST_S3_ENDPOINT"] ?? ""
        let client = S3Client(account: try XCTUnwrap(S3Account(settings: s, secret: env["BRAINIO_PEN_TEST_S3_SECRET"])))
        let data = try XCTUnwrap(try client.get(key))
        XCTAssertFalse(data.isEmpty)
        XCTAssertNil(try client.get(key + ".there-is-no-such-file"))
    }
}
