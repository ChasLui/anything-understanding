// macOS Vision OCR: real text + confidence + normalized bboxes, zero installs.
//
//   swiftc -O ocr.swift -o ocr && ./ocr shot.png
//   ./ocr shot.png --lang zh-Hans,en-US --json
//
// Coordinates are Vision's normalized space: origin bottom-left, x/y/w/h in
// 0..1 of the image. Convert to pixels with x*width, (1-y-h)*height.
// Prefer ../../references/ocr.sh: it caches the compiled binary.
import AppKit
import Foundation
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: ocr <image> [--lang a,b] [--json]") }
let path = args[1]
var languages: [String] = ["en-US"]
var asJSON = false
var i = 2
while i < args.count {
    switch args[i] {
    case "--json": asJSON = true
    case "--lang":
        i += 1
        guard i < args.count else { fail("--lang needs a value") }
        languages = args[i].split(separator: ",").map(String.init)
    default: fail("unknown argument \(args[i])")
    }
    i += 1
}

guard let image = NSImage(contentsOfFile: path),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("cannot decode image: \(path)") }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = languages

do {
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
} catch {
    fail("Vision failed: \(error.localizedDescription)")
}

let results = request.results ?? []
func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
}

if asJSON {
    let rows = results.compactMap { obs -> String? in
        guard let c = obs.topCandidates(1).first else { return nil }
        let b = obs.boundingBox
        return String(
            format: "{\"text\":\"%@\",\"confidence\":%.3f,\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f}",
            esc(c.string), c.confidence, b.origin.x, b.origin.y, b.size.width, b.size.height)
    }
    let langJSON = languages.map { "\"\($0)\"" }.joined(separator: ",")
    print("{\"file\":\"\(esc(path))\",\"languages\":[\(langJSON)],\"lines\":[\(rows.joined(separator: ","))]}")
} else {
    for obs in results {
        guard let c = obs.topCandidates(1).first else { continue }
        let b = obs.boundingBox
        print(String(format: "%.3f\t%.4f\t%.4f\t%.4f\t%.4f\t%@",
                     c.confidence, b.origin.x, b.origin.y, b.size.width, b.size.height, c.string))
    }
}
