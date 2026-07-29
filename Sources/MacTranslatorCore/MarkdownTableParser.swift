import Foundation

public enum MarkdownTableAlignment: Equatable, Sendable {
    case left
    case center
    case right
}

public struct MarkdownTable: Equatable, Sendable {
    public let headers: [String]
    public let alignments: [MarkdownTableAlignment]
    public let rows: [[String]]

    public init(
        headers: [String],
        alignments: [MarkdownTableAlignment],
        rows: [[String]]
    ) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
    }
}

/// Parses GitHub-style Markdown tables without treating escaped pipes or pipes
/// inside inline-code spans as column separators.
public enum MarkdownTableParser {
    public static func parse(
        lines: [String],
        startingAt startIndex: Int
    ) -> (table: MarkdownTable, consumedLineCount: Int)? {
        guard startIndex >= 0, startIndex + 1 < lines.count,
              let header = splitRow(lines[startIndex]),
              let delimiter = splitRow(lines[startIndex + 1]),
              header.hasStructuralPipe || delimiter.hasStructuralPipe,
              !header.cells.isEmpty,
              header.cells.count == delimiter.cells.count
        else {
            return nil
        }

        let alignments = delimiter.cells.compactMap(delimiterAlignment)
        guard alignments.count == header.cells.count else { return nil }

        var rows: [[String]] = []
        var index = startIndex + 2
        while index < lines.count {
            let line = lines[index]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let parsedRow = splitRow(line),
                  parsedRow.hasStructuralPipe
            else {
                break
            }

            var cells = parsedRow.cells
            if cells.count < header.cells.count {
                cells.append(contentsOf: repeatElement("", count: header.cells.count - cells.count))
            } else if cells.count > header.cells.count {
                cells.removeLast(cells.count - header.cells.count)
            }
            rows.append(cells)
            index += 1
        }

        return (
            MarkdownTable(
                headers: header.cells,
                alignments: alignments,
                rows: rows
            ),
            index - startIndex
        )
    }

    private static func delimiterAlignment(_ cell: String) -> MarkdownTableAlignment? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let leftAligned = trimmed.hasPrefix(":")
        let rightAligned = trimmed.hasSuffix(":")
        let hyphens = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))

        guard hyphens.count >= 3, hyphens.allSatisfy({ $0 == "-" }) else {
            return nil
        }

        if leftAligned, rightAligned { return .center }
        if rightAligned { return .right }
        return .left
    }

    private static func splitRow(_ line: String) -> (cells: [String], hasStructuralPipe: Bool)? {
        let source = line.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return nil }

        var cells = [""]
        var structuralPipeCount = 0
        var activeBacktickCount = 0
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if character == "\\" {
                cells[cells.count - 1].append(character)
                index = source.index(after: index)
                if index < source.endIndex {
                    cells[cells.count - 1].append(source[index])
                    index = source.index(after: index)
                }
                continue
            }

            if character == "`" {
                let runStart = index
                var runEnd = index
                var runLength = 0
                while runEnd < source.endIndex, source[runEnd] == "`" {
                    runLength += 1
                    runEnd = source.index(after: runEnd)
                }

                cells[cells.count - 1].append(contentsOf: source[runStart..<runEnd])
                if activeBacktickCount == 0 {
                    activeBacktickCount = runLength
                } else if activeBacktickCount == runLength {
                    activeBacktickCount = 0
                }
                index = runEnd
                continue
            }

            if character == "|", activeBacktickCount == 0 {
                structuralPipeCount += 1
                cells.append("")
            } else {
                cells[cells.count - 1].append(character)
            }
            index = source.index(after: index)
        }

        if source.first == "|", cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if source.last == "|", cells.last?.isEmpty == true {
            cells.removeLast()
        }

        return (
            cells.map { $0.trimmingCharacters(in: .whitespaces) },
            structuralPipeCount > 0
        )
    }
}
