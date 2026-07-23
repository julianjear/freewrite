import SwiftUI
import AppKit

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var backgroundColor: NSColor
    var lineSpacing: CGFloat
    var controller: EditorController? = nil
    var suppressTextInteraction = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.alphaValue = 0
        scrollView.borderType = .noBorder

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = !suppressTextInteraction
        textView.isSelectable = !suppressTextInteraction
        textView.allowsUndo = true
        textView.isRichText = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: font.pointSize)
        textView.textContainer?.lineFragmentPadding = 5

        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.currentFont = font
        context.coordinator.currentTextColor = textColor
        context.coordinator.currentLineSpacing = lineSpacing
        context.coordinator.parent = self
        context.coordinator.registerWith(controller)

        textView.string = Coordinator.markdownToDisplay(text)
        context.coordinator.applyMarkdownStyling()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        scrollView.backgroundColor = backgroundColor
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = textColor
        textView.isEditable = !suppressTextInteraction
        textView.isSelectable = !suppressTextInteraction

        context.coordinator.currentFont = font
        context.coordinator.currentTextColor = textColor
        context.coordinator.currentLineSpacing = lineSpacing
        context.coordinator.parent = self
        context.coordinator.registerWith(controller)

        let displayText = Coordinator.markdownToDisplay(text)
        if textView.string != displayText {
            context.coordinator.isUpdating = true
            let selectedRanges = textView.selectedRanges
            textView.string = displayText

            let maxLen = (textView.string as NSString).length
            let validRanges = selectedRanges.compactMap { val -> NSValue? in
                let r = val.rangeValue
                guard r.location <= maxLen else { return nil }
                return NSValue(range: NSRange(location: r.location, length: min(r.length, maxLen - r.location)))
            }
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
            context.coordinator.applyMarkdownStyling()
            context.coordinator.isUpdating = false
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var currentFont: NSFont
        var currentTextColor: NSColor
        var currentLineSpacing: CGFloat
        var isUpdating = false

        // List continuation patterns (match both raw markdown markers and display bullet •)
        private static let bulletRegex = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+•])\\s(.*)")
        private static let numberRegex = try! NSRegularExpression(pattern: "^([ \\t]*)(\\d+)\\.\\s(.*)")
        private static let checkboxRegex = try! NSRegularExpression(pattern: "^([ \\t]*[-*+•])\\s\\[[ xX]\\]\\s(.*)")

        init(_ parent: MarkdownEditor) {
            self.parent = parent
            self.currentFont = parent.font
            self.currentTextColor = parent.textColor
            self.currentLineSpacing = parent.lineSpacing
        }

        // MARK: - Markdown <-> Display Conversion

        /// Converts raw markdown bullets (- , * , + ) to display bullets (•) for rendering.
        static func markdownToDisplay(_ text: String) -> String {
            return text.replacingOccurrences(
                of: "(?m)^([ \\t]*)([-*+]) ",
                with: "$1• ",
                options: .regularExpression
            )
        }

        /// Converts display bullets (•) back to markdown dashes (-) for saving to .md files.
        static func displayToMarkdown(_ text: String) -> String {
            return text.replacingOccurrences(
                of: "(?m)^([ \\t]*)• ",
                with: "$1- ",
                options: .regularExpression
            )
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isUpdating else { return }
            isUpdating = true

            // Convert any raw markdown bullets the user just typed into display bullets
            convertRawBulletsInPlace(textView: textView)

            // Save the markdown version (• → -) to the binding
            parent.text = Self.displayToMarkdown(textView.string)
            applyMarkdownStyling()
            isUpdating = false
        }

        /// Replaces any raw markdown bullet markers (-, *, +) at line starts with •.
        /// Uses targeted textStorage replacement to preserve undo history.
        private func convertRawBulletsInPlace(textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let nsText = storage.string as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)

            guard let regex = try? NSRegularExpression(pattern: "(?m)^([ \\t]*)([-*+]) ", options: []) else { return }

            let matches = regex.matches(in: nsText as String, range: fullRange)
            guard !matches.isEmpty else { return }

            // Disable undo for the auto-conversion so it doesn't pollute undo stack
            textView.undoManager?.disableUndoRegistration()

            // Replace in reverse order to preserve earlier range positions
            for match in matches.reversed() {
                let markerRange = match.range(at: 2)
                storage.replaceCharacters(in: markerRange, with: "•")
            }

            textView.undoManager?.enableUndoRegistration()
        }

        // MARK: - Markdown Styling

        func applyMarkdownStyling() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            let length = storage.length
            guard length > 0 else { return }
            let fullRange = NSRange(location: 0, length: length)

            let baseParagraphStyle = NSMutableParagraphStyle()
            baseParagraphStyle.lineSpacing = currentLineSpacing

            storage.beginEditing()

            // Reset to base style
            storage.setAttributes([
                .font: currentFont,
                .foregroundColor: currentTextColor,
                .paragraphStyle: baseParagraphStyle
            ], range: fullRange)

            let text = storage.string
            let nsText = text as NSString

            // List indentation (before other styling so paragraph styles are set first)
            applyListIndentation(storage: storage, nsText: nsText, fullRange: fullRange, baseParagraphStyle: baseParagraphStyle)

            // Headers
            applyHeaderStyling(storage: storage, nsText: nsText, fullRange: fullRange, prefix: "### ", sizeMultiplier: 1.1)
            applyHeaderStyling(storage: storage, nsText: nsText, fullRange: fullRange, prefix: "## ", sizeMultiplier: 1.25)
            applyHeaderStyling(storage: storage, nsText: nsText, fullRange: fullRange, prefix: "# ", sizeMultiplier: 1.5)

            // Bold: **text**
            applyBoldStyling(storage: storage, text: text, fullRange: fullRange)

            // Italic: *text*
            applyItalicStyling(storage: storage, text: text, fullRange: fullRange)

            storage.endEditing()
        }

        // MARK: - List Indentation

        private func applyListIndentation(storage: NSTextStorage, nsText: NSString, fullRange: NSRange, baseParagraphStyle: NSMutableParagraphStyle) {
            // Adjust this multiplier to control how far lists are indented from the left margin
            let baseIndent: CGFloat = round(currentFont.pointSize * 1.0)
            let bulletMarkerWidth = ("• " as NSString).size(withAttributes: [.font: currentFont]).width
            let numberMarkerWidth = ("1. " as NSString).size(withAttributes: [.font: currentFont]).width

            // Bullet lines (• item)
            if let bulletLineRegex = try? NSRegularExpression(pattern: "^[ \\t]*•[ \\t].*", options: .anchorsMatchLines) {
                bulletLineRegex.enumerateMatches(in: nsText as String, range: fullRange) { match, _, _ in
                    guard let range = match?.range else { return }
                    let listStyle = NSMutableParagraphStyle()
                    listStyle.lineSpacing = self.currentLineSpacing
                    listStyle.firstLineHeadIndent = baseIndent
                    listStyle.headIndent = baseIndent + ceil(bulletMarkerWidth)
                    storage.addAttribute(.paragraphStyle, value: listStyle, range: range)
                }
            }

            // Numbered list lines (1. item)
            if let numberLineRegex = try? NSRegularExpression(pattern: "^[ \\t]*\\d+\\.[ \\t].*", options: .anchorsMatchLines) {
                numberLineRegex.enumerateMatches(in: nsText as String, range: fullRange) { match, _, _ in
                    guard let range = match?.range else { return }
                    let listStyle = NSMutableParagraphStyle()
                    listStyle.lineSpacing = self.currentLineSpacing
                    listStyle.firstLineHeadIndent = baseIndent
                    listStyle.headIndent = baseIndent + ceil(numberMarkerWidth)
                    storage.addAttribute(.paragraphStyle, value: listStyle, range: range)
                }
            }
        }

        // MARK: - Header Styling

        static func headerPattern(prefix: String) -> NSRegularExpression? {
            let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
            return try? NSRegularExpression(
                pattern: "^\(escapedPrefix).*",
                options: .anchorsMatchLines
            )
        }

        private func applyHeaderStyling(storage: NSTextStorage, nsText: NSString, fullRange: NSRange, prefix: String, sizeMultiplier: CGFloat) {
            // Match the marker immediately, even before the first heading
            // character exists. `.+` delayed the visual heading state until
            // the user typed one more character after "# ".
            guard let regex = Self.headerPattern(prefix: prefix) else { return }

            regex.enumerateMatches(in: nsText as String, range: fullRange) { match, _, _ in
                guard let range = match?.range else { return }
                let size = self.currentFont.pointSize * sizeMultiplier
                let baseFont = NSFont(name: self.currentFont.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
                let boldFont = self.fontByAddingBoldTrait(to: baseFont)
                storage.addAttribute(.font, value: boldFont.font, range: range)
                if !boldFont.hasTrait {
                    storage.addAttribute(.strokeWidth, value: NSNumber(value: -3.0), range: range)
                }
            }
        }

        // MARK: - Bold Styling

        private func applyBoldStyling(storage: NSTextStorage, text: String, fullRange: NSRange) {
            guard let regex = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*") else { return }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match = match else { return }
                let contentRange = match.range(at: 1)
                let boldResult = self.fontByAddingBoldTrait(to: self.currentFont)
                storage.addAttribute(.font, value: boldResult.font, range: contentRange)
                if !boldResult.hasTrait {
                    storage.addAttribute(.strokeWidth, value: NSNumber(value: -3.0), range: contentRange)
                }

                // Dim the ** markers
                let dimColor = self.currentTextColor.withAlphaComponent(0.3)
                let startMarker = NSRange(location: match.range.location, length: 2)
                let endMarker = NSRange(location: match.range.location + match.range.length - 2, length: 2)
                storage.addAttribute(.foregroundColor, value: dimColor, range: startMarker)
                storage.addAttribute(.foregroundColor, value: dimColor, range: endMarker)
            }
        }

        // MARK: - Italic Styling

        private func applyItalicStyling(storage: NSTextStorage, text: String, fullRange: NSRange) {
            guard let regex = try? NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)") else { return }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match = match else { return }
                let contentRange = match.range(at: 1)
                let italicFont = NSFontManager.shared.convert(self.currentFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italicFont, range: contentRange)
                if italicFont.fontName == self.currentFont.fontName {
                    storage.addAttribute(.obliqueness, value: NSNumber(value: 0.2), range: contentRange)
                }

                // Dim the * markers
                let dimColor = self.currentTextColor.withAlphaComponent(0.3)
                let startMarker = NSRange(location: match.range.location, length: 1)
                let endMarker = NSRange(location: match.range.location + match.range.length - 1, length: 1)
                storage.addAttribute(.foregroundColor, value: dimColor, range: startMarker)
                storage.addAttribute(.foregroundColor, value: dimColor, range: endMarker)
            }
        }

        // MARK: - Font Helpers

        /// Attempts to produce a bold variant of the given font.
        /// Returns the font and whether the bold trait was actually applied.
        private func fontByAddingBoldTrait(to font: NSFont) -> (font: NSFont, hasTrait: Bool) {
            let manager = NSFontManager.shared

            // Try NSFontManager conversion first
            let converted = manager.convert(font, toHaveTrait: .boldFontMask)
            if manager.traits(of: converted).contains(.boldFontMask) {
                return (converted, true)
            }

            // Try font descriptor approach
            let descriptor = font.fontDescriptor.withSymbolicTraits(.bold)
            if let descriptorFont = NSFont(descriptor: descriptor, size: font.pointSize) {
                if manager.traits(of: descriptorFont).contains(.boldFontMask) {
                    return (descriptorFont, true)
                }
            }

            // Font has no bold variant; caller should use strokeWidth fallback
            return (font, false)
        }

        // MARK: - List Continuation

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleNewline(textView: textView)
            }
            return false
        }

        private func handleNewline(textView: NSTextView) -> Bool {
            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else { return false }

            let nsText = textView.string as NSString
            let cursorLocation = selectedRange.location
            guard cursorLocation > 0 else { return false }

            let lineRange = nsText.lineRange(for: NSRange(location: cursorLocation, length: 0))
            let lineTextLength = cursorLocation - lineRange.location
            guard lineTextLength > 0 else { return false }

            let currentLine = nsText.substring(with: NSRange(location: lineRange.location, length: lineTextLength))
            let lineNSRange = NSRange(location: 0, length: currentLine.count)

            // Checkbox lists (check before bullets since it's more specific): "• [ ] text"
            if let match = Self.checkboxRegex.firstMatch(in: currentLine, range: lineNSRange) {
                let prefix = (currentLine as NSString).substring(with: match.range(at: 1))
                let content = (currentLine as NSString).substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)

                if content.isEmpty {
                    let deleteRange = NSRange(location: lineRange.location, length: lineTextLength)
                    textView.insertText("\n", replacementRange: deleteRange)
                    return true
                }

                textView.insertText("\n\(prefix) [ ] ", replacementRange: textView.selectedRange())
                return true
            }

            // Bullet points: "• text" or "- text", "* text", "+ text"
            if let match = Self.bulletRegex.firstMatch(in: currentLine, range: lineNSRange) {
                let indent = (currentLine as NSString).substring(with: match.range(at: 1))
                let content = (currentLine as NSString).substring(with: match.range(at: 3))
                    .trimmingCharacters(in: .whitespaces)

                if content.isEmpty {
                    let deleteRange = NSRange(location: lineRange.location, length: lineTextLength)
                    textView.insertText("\n", replacementRange: deleteRange)
                    return true
                }

                // Always continue with • for display consistency
                textView.insertText("\n\(indent)• ", replacementRange: textView.selectedRange())
                return true
            }

            // Numbered lists: "1. text", "2. text", etc.
            if let match = Self.numberRegex.firstMatch(in: currentLine, range: lineNSRange) {
                let indent = (currentLine as NSString).substring(with: match.range(at: 1))
                let numberStr = (currentLine as NSString).substring(with: match.range(at: 2))
                let content = (currentLine as NSString).substring(with: match.range(at: 3))
                    .trimmingCharacters(in: .whitespaces)
                let number = Int(numberStr) ?? 0

                if content.isEmpty {
                    let deleteRange = NSRange(location: lineRange.location, length: lineTextLength)
                    textView.insertText("\n", replacementRange: deleteRange)
                    return true
                }

                textView.insertText("\n\(indent)\(number + 1). ", replacementRange: textView.selectedRange())
                return true
            }

            return false
        }

        // MARK: - External insertion

        /// Inserts a prompt at the current cursor on its own line. The normal
        /// text-change path handles markdown styling, persistence, and undo.
        func insertAtCursor(_ string: String) {
            guard let textView else { return }
            textView.isEditable = true
            textView.isSelectable = true

            let selection = textView.selectedRange()
            let source = textView.string as NSString
            var prefix = ""
            if selection.location > 0,
               source.character(at: selection.location - 1) != 0x0A {
                prefix = "\n\n"
            } else if selection.location > 1,
                      source.character(at: selection.location - 2) != 0x0A {
                prefix = "\n"
            }

            var suffix = "\n\n"
            if selection.location < source.length,
               source.character(at: selection.location) == 0x0A {
                suffix = "\n"
            }

            let insertion = prefix + string + suffix
            textView.insertText(insertion, replacementRange: selection)
            textView.setSelectedRange(NSRange(
                location: selection.location + (insertion as NSString).length,
                length: 0
            ))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        /// Adds a reflection question as the final H3 section and deliberately
        /// leaves enough writable space below it to position the prompt near
        /// the top of the editor instead of stranded against the bottom edge.
        @discardableResult
        func appendReflectionQuestion(_ question: String) -> Bool {
            guard let textView else { return false }
            let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return false }

            textView.isEditable = true
            textView.isSelectable = true
            let source = textView.string as NSString
            let separator: String
            if source.length == 0 || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                separator = ""
            } else if source.hasSuffix("\n\n") {
                separator = ""
            } else if source.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }

            let scrollView = textView.enclosingScrollView
            let viewportHeight = max(320, scrollView?.contentView.bounds.height ?? 0)
            let lineHeight = max(
                18,
                NSLayoutManager().defaultLineHeight(for: currentFont) + currentLineSpacing
            )
            let trailingLineCount = min(30, max(14, Int(ceil(viewportHeight * 0.72 / lineHeight))))
            let heading = "### \(clean)"
            let answerPrefix = "\(separator)\(heading)\n\n"
            let insertion = answerPrefix + String(repeating: "\n", count: trailingLineCount)
            let headingLocation = source.length + (separator as NSString).length
            let answerLocation = source.length + (answerPrefix as NSString).length

            textView.setSelectedRange(NSRange(location: source.length, length: 0))
            textView.insertText(insertion, replacementRange: textView.selectedRange())
            textView.setSelectedRange(NSRange(location: answerLocation, length: 0))
            applyMarkdownStyling()
            textView.window?.makeFirstResponder(textView)

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView,
                      let scrollView = textView.enclosingScrollView,
                      let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer else { return }
                layoutManager.ensureLayout(for: textContainer)
                let characterRange = NSRange(
                    location: headingLocation,
                    length: (heading as NSString).length
                )
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: characterRange,
                    actualCharacterRange: nil
                )
                var headingRect = layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: textContainer
                )
                headingRect.origin.y += textView.textContainerOrigin.y
                let clipView = scrollView.contentView
                let maxY = max(0, textView.bounds.height - clipView.bounds.height)
                let targetY = min(maxY, max(0, headingRect.minY - clipView.bounds.height * 0.18))
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(clipView)
                textView.setSelectedRange(NSRange(location: answerLocation, length: 0))
                self.applyMarkdownStyling()
            }
            return true
        }
    }
}
