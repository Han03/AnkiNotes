//
//  MarkdownRenderer.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 轻量级 Markdown 渲染器（纯原生，无第三方依赖）
/// 支持: # ## ### 标题, **粗体**, *斜体*, `行内代码`, ```代码块```, - 列表, > 引用, 链接, 图片占位
final class MarkdownRenderer {
    
    /// 解析表格行，返回单元格数组
    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // 移除首尾的 |
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        // 按 | 分割
        let cells = trimmed.components(separatedBy: "|").map { 
            $0.trimmingCharacters(in: .whitespaces)
        }
        return cells
    }
    
    /// 将 Markdown 字符串解析为一系列段落块
    static func parse(markdown: String) -> [MarkdownBlock] {
        let lines = markdown.split(whereSeparator: \.isNewline).map(String.init)
        var blocks: [MarkdownBlock] = []
        
        var i = 0
        while i < lines.count {
            let line = lines[i]
            
            // 空行
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.empty)
                i += 1
                continue
            }
            
            // 代码块 ```
            if line.trimmingCharacters(in: .whitespaces).starts(with: "```") {
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).starts(with: "```") {
                        i += 1
                        break
                    }
                    codeLines.append(l)
                    i += 1
                }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }
            
            // 标题
            if line.starts(with: "### ") {
                blocks.append(.heading(level: 3, text: String(line.dropFirst(4))))
                i += 1; continue
            }
            if line.starts(with: "## ") {
                blocks.append(.heading(level: 2, text: String(line.dropFirst(3))))
                i += 1; continue
            }
            if line.starts(with: "# ") {
                blocks.append(.heading(level: 1, text: String(line.dropFirst(2))))
                i += 1; continue
            }
            
            // 引用
            if line.starts(with: "> ") || line == ">" {
                var quoteLines: [String] = [String(line.drop(while: { $0 == ">" || $0 == " " }).dropFirst(0))]
                let text = line.starts(with: "> ") ? String(line.dropFirst(2)) : ""
                quoteLines = [text]
                i += 1
                while i < lines.count, (lines[i].starts(with: "> ") || lines[i] == ">") {
                    let t = lines[i].starts(with: "> ") ? String(lines[i].dropFirst(2)) : ""
                    quoteLines.append(t)
                    i += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }
            
            // 无序列表
            if line.starts(with: "- ") || line.starts(with: "* ") || line.starts(with: "+ ") {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.starts(with: "- ") || l.starts(with: "* ") || l.starts(with: "+ ") {
                        items.append(String(l.dropFirst(2)))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.unorderedList(items))
                continue
            }
            
            // 有序列表
            if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if let m = l.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        items.append(String(l[m.upperBound...]))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items))
                continue
            }
            
            // 表格（GFM 格式）
            if line.contains("|") && i + 1 < lines.count {
                let nextLine = lines[i + 1]
                // 检查第二行是否是分隔行（|---|---|）
                let separatorPattern = #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?$"#
                if nextLine.range(of: separatorPattern, options: .regularExpression) != nil {
                    var tableLines: [String] = [line, nextLine]
                    var j = i + 2
                    while j < lines.count && lines[j].contains("|") && !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                        tableLines.append(lines[j])
                        j += 1
                    }
                    // 解析表格
                    let headers = parseTableRow(tableLines[0])
                    var rows: [[String]] = []
                    for rowLine in tableLines.dropFirst(2) {
                        rows.append(parseTableRow(rowLine))
                    }
                    blocks.append(.table(headers: headers, rows: rows))
                    i = j
                    continue
                }
            }
            
            // 任务列表
            if (line.starts(with: "- [") || line.starts(with: "* [")) && line.count > 4 {
                var items: [TaskItem] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.starts(with: "- [") || l.starts(with: "* [") {
                        let checked = l.prefix(5).contains("x") || l.prefix(5).contains("X")
                        let text = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        items.append(TaskItem(text: text, checked: checked))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.taskList(items: items))
                continue
            }
            
            // 水平分割线
            if line == "---" || line == "***" || line == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }
            
            // 普通段落（合并连续非空行为一段）
            var paraLines: [String] = [line]
            i += 1
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.starts(with: "#") || l.starts(with: ">") || l.starts(with: "```") ||
                    l.starts(with: "- ") || l.starts(with: "* ") ||
                    (l.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil) ||
                    l == "---" || l == "***" { break }
                paraLines.append(l)
                i += 1
            }
            blocks.append(.paragraph(paraLines.joined(separator: " ")))
        }
        
        return blocks
    }
}

/// 任务列表项
struct TaskItem: Hashable, Identifiable {
    let id = UUID()
    var text: String
    var checked: Bool
}

/// Markdown 段落块类型
enum MarkdownBlock: Hashable, Identifiable {
    case empty
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case unorderedList([String])
    case orderedList([String])
    case codeBlock(String)
    case divider
    case table(headers: [String], rows: [[String]])
    case taskList(items: [TaskItem])
    
    var id: Int { hashValue }
}

// MARK: - SwiftUI View 渲染

struct MarkdownView: View {
    let markdown: String
    var bodyFont: Font = .body
    var textColor: Color = .primary
    var knowledgePoints: [KnowledgePoint] = []  // 知识点列表（用于标记原文）
    var onKnowledgeTap: ((KnowledgePoint) -> Void)? = nil  // 点击知识点回调
    
    var body: some View {
        let blocks = MarkdownRenderer.parse(markdown: markdown)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                BlockView(
                    block: block,
                    bodyFont: bodyFont,
                    textColor: textColor,
                    knowledgePoints: knowledgePoints,
                    onKnowledgeTap: onKnowledgeTap
                )
            }
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    var bodyFont: Font
    var textColor: Color
    var knowledgePoints: [KnowledgePoint] = []
    var onKnowledgeTap: ((KnowledgePoint) -> Void)? = nil
    
    var body: some View {
        switch block {
        case .empty:
            Color.clear.frame(height: 4)
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            KnowledgeInlineText(
                text: text,
                font: bodyFont,
                color: textColor,
                knowledgePoints: knowledgePoints,
                onKnowledgeTap: onKnowledgeTap
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 4)
                KnowledgeInlineText(
                    text: text,
                    font: .body.italic(),
                    color: .secondary,
                    knowledgePoints: knowledgePoints,
                    onKnowledgeTap: onKnowledgeTap
                )
            }
            .padding(.vertical, 4)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").bold()
                        KnowledgeInlineText(
                            text: item,
                            font: bodyFont,
                            color: textColor,
                            knowledgePoints: knowledgePoints,
                            onKnowledgeTap: onKnowledgeTap
                        )
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).").bold().frame(width: 24, alignment: .trailing)
                        KnowledgeInlineText(
                            text: item,
                            font: bodyFont,
                            color: textColor,
                            knowledgePoints: knowledgePoints,
                            onKnowledgeTap: onKnowledgeTap
                        )
                    }
                }
            }
        case .codeBlock(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
        case .divider:
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows):
            TableView(headers: headers, rows: rows, bodyFont: bodyFont, textColor: textColor)
        case .taskList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .foregroundColor(item.checked ? .green : .secondary)
                            .font(.callout)
                        InlineMarkdownText(text: item.text, font: bodyFont, color: item.checked ? .secondary : textColor)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            InlineMarkdownText(text: text, font: .largeTitle.bold(), color: textColor)
        case 2:
            InlineMarkdownText(text: text, font: .title.bold(), color: textColor)
        case 3:
            InlineMarkdownText(text: text, font: .title2.bold(), color: textColor)
        default:
            InlineMarkdownText(text: text, font: .title3.bold(), color: textColor)
        }
    }
}

// MARK: - 表格视图
private struct TableView: View {
    let headers: [String]
    let rows: [[String]]
    var bodyFont: Font
    var textColor: Color
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // 表头
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(bodyFont.bold())
                            .foregroundColor(textColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(minWidth: 80, alignment: .leading)
                            .background(Color.secondary.opacity(0.15))
                        if header != headers.last {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 1)
                        }
                    }
                }
                // 分隔线
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 1)
                // 数据行
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            InlineMarkdownText(text: cell, font: bodyFont, color: textColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(minWidth: 80, alignment: .leading)
                            if colIdx < row.count - 1 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 1)
                            }
                        }
                    }
                    .background(rowIdx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                    // 行底部分隔线
                    if rowIdx < rows.count - 1 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 0.5)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - 行内 Markdown 解析（粗体、斜体、行内代码、链接）

struct InlineMarkdownText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    
    var body: some View {
        let segments = parseInline(text)
        segments.reduce(Text("")) { partial, seg in
            let style: Font = {
                switch seg.style {
                case .normal: return font
                case .bold:   return font.bold()
                case .italic: return font.italic()
                case .boldItalic: return font.bold().italic()
                case .code:   return .system(.callout, design: .monospaced)
                }
            }()
            var t = Text(seg.content).font(style)
            switch seg.style {
            case .code:
                t = t.foregroundColor(.orange)
            case .normal, .bold, .italic, .boldItalic:
                t = t.foregroundColor(color)
            }
            if seg.linkURL != nil {
                return partial + t.underline().foregroundColor(.blue)
            }
            return partial + t
        }
    }
    
    private enum InlineStyle {
        case normal, bold, italic, boldItalic, code
    }
    private struct InlineSegment {
        let content: String
        let style: InlineStyle
        let linkURL: URL?
    }
    
    private func parseInline(_ input: String) -> [InlineSegment] {
        var result: [InlineSegment] = []
        var remaining = input[...]
        
        while !remaining.isEmpty {
            // 行内代码 `code`
            if let backtickRange = remaining.range(of: "`") {
                let before = remaining[..<backtickRange.lowerBound]
                if !before.isEmpty {
                    result.append(contentsOf: parseStyles(String(before)))
                }
                let afterBacktick = remaining[backtickRange.upperBound...]
                if let closeRange = afterBacktick.range(of: "`") {
                    let code = afterBacktick[..<closeRange.lowerBound]
                    result.append(InlineSegment(content: String(code), style: .code, linkURL: nil))
                    remaining = afterBacktick[closeRange.upperBound...]
                } else {
                    result.append(InlineSegment(content: "`", style: .normal, linkURL: nil))
                    remaining = afterBacktick
                }
                continue
            }
            
            result.append(contentsOf: parseStyles(String(remaining)))
            break
        }
        return result
    }
    
    private func parseStyles(_ input: String) -> [InlineSegment] {
        // 处理链接 [text](url)
        var segments: [InlineSegment] = []
        var str = input
        
        let linkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern) else {
            return [InlineSegment(content: str, style: .normal, linkURL: nil)]
        }
        let nsRange = NSRange(str.startIndex..., in: str)
        let matches = regex.matches(in: str, range: nsRange).reversed()
        
        for match in matches {
            guard let fullRange = Range(match.range, in: str),
                  let textRange = Range(match.range(at: 1), in: str),
                  let urlRange = Range(match.range(at: 2), in: str) else { continue }
            let after = str[fullRange.upperBound...]
            let linkText = String(str[textRange])
            let linkURL = URL(string: String(str[urlRange]))
            
            // 在链接之前处理粗体/斜体
            let before = String(str[..<fullRange.lowerBound])
            if !after.isEmpty {
                segments.insert(contentsOf: parseBoldItalic(String(after)), at: 0)
            }
            segments.insert(InlineSegment(content: linkText, style: .normal, linkURL: linkURL), at: 0)
            str = before
        }
        if !str.isEmpty {
            segments.insert(contentsOf: parseBoldItalic(str), at: 0)
        }
        return segments
    }
    
    private func parseBoldItalic(_ input: String) -> [InlineSegment] {
        // 简单 **bold** *italic* ***boldItalic*** 处理
        var segs: [InlineSegment] = []
        var text = input
        // ***...***
        while let r = text.range(of: #"(\*\*\*|___)(.*?)\1"#, options: .regularExpression) {
            let before = String(text[..<r.lowerBound])
            if !before.isEmpty { segs.append(InlineSegment(content: before, style: .normal, linkURL: nil)) }
            var inside = String(text[r])
            if inside.hasPrefix("***") { inside = String(inside.dropFirst(3).dropLast(3)) }
            else { inside = String(inside.dropFirst(3).dropLast(3)) }
            segs.append(InlineSegment(content: inside, style: .boldItalic, linkURL: nil))
            text = String(text[r.upperBound...])
        }
        // **...**
        while let r = text.range(of: #"(\*\*|__)(.*?)\1"#, options: .regularExpression) {
            let before = String(text[..<r.lowerBound])
            if !before.isEmpty { segs.append(InlineSegment(content: before, style: .normal, linkURL: nil)) }
            var inside = String(text[r])
            inside = String(inside.dropFirst(2).dropLast(2))
            segs.append(InlineSegment(content: inside, style: .bold, linkURL: nil))
            text = String(text[r.upperBound...])
        }
        // *...*
        while let r = text.range(of: #"(\*|_)(.*?)\1"#, options: .regularExpression) {
            let before = String(text[..<r.lowerBound])
            if !before.isEmpty { segs.append(InlineSegment(content: before, style: .normal, linkURL: nil)) }
            var inside = String(text[r])
            inside = String(inside.dropFirst(1).dropLast(1))
            segs.append(InlineSegment(content: inside, style: .italic, linkURL: nil))
            text = String(text[r.upperBound...])
        }
        if !text.isEmpty {
            segs.append(InlineSegment(content: text, style: .normal, linkURL: nil))
        }
        return segs
    }
}

// MARK: - 带知识点标记的行内文本渲染

/// 支持知识点标记的行内文本渲染器
/// 使用 AttributedString + 自定义 URL scheme 实现可点击的知识点虚线下划线
struct KnowledgeInlineText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var knowledgePoints: [KnowledgePoint] = []
    var onKnowledgeTap: ((KnowledgePoint) -> Void)? = nil
    
    var body: some View {
        let attributed = buildAttributedString()
        Text(attributed)
            .font(font)
            .foregroundColor(color)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "knowledge",
                   let pointId = UUID(uuidString: url.host ?? ""),
                   let point = knowledgePoints.first(where: { $0.id == pointId }) {
                    onKnowledgeTap?(point)
                    return .handled
                }
                return .systemAction
            })
    }
    
    private func buildAttributedString() -> AttributedString {
        var attr = AttributedString(text)
        
        // 应用基础样式
        attr.font = font
        attr.foregroundColor = color
        
        // 处理粗体 **text**
        applyMarkdownStyle(&attr, pattern: #"\*\*(.+?)\*\*"#, style: .bold)
        // 处理斜体 *text*
        applyMarkdownStyle(&attr, pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, style: .italic)
        // 处理行内代码 `code`
        applyInlineCode(&attr)
        
        // 标记知识点（虚线下划线 + 可点击链接）
        for point in knowledgePoints {
            markKnowledgePoint(&attr, point: point)
        }
        
        return attr
    }
    
    private enum MarkdownStyle {
        case bold, italic
    }
    
    private func applyMarkdownStyle(_ attr: inout AttributedString, pattern: String, style: MarkdownStyle) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange).reversed()
        
        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let contentRange = Range(match.range(at: 1), in: text) else { continue }
            
            let content = String(text[contentRange])
            if let attrContentRange = Range(fullRange, in: attr) {
                attr[attrContentRange].setAttributes(AttributeContainer())
                // 替换标记符号
                // 由于 AttributedString 不支持直接替换文本，这里只设置样式，保留标记符号
                // 简化处理：只对内容部分设置样式
                if let attrInnerRange = Range(contentRange, in: attr) {
                    switch style {
                    case .bold:
                        attr[attrInnerRange].inlinePresentationIntent = .stronglyEmphasized
                    case .italic:
                        attr[attrInnerRange].inlinePresentationIntent = .emphasized
                    }
                }
            }
        }
    }
    
    private func applyInlineCode(_ attr: inout AttributedString) {
        guard let regex = try? NSRegularExpression(pattern: "`([^`]+)`") else { return }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange).reversed()
        
        for match in matches {
            guard let contentRange = Range(match.range(at: 1), in: text),
                  let attrRange = Range(contentRange, in: attr) else { continue }
            attr[attrRange].font = .system(.callout, design: .monospaced)
            attr[attrRange].foregroundColor = .orange
        }
    }
    
    private func markKnowledgePoint(_ attr: inout AttributedString, point: KnowledgePoint) {
        let keyword = point.keyword
        guard !keyword.isEmpty else { return }
        
        // 在文本中查找关键字（不区分大小写）
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: keyword, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(range, in: attr) {
                // 设置虚线下划线
                attr[attrRange].underlineStyle = .patternDash
                attr[attrRange].underlineColor = .purple
                attr[attrRange].foregroundColor = .purple
                // 设置自定义 URL scheme，用于点击拦截
                attr[attrRange].link = URL(string: "knowledge://\(point.id.uuidString)")
            }
            searchRange = range.upperBound..<text.endIndex
        }
    }
}
