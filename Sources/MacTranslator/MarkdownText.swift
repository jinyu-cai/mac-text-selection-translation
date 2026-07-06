import SwiftUI

/// Renders AI output as Markdown while preserving the original string for copy
/// and speech actions elsewhere.
struct MarkdownText: View {
    let markdown: String
    var placeholder: String?

    private var displayText: String {
        if markdown.isEmpty, let placeholder {
            return placeholder
        }
        return markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownBlock.parse(displayText).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdownText(markdown: text)

        case .heading(let level, let text):
            InlineMarkdownText(markdown: text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 3 : 1)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.marker)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        InlineMarkdownText(markdown: item.text)
                    }
                    .padding(.leading, CGFloat(item.indentLevel) * 16)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                    .clipShape(Capsule())
                InlineMarkdownText(markdown: text)
                    .foregroundStyle(.secondary)
            }

        case .code(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .title3.weight(.semibold)
        case 2:
            return .headline.weight(.semibold)
        case 3:
            return .subheadline.weight(.semibold)
        default:
            return .body.weight(.semibold)
        }
    }
}

private struct InlineMarkdownText: View {
    let markdown: String

    private var renderedText: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    var body: some View {
        Text(renderedText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list([MarkdownListItem])
    case quote(String)
    case code(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var listItems: [MarkdownListItem] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(listItems))
            listItems.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                index += 1
                continue
            }

            if let fence = codeFenceStart(line) {
                flushParagraph()
                flushList()
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if isCodeFenceEnd(lines[index], marker: fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(line) {
                flushParagraph()
                flushList()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                flushList()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let quoteLine = blockquoteLine(line) {
                flushParagraph()
                flushList()
                var quoteLines = [quoteLine]
                index += 1
                while index < lines.count, let next = blockquoteLine(lines[index]) {
                    quoteLines.append(next)
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                listItems.append(item)
                index += 1
                continue
            }

            if !listItems.isEmpty, leadingWhitespaceCount(line) > 0 {
                var previous = listItems.removeLast()
                previous.text += "\n" + trimmed
                listItems.append(previous)
                index += 1
                continue
            }

            flushList()
            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        flushList()

        return blocks.isEmpty ? [.paragraph(markdown)] : blocks
    }

    private static func codeFenceStart(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isCodeFenceEnd(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return nil }

        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }

        let rest = trimmed.dropFirst(hashes)
        guard rest.first?.isWhitespace == true else { return nil }

        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        return (first == "-" || first == "*" || first == "_") && compact.allSatisfy { $0 == first }
    }

    private static func blockquoteLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        return trimmed.dropFirst().trimmingCharacters(in: .whitespaces).description
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = leadingWhitespaceCount(line) / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" {
            let rest = trimmed.dropFirst()
            guard rest.first?.isWhitespace == true else { return nil }
            return MarkdownListItem(
                marker: "\u{2022}",
                text: rest.trimmingCharacters(in: .whitespaces),
                indentLevel: indent
            )
        }

        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first?.isWhitespace == true else { return nil }
        return MarkdownListItem(
            marker: "\(digits).",
            text: rest.trimmingCharacters(in: .whitespaces),
            indentLevel: indent
        )
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }
        return count
    }
}

private struct MarkdownListItem {
    var marker: String
    var text: String
    var indentLevel: Int
}
