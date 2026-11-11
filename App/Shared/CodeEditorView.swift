import SwiftUI

#if os(macOS)
import AppKit

/// Monospaced text editor on TextKit 2. The lines on screen are coloured as G-code.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text

        context.coordinator.textView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.scheduleHighlight()
        }
        context.coordinator.scheduleHighlight(delay: 0.15)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.scheduleHighlight(delay: 0.05)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        var scrollObserver: NSObjectProtocol?
        private var pending: DispatchWorkItem?

        init(_ parent: CodeEditorView) { self.parent = parent }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            scheduleHighlight(delay: 0.02)
        }

        func scheduleHighlight(delay: TimeInterval = 0.03) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func highlightNow() {
            guard let textView, let layoutManager = textView.textLayoutManager,
                  let storage = textView.textStorage else { return }
            let length = storage.mutableString.length
            let range = EditorHighlight.visibleRange(layoutManager) ?? NSRange(location: 0, length: min(length, 20_000))
            EditorHighlight.apply(string: storage.mutableString, layoutManager: layoutManager, range: range)
            textView.needsDisplay = true
        }
    }
}

#else
import UIKit

struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .allCharacters
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.alwaysBounceVertical = true
        textView.text = text
        context.coordinator.textView = textView
        context.coordinator.scheduleHighlight(delay: 0.15)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
            context.coordinator.scheduleHighlight(delay: 0.05)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        weak var textView: UITextView?
        private var pending: DispatchWorkItem?

        init(_ parent: CodeEditorView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            scheduleHighlight(delay: 0.02)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scheduleHighlight()
        }

        func scheduleHighlight(delay: TimeInterval = 0.03) {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func highlightNow() {
            guard let textView, let layoutManager = textView.textLayoutManager else { return }
            let string = textView.textStorage.mutableString
            let range = EditorHighlight.visibleRange(layoutManager) ?? NSRange(location: 0, length: min(string.length, 20_000))
            EditorHighlight.apply(string: string, layoutManager: layoutManager, range: range)
            textView.setNeedsDisplay()
        }
    }
}
#endif
