import Foundation
import AppKit
import Vision

enum ImageOCR {
    /// Extract the best search query from an image via OCR.
    /// Returns the first detected handle (e.g. evan@id), full OCR text, or nil if nothing found.
    static func extractQuery(from image: NSImage) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("[Veritas] OCR: failed to get CGImage from NSImage")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    print("[Veritas] OCR: no observations returned")
                    continuation.resume(returning: nil)
                    return
                }

                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                print("[Veritas] OCR lines: \(lines)")
                let query = Self.bestQuery(from: lines)
                print("[Veritas] OCR bestQuery: \(query ?? "nil")")
                continuation.resume(returning: query)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[Veritas] OCR failed: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Pick the best search query from OCR lines.
    /// Priority: handle (name@tld) > hex key > full text.
    private static func bestQuery(from lines: [String]) -> String? {
        let handleRegex = try! NSRegularExpression(pattern: #"[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+"#)
        let hexRegex = try! NSRegularExpression(pattern: #"(?:0[xX])?[0-9a-fA-F]{40,}"#)

        var bestHandle: String?
        var bestHex: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // Look for handles
            if bestHandle == nil,
               let match = handleRegex.firstMatch(in: trimmed, range: range),
               let r = Range(match.range, in: trimmed) {
                let h = String(trimmed[r])
                if !h.lowercased().contains("noreply") && !h.lowercased().contains("email") {
                    bestHandle = h
                }
            }

            // Look for hex keys
            if bestHex == nil,
               let match = hexRegex.firstMatch(in: trimmed, range: range),
               let r = Range(match.range, in: trimmed) {
                bestHex = String(trimmed[r])
            }
        }

        // Handle takes priority, then hex key, then full OCR text
        if let handle = bestHandle { return handle }
        if let hex = bestHex { return hex }

        // Fallback: return all OCR text joined (useful for sealed message search)
        let fullText = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return fullText.isEmpty ? nil : fullText
    }
}
