import Foundation

/// The browser client's static assets (`client.html` + `client.js`), loaded once
/// from the resource bundle.
///
/// The page is fully static — nothing is interpolated server-side. The video
/// codec the client needs is delivered at runtime as the first text frame on the
/// media WebSocket (see `Broadcaster`/`SameDeskServer`), so these are authored as
/// real `.html`/`.js` files (full editor tooling, no Swift-string escaping) and
/// served verbatim.
///
/// Video path is modular with two backends sharing one interface:
///   - **WebCodecs** (default when supported): demux our fMP4 fragments to raw
///     AVCC, feed `EncodedVideoChunk`s to a `VideoDecoder`, render `VideoFrame`s
///     to a `<canvas>`. Lowest latency, no MSE buffering.
///   - **MSE** (fallback): append fragments to a `SourceBuffer`.
enum ClientAssets {
    /// The HTML document served at `GET /`.
    static let html: String = load("client", "html")

    /// The JavaScript served at `GET /client.js`.
    static let js: String = load("client", "js")

    private static func load(_ name: String, _ ext: String) -> String {
        for url in candidateURLs(name, ext) {
            if let contents = try? String(contentsOf: url, encoding: .utf8) { return contents }
        }
        fatalError("Missing bundled client asset \(name).\(ext)")
    }

    /// Resolve a bundled asset across every layout SameDesk ships in: a bare
    /// SwiftPM binary (resource bundle next to the executable), a `.app`
    /// (assets flat in `Contents/Resources`, or in the nested resource bundle),
    /// and `swift run` (resource bundle under `.build`). Deliberately avoids
    /// `Bundle.module`, whose generated accessor hard-codes a single path and
    /// `fatalError`s on init if the bundle isn't exactly there.
    private static func candidateURLs(_ name: String, _ ext: String) -> [URL] {
        var urls: [URL] = []
        func add(_ url: URL?) { if let url { urls.append(url) } }

        // Flat inside the main bundle, e.g. `SameDesk.app/Contents/Resources`.
        add(Bundle.main.url(forResource: name, withExtension: ext))

        // Inside the SwiftPM resource bundle, wherever it sits relative to us.
        let resourceBundle = "SameDesk_SameDesk.bundle"
        let roots = [Bundle.main.bundleURL,
                     Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(resourceBundle)) {
                add(bundle.url(forResource: name, withExtension: ext))
            }
        }
        return urls
    }
}
