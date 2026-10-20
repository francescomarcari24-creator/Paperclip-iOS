import SwiftUI
import UIKit

// MARK: - Custom NSAttributedString Keys for Paperclip Visual Editor

extension NSAttributedString.Key {
    static let paperclipHeading = NSAttributedString.Key("PaperclipHeading")
    static let paperclipQuote = NSAttributedString.Key("PaperclipQuote")
    static let paperclipInlineCode = NSAttributedString.Key("PaperclipInlineCode")
}

// MARK: - RichTextFormattingController

@MainActor
final class RichTextFormattingController: ObservableObject {
    @Published var isBold: Bool = false
    @Published var isItalic: Bool = false
    @Published var isStrikethrough: Bool = false
    @Published var isInlineCode: Bool = false
    @Published var isHeading: Bool = false
    @Published var isBulletList: Bool = false
    @Published var isQuote: Bool = false
    @Published var isEditorFocused: Bool = false

    weak var textView: UITextView?
    var onMarkdownChanged: ((String) -> Void)?
    private var isUpdatingInternally = false

    static let baseFontSize: CGFloat = 17
    static let headingFontSize: CGFloat = 22
    static let bulletPrefix = "• "
    static let quotePrefix = "▏ "

    // MARK: - Toolbar Actions

    private func ensureFocused(_ tv: UITextView) {
        if !tv.isFirstResponder {
            tv.becomeFirstResponder()
        }
    }

    func toggleBold() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        let range = tv.selectedRange
        if range.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
            let enable = !isBold
            mutable.enumerateAttribute(.font, in: range, options: []) { val, subrange, _ in
                let currentFont = (val as? UIFont) ?? Self.makeFont(bold: false, italic: false, size: Self.baseFontSize, mono: false)
                let traits = currentFont.fontDescriptor.symbolicTraits
                let isMono = traits.contains(.traitMonoSpace)
                let newFont = Self.makeFont(
                    bold: enable,
                    italic: traits.contains(.traitItalic),
                    size: currentFont.pointSize,
                    mono: isMono
                )
                mutable.addAttribute(.font, value: newFont, range: subrange)
            }
            applyAttributedText(mutable, selectedRange: range, to: tv)
        } else {
            isBold.toggle()
            syncTypingAttributes(on: tv)
        }
    }

    func toggleItalic() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        let range = tv.selectedRange
        if range.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
            let enable = !isItalic
            mutable.enumerateAttribute(.font, in: range, options: []) { val, subrange, _ in
                let currentFont = (val as? UIFont) ?? Self.makeFont(bold: false, italic: false, size: Self.baseFontSize, mono: false)
                let traits = currentFont.fontDescriptor.symbolicTraits
                let isMono = traits.contains(.traitMonoSpace)
                let newFont = Self.makeFont(
                    bold: traits.contains(.traitBold),
                    italic: enable,
                    size: currentFont.pointSize,
                    mono: isMono
                )
                mutable.addAttribute(.font, value: newFont, range: subrange)
            }
            applyAttributedText(mutable, selectedRange: range, to: tv)
        } else {
            isItalic.toggle()
            syncTypingAttributes(on: tv)
        }
    }

    func toggleStrikethrough() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        let range = tv.selectedRange
        if range.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
            let enable = !isStrikethrough
            if enable {
                mutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                mutable.removeAttribute(.strikethroughStyle, range: range)
            }
            applyAttributedText(mutable, selectedRange: range, to: tv)
        } else {
            isStrikethrough.toggle()
            syncTypingAttributes(on: tv)
        }
    }

    func toggleInlineCode() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        let range = tv.selectedRange
        if range.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
            let enable = !isInlineCode
            mutable.enumerateAttribute(.font, in: range, options: []) { val, subrange, _ in
                let currentFont = (val as? UIFont) ?? Self.makeFont(bold: false, italic: false, size: Self.baseFontSize, mono: false)
                let traits = currentFont.fontDescriptor.symbolicTraits
                let newFont = Self.makeFont(
                    bold: traits.contains(.traitBold),
                    italic: traits.contains(.traitItalic),
                    size: currentFont.pointSize,
                    mono: enable
                )
                mutable.addAttribute(.font, value: newFont, range: subrange)
                if enable {
                    mutable.addAttribute(.paperclipInlineCode, value: true, range: subrange)
                    mutable.addAttribute(.backgroundColor, value: UIColor.secondarySystemFill, range: subrange)
                } else {
                    mutable.removeAttribute(.paperclipInlineCode, range: subrange)
                    mutable.removeAttribute(.backgroundColor, range: subrange)
                }
            }
            applyAttributedText(mutable, selectedRange: range, to: tv)
        } else {
            isInlineCode.toggle()
            syncTypingAttributes(on: tv)
        }
    }

    func toggleHeading() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
        let nsStr = mutable.string as NSString
        let paraRange = nsStr.paragraphRange(for: tv.selectedRange)
        let enable = !isHeading

        if paraRange.length > 0 {
            let size = enable ? Self.headingFontSize : Self.baseFontSize
            mutable.enumerateAttribute(.font, in: paraRange, options: []) { val, subrange, _ in
                let currentFont = (val as? UIFont) ?? Self.makeFont(bold: false, italic: false, size: Self.baseFontSize, mono: false)
                let traits = currentFont.fontDescriptor.symbolicTraits
                let newFont = Self.makeFont(
                    bold: enable ? true : false,
                    italic: traits.contains(.traitItalic),
                    size: size,
                    mono: false
                )
                mutable.addAttribute(.font, value: newFont, range: subrange)
            }
            if enable {
                mutable.addAttribute(.paperclipHeading, value: true, range: paraRange)
            } else {
                mutable.removeAttribute(.paperclipHeading, range: paraRange)
            }
            applyAttributedText(mutable, selectedRange: tv.selectedRange, to: tv)
        } else {
            isHeading = enable
            if enable { isBold = true } else { isBold = false }
            syncTypingAttributes(on: tv)
        }
    }

    func toggleBulletList() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        toggleLinePrefixVisual(prefix: Self.bulletPrefix, otherPrefix: Self.quotePrefix, on: tv)
    }

    func toggleQuote() {
        guard let tv = textView else { return }
        ensureFocused(tv)
        toggleLinePrefixVisual(prefix: Self.quotePrefix, otherPrefix: Self.bulletPrefix, on: tv)
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }

    private func toggleLinePrefixVisual(prefix: String, otherPrefix: String, on tv: UITextView) {
        let mutable = NSMutableAttributedString(attributedString: tv.attributedText)
        let nsStr = mutable.string as NSString
        let paraRange = nsStr.paragraphRange(for: tv.selectedRange)
        let paraText = nsStr.substring(with: paraRange)

        var cursorDelta = 0
        if paraText.hasPrefix(prefix) {
            let removeRange = NSRange(location: paraRange.location, length: (prefix as NSString).length)
            mutable.replaceCharacters(in: removeRange, with: "")
            cursorDelta = -(prefix as NSString).length
        } else if paraText.hasPrefix(otherPrefix) {
            let replaceRange = NSRange(location: paraRange.location, length: (otherPrefix as NSString).length)
            let attrPrefix = NSAttributedString(string: prefix, attributes: defaultAttributes())
            mutable.replaceCharacters(in: replaceRange, with: attrPrefix)
            cursorDelta = (prefix as NSString).length - (otherPrefix as NSString).length
        } else {
            let attrPrefix = NSAttributedString(string: prefix, attributes: defaultAttributes())
            mutable.insert(attrPrefix, at: paraRange.location)
            cursorDelta = (prefix as NSString).length
        }

        let newCursor = max(0, min(mutable.length, tv.selectedRange.location + cursorDelta))
        applyAttributedText(mutable, selectedRange: NSRange(location: newCursor, length: tv.selectedRange.length), to: tv)
    }

    private func applyAttributedText(_ mutable: NSMutableAttributedString, selectedRange: NSRange, to tv: UITextView) {
        isUpdatingInternally = true
        tv.attributedText = mutable
        tv.selectedRange = selectedRange
        isUpdatingInternally = false
        refreshToolbarState(from: tv)
        onMarkdownChanged?(Self.serializeToMarkdown(tv.attributedText))
    }

    func refreshToolbarState(from tv: UITextView) {
        let nsStr = tv.attributedText.string as NSString
        let sel = tv.selectedRange
        let paraRange = nsStr.paragraphRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
        let paraText = nsStr.substring(with: paraRange)

        isBulletList = paraText.hasPrefix(Self.bulletPrefix)
        isQuote = paraText.hasPrefix(Self.quotePrefix)

        let attrs: [NSAttributedString.Key: Any]
        if sel.length > 0 && sel.location < tv.attributedText.length {
            attrs = tv.attributedText.attributes(at: sel.location, effectiveRange: nil)
        } else if sel.location > 0 && sel.location <= tv.attributedText.length {
            attrs = tv.typingAttributes
        } else {
            attrs = tv.typingAttributes
        }

        if let font = attrs[.font] as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            isBold = traits.contains(.traitBold)
            isItalic = traits.contains(.traitItalic)
            isHeading = font.pointSize >= Self.headingFontSize - 1 || (attrs[.paperclipHeading] as? Bool == true)
            isInlineCode = traits.contains(.traitMonoSpace) || (attrs[.paperclipInlineCode] as? Bool == true)
        } else {
            isBold = false
            isItalic = false
            isHeading = false
            isInlineCode = false
        }
        let strike = (attrs[.strikethroughStyle] as? Int) ?? 0
        isStrikethrough = strike != 0
    }

    func syncTypingAttributes(on tv: UITextView) {
        var attrs = tv.typingAttributes
        let size = isHeading ? Self.headingFontSize : Self.baseFontSize
        attrs[.font] = Self.makeFont(bold: isBold || isHeading, italic: isItalic, size: size, mono: isInlineCode)
        attrs[.foregroundColor] = UIColor.label
        if isStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        } else {
            attrs.removeValue(forKey: .strikethroughStyle)
        }
        if isInlineCode {
            attrs[.paperclipInlineCode] = true
            attrs[.backgroundColor] = UIColor.secondarySystemFill
        } else {
            attrs.removeValue(forKey: .paperclipInlineCode)
            attrs.removeValue(forKey: .backgroundColor)
        }
        if isHeading {
            attrs[.paperclipHeading] = true
        } else {
            attrs.removeValue(forKey: .paperclipHeading)
        }
        tv.typingAttributes = attrs
    }

    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: Self.makeFont(bold: false, italic: false, size: Self.baseFontSize, mono: false),
            .foregroundColor: UIColor.label
        ]
    }

    // MARK: - Font Factory

    static func makeFont(bold: Bool, italic: Bool, size: CGFloat, mono: Bool) -> UIFont {
        let base = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if mono { traits.insert(.traitMonoSpace) }
        if let desc = base.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: desc, size: size)
        }
        return base
    }

    // MARK: - Parse Markdown -> Visual NSAttributedString

    static func parseMarkdownToAttributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        for (lineIdx, rawLine) in lines.enumerated() {
            var line = rawLine
            var isHeadingLine = false
            var linePrefix = ""

            if line.hasPrefix("# ") {
                line = String(line.dropFirst(2))
                isHeadingLine = true
            } else if line.hasPrefix("## ") {
                line = String(line.dropFirst(3))
                isHeadingLine = true
            } else if line.hasPrefix("### ") {
                line = String(line.dropFirst(4))
                isHeadingLine = true
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2))
                linePrefix = bulletPrefix
            } else if line.hasPrefix("> ") {
                line = String(line.dropFirst(2))
                linePrefix = quotePrefix
            }

            let lineAttr = parseInlineMarkdown(linePrefix + line, isHeading: isHeadingLine)
            result.append(lineAttr)

            if lineIdx < lines.count - 1 {
                let newlineAttr = NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: makeFont(bold: false, italic: false, size: baseFontSize, mono: false),
                        .foregroundColor: UIColor.label
                    ]
                )
                result.append(newlineAttr)
            }
        }
        return result
    }

    private static func parseInlineMarkdown(_ text: String, isHeading: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let chars = Array(text)
        var i = 0
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            let size = isHeading ? headingFontSize : baseFontSize
            var attrs: [NSAttributedString.Key: Any] = [
                .font: makeFont(bold: bold || isHeading, italic: italic, size: size, mono: code),
                .foregroundColor: UIColor.label
            ]
            if strike {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if code {
                attrs[.paperclipInlineCode] = true
                attrs[.backgroundColor] = UIColor.secondarySystemFill
            }
            if isHeading {
                attrs[.paperclipHeading] = true
            }
            out.append(NSAttributedString(string: buffer, attributes: attrs))
            buffer = ""
        }

        while i < chars.count {
            if i + 1 < chars.count && chars[i] == "*" && chars[i + 1] == "*" {
                flush()
                bold.toggle()
                i += 2
            } else if i + 1 < chars.count && chars[i] == "~" && chars[i + 1] == "~" {
                flush()
                strike.toggle()
                i += 2
            } else if chars[i] == "`" {
                flush()
                code.toggle()
                i += 1
            } else if chars[i] == "*" {
                flush()
                italic.toggle()
                i += 1
            } else {
                buffer.append(chars[i])
                i += 1
            }
        }
        flush()

        if out.length == 0 && isHeading {
            return NSAttributedString(
                string: "",
                attributes: [
                    .font: makeFont(bold: true, italic: false, size: headingFontSize, mono: false),
                    .foregroundColor: UIColor.label,
                    .paperclipHeading: true
                ]
            )
        }
        return out
    }

    // MARK: - Serialize Visual NSAttributedString -> Paperclip Markdown

    static func serializeToMarkdown(_ attributed: NSAttributedString) -> String {
        let fullString = attributed.string as NSString
        guard fullString.length > 0 else { return "" }

        var outLines: [String] = []
        var location = 0

        while location <= fullString.length {
            let lineRange = fullString.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            // Strip trailing \n or \r\n from the line slice
            while contentRange.length > 0 {
                let lastChar = fullString.character(at: contentRange.location + contentRange.length - 1)
                if lastChar == 10 || lastChar == 13 {
                    contentRange.length -= 1
                } else {
                    break
                }
            }

            outLines.append(serializeLine(attributed, range: contentRange))

            if lineRange.length == 0 || lineRange.location + lineRange.length >= fullString.length {
                if lineRange.length > 0 && fullString.character(at: fullString.length - 1) == 10 {
                    outLines.append("")
                }
                break
            }
            location = lineRange.location + lineRange.length
        }

        return outLines.joined(separator: "\n")
    }

    private static func serializeLine(_ attributed: NSAttributedString, range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let nsStr = attributed.string as NSString
        let rawLine = nsStr.substring(with: range)

        var markdownLinePrefix = ""
        var innerRange = range

        if rawLine.hasPrefix(bulletPrefix) {
            markdownLinePrefix = "- "
            let pLen = (bulletPrefix as NSString).length
            innerRange = NSRange(location: range.location + pLen, length: range.length - pLen)
        } else if rawLine.hasPrefix(quotePrefix) {
            markdownLinePrefix = "> "
            let pLen = (quotePrefix as NSString).length
            innerRange = NSRange(location: range.location + pLen, length: range.length - pLen)
        } else {
            let firstAttrs = attributed.attributes(at: range.location, effectiveRange: nil)
            let font = firstAttrs[.font] as? UIFont
            let isH1 = (firstAttrs[.paperclipHeading] as? Bool == true) || ((font?.pointSize ?? baseFontSize) >= headingFontSize - 1)
            if isH1 {
                markdownLinePrefix = "# "
            }
        }

        guard innerRange.length > 0 else { return markdownLinePrefix }

        var lineResult = markdownLinePrefix
        attributed.enumerateAttributes(in: innerRange, options: []) { attrs, subrange, _ in
            let segment = nsStr.substring(with: subrange)
            guard !segment.isEmpty else { return }

            let font = attrs[.font] as? UIFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isH1 = markdownLinePrefix == "# "
            let isBold = traits.contains(.traitBold) && !isH1
            let isItalic = traits.contains(.traitItalic)
            let isStrike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            let isCode = traits.contains(.traitMonoSpace) || (attrs[.paperclipInlineCode] as? Bool == true)

            var prefixMarkers = ""
            var suffixMarkers = ""
            if isCode {
                prefixMarkers += "`"
                suffixMarkers = "`" + suffixMarkers
            }
            if isBold {
                prefixMarkers += "**"
                suffixMarkers = "**" + suffixMarkers
            }
            if isItalic {
                prefixMarkers += "*"
                suffixMarkers = "*" + suffixMarkers
            }
            if isStrike {
                prefixMarkers += "~~"
                suffixMarkers = "~~" + suffixMarkers
            }

            lineResult += prefixMarkers + segment + suffixMarkers
        }

        return lineResult
    }
}

// MARK: - Fixed Top Formatting Bar

struct RichTextFormattingBar: View {
    @ObservedObject var controller: RichTextFormattingController
    @Environment(\.paperclipPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    formatButton(
                        icon: "bold",
                        label: "Grassetto",
                        isActive: controller.isBold,
                        action: { controller.toggleBold() }
                    )

                    formatButton(
                        icon: "italic",
                        label: "Corsivo",
                        isActive: controller.isItalic,
                        action: { controller.toggleItalic() }
                    )

                    formatButton(
                        icon: "strikethrough",
                        label: "Barrato",
                        isActive: controller.isStrikethrough,
                        action: { controller.toggleStrikethrough() }
                    )

                    Divider()
                        .frame(height: 22)
                        .padding(.horizontal, 2)

                    formatButton(
                        icon: "textformat.size.larger",
                        label: "Titolo",
                        isActive: controller.isHeading,
                        action: { controller.toggleHeading() }
                    )

                    formatButton(
                        icon: "list.bullet",
                        label: "Elenco puntato",
                        isActive: controller.isBulletList,
                        action: { controller.toggleBulletList() }
                    )

                    formatButton(
                        icon: "text.quote",
                        label: "Citazione",
                        isActive: controller.isQuote,
                        action: { controller.toggleQuote() }
                    )

                    formatButton(
                        icon: "chevron.left.forwardslash.chevron.right",
                        label: "Codice",
                        isActive: controller.isInlineCode,
                        action: { controller.toggleInlineCode() }
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if controller.isEditorFocused {
                Button {
                    controller.dismissKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .frame(width: 36, height: 36)
                        .background(palette.surfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .accessibilityLabel("Chiudi tastiera")
            }
        }
        .background(palette.surfaceContainer)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func formatButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? palette.onPrimaryContainer : palette.onSurface)
                .frame(width: 38, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? palette.primaryContainer : palette.surfaceVariant.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isActive ? palette.primary : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - VisualRichTextEditor (UIViewRepresentable)

struct VisualRichTextEditor: UIViewRepresentable {
    @Binding var markdownText: String
    @ObservedObject var controller: RichTextFormattingController
    var placeholder: String = "Scrivi una nota…"

    func makeCoordinator() -> Coordinator {
        Coordinator(markdownText: $markdownText, controller: controller)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.isScrollEnabled = true
        tv.alwaysBounceVertical = false
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 4, bottom: 10, right: 4)
        tv.font = RichTextFormattingController.makeFont(bold: false, italic: false, size: RichTextFormattingController.baseFontSize, mono: false)
        tv.textColor = .label
        tv.attributedText = RichTextFormattingController.parseMarkdownToAttributed(markdownText)
        controller.textView = tv
        controller.onMarkdownChanged = { newMd in
            context.coordinator.updateBinding(newMd)
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        controller.textView = uiView
        if !context.coordinator.isEditing && RichTextFormattingController.serializeToMarkdown(uiView.attributedText) != markdownText {
            let sel = uiView.selectedRange
            uiView.attributedText = RichTextFormattingController.parseMarkdownToAttributed(markdownText)
            if sel.location <= uiView.attributedText.length {
                uiView.selectedRange = sel
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var markdownText: String
        let controller: RichTextFormattingController
        var isEditing: Bool = false

        init(markdownText: Binding<String>, controller: RichTextFormattingController) {
            _markdownText = markdownText
            self.controller = controller
        }

        func updateBinding(_ newMarkdown: String) {
            isEditing = true
            markdownText = newMarkdown
            isEditing = false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            Task { @MainActor in
                controller.isEditorFocused = true
                controller.refreshToolbarState(from: textView)
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            Task { @MainActor in
                controller.isEditorFocused = false
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            Task { @MainActor in
                controller.refreshToolbarState(from: textView)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            isEditing = true
            markdownText = RichTextFormattingController.serializeToMarkdown(textView.attributedText)
            isEditing = false
            Task { @MainActor in
                controller.refreshToolbarState(from: textView)
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Auto-continue or exit bullet list when pressing Return
            guard text == "\n" else { return true }
            let nsStr = textView.attributedText.string as NSString
            let paraRange = nsStr.paragraphRange(for: range)
            let paraText = nsStr.substring(with: paraRange).trimmingCharacters(in: .newlines)

            let bullet = RichTextFormattingController.bulletPrefix
            if paraText == bullet.trimmingCharacters(in: .whitespaces) || paraText == bullet {
                // Empty bullet line -> remove bullet prefix on Return
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                mutable.replaceCharacters(in: paraRange, with: "\n")
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: paraRange.location + 1, length: 0)
                textViewDidChange(textView)
                return false
            } else if paraText.hasPrefix(bullet) {
                // Continue bullet on next line
                let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                let insertStr = "\n" + bullet
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: RichTextFormattingController.makeFont(bold: false, italic: false, size: RichTextFormattingController.baseFontSize, mono: false),
                    .foregroundColor: UIColor.label
                ]
                mutable.replaceCharacters(in: range, with: NSAttributedString(string: insertStr, attributes: attrs))
                textView.attributedText = mutable
                textView.selectedRange = NSRange(location: range.location + (insertStr as NSString).length, length: 0)
                textViewDidChange(textView)
                return false
            } else if paraRange.length > 0 {
                let firstAttrs = textView.attributedText.attributes(at: paraRange.location, effectiveRange: nil)
                let font = firstAttrs[.font] as? UIFont
                let isH1 = (firstAttrs[.paperclipHeading] as? Bool == true) || ((font?.pointSize ?? RichTextFormattingController.baseFontSize) >= RichTextFormattingController.headingFontSize - 1)
                if isH1 {
                    let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
                    let normalAttrs: [NSAttributedString.Key: Any] = [
                        .font: RichTextFormattingController.makeFont(bold: false, italic: false, size: RichTextFormattingController.baseFontSize, mono: false),
                        .foregroundColor: UIColor.label
                    ]
                    mutable.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: normalAttrs))
                    textView.attributedText = mutable
                    textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                    textView.typingAttributes = normalAttrs
                    textViewDidChange(textView)
                    return false
                }
            }
            return true
        }
    }
}
