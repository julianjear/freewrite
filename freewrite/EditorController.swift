import AppKit
import Foundation

/// Lets the prompts overlay insert at the live editor selection and return
/// focus without routing cursor state through SwiftUI bindings.
@MainActor
final class EditorController: ObservableObject {
    fileprivate weak var coordinator: MarkdownEditor.Coordinator?

    func insertAtCursor(_ string: String) {
        coordinator?.insertAtCursor(string)
    }

    /// Appends an H3 reflection question, places the answer caret beneath it,
    /// and positions that new section in the upper portion of the viewport.
    @discardableResult
    func appendReflectionQuestion(_ question: String) -> Bool {
        coordinator?.appendReflectionQuestion(question) ?? false
    }

    func focus() {
        guard let textView = coordinator?.textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}

extension MarkdownEditor.Coordinator {
    @MainActor
    func registerWith(_ controller: EditorController?) {
        controller?.coordinator = self
    }
}
