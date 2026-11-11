import Foundation
import SihemaCore
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Colours the lines on screen using TextKit 2 rendering attributes. Nothing is written into the text storage,
/// so the file text, undo and typing are untouched, and only a screenful is ever scanned.
enum EditorHighlight {
    static func color(for kind: SyntaxKind) -> PlatformColor {
        #if os(macOS)
        switch kind {
        case .comment: return .secondaryLabelColor
        case .generalCode: return .systemBlue
        case .miscCode: return .systemOrange
        case .sequence: return .tertiaryLabelColor
        case .axis: return .labelColor
        case .feed: return .systemGreen
        case .speed: return .systemTeal
        case .tool: return .systemPurple
        case .address: return .labelColor
        case .macro: return .systemPink
        case .delimiter: return .tertiaryLabelColor
        }
        #else
        switch kind {
        case .comment: return .secondaryLabel
        case .generalCode: return .systemBlue
        case .miscCode: return .systemOrange
        case .sequence: return .tertiaryLabel
        case .axis: return .label
        case .feed: return .systemGreen
        case .speed: return .systemTeal
        case .tool: return .systemPurple
        case .address: return .label
        case .macro: return .systemPink
        case .delimiter: return .tertiaryLabel
        }
        #endif
    }

    /// The characters currently laid out on screen, or nil when the text view has not laid anything out yet.
    static func visibleRange(_ layoutManager: NSTextLayoutManager?) -> NSRange? {
        guard let layoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange,
              let content = layoutManager.textContentManager else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let length = content.offset(from: viewport.location, to: viewport.endLocation)
        guard start >= 0, length >= 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    /// Colours the whole lines that touch `range`.
    static func apply(string: NSString, layoutManager: NSTextLayoutManager, range: NSRange) {
        guard let content = layoutManager.textContentManager, string.length > 0 else { return }
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        let lines = string.lineRange(for: safe)
        let text = string.substring(with: lines)
        let bytes = Array(text.utf8)

        // byte offset -> UTF-16 offset inside `text`
        var map = [Int](repeating: 0, count: bytes.count + 1)
        var byte = 0
        var unit = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let byteCount = v < 0x80 ? 1 : (v < 0x800 ? 2 : (v < 0x10000 ? 3 : 4))
            for k in 0..<byteCount where byte + k < map.count { map[byte + k] = unit }
            byte += byteCount
            unit += v >= 0x10000 ? 2 : 1
        }
        map[min(byte, bytes.count)] = unit

        func textRange(_ r: NSRange) -> NSTextRange? {
            guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                  let end = content.location(start, offsetBy: r.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        guard let wholeRange = textRange(lines) else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: wholeRange)
        for span in SyntaxHighlighter.spans(in: bytes) {
            let from = map[min(span.start, bytes.count)]
            let to = map[min(span.end, bytes.count)]
            guard to > from,
                  let r = textRange(NSRange(location: lines.location + from, length: to - from)) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color(for: span.kind), for: r)
        }
    }
}
