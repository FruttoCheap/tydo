import Foundation
import PDFKit
import AppKit

/// Reads a text-based document (pdf/docx/doc/rtf/html/txt/md) and asks the
/// chat model to pull out actionable items — the "hand it a document instead
/// of typing" front door to the same manual-capture path. Read-only: callers
/// insert the returned strings as Todos themselves, exactly like typed capture.
actor DocumentImportService {
    private let llm: LLMService

    /// Rough character budget per model call — comfortably inside context for
    /// any locally-hosted chat model without needing to count tokens.
    private let chunkSize = 8000
    private let chunkOverlap = 400
    static let maxBytes = 5 * 1024 * 1024
    private let maxChunks = 64
    static let supportedExtensions = Set(["pdf", "txt", "md", "markdown", "doc", "docx", "rtf", "rtfd", "html", "htm"])

    init(llm: LLMService) {
        self.llm = llm
    }

    enum ImportError: Error, LocalizedError {
        case unreadable
        case empty
        case unsupported
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that document."
            case .empty: return "No text found in that document."
            case .unsupported: return "Unsupported document type. Supported extensions: pdf, txt, md, markdown, doc, docx, rtf, rtfd, html, htm."
            case .tooLarge: return "Document exceeds the 5 MiB or 64 chunk limit."
            }
        }
    }

    /// Extracts text from `url`, asks the model to list actionable items, and
    /// returns them deduplicated. Never writes anything — the caller decides
    /// which items to keep and inserts them like any manually captured todo.
    func extractItems(from url: URL) async throws -> [String] {
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { throw ImportError.unsupported }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maxBytes else { throw ImportError.tooLarge }
        let text = try Self.readText(from: url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.empty }
        let chunks = Self.chunk(text, size: chunkSize, overlap: chunkOverlap)
        guard chunks.count <= maxChunks else { throw ImportError.tooLarge }

        var seen = Set<String>()
        var items: [String] = []
        for chunk in chunks {
            for item in try await extractChunk(chunk) {
                let key = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                items.append(item)
            }
        }
        return items
    }

    private func extractChunk(_ text: String) async throws -> [String] {
        let out = try await llm.chat(
            [ ChatMessage(.system, DocumentPrompts.extractSystem),
              ChatMessage(.user, text) ],
            temperature: 0.0
        )
        return Self.parseItems(out)
    }

    // MARK: - Text extraction (native frameworks only — no third-party deps)

    private static func readText(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        switch url.pathExtension.lowercased() {
        case "txt", "md", "markdown":
            for encoding in [String.Encoding.utf8, .utf16, .isoLatin1] {
                if let text = try? String(contentsOf: url, encoding: encoding) { return text }
            }
            throw ImportError.unreadable
        case "pdf":
            guard let doc = PDFDocument(url: url), let text = doc.string else {
                throw ImportError.unreadable
            }
            return text
        default:
            // doc, docx, rtf, rtfd, html — AppKit already knows how to read these.
            guard let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw ImportError.unreadable
            }
            return attributed.string
        }
    }

    // MARK: - Chunking

    // ponytail: naive fixed-size character split, not sentence-aware — fine
    // for local models with 8k+ context; add smarter splitting only if items
    // keep getting truncated at chunk boundaries in practice.
    private static func chunk(_ text: String, size: Int, overlap: Int) -> [String] {
        guard text.count > size else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            if end == text.endIndex { break }
            start = text.index(end, offsetBy: -overlap, limitedBy: text.startIndex) ?? end
        }
        return chunks
    }

    // MARK: - Parsing

    /// Extract a JSON array of strings even if the model wrapped it in prose
    /// or ```json fences; empty (never throws) on a malformed reply.
    private static func parseItems(_ raw: String) -> [String] {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"),
              start < end else { return [] }
        let json = String(raw[start...end])
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
