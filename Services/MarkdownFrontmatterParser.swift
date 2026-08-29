//
//  MarkdownFrontmatterParser.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//
//  Markdown 文件 YAML Frontmatter 轻量解析器（不引入外部 YAML 库）
//  支持 Obsidian / Logseq / Jekyll 等常用 Frontmatter 格式：
//  ---
//  title: 笔记标题
//  tags: [高数, 极限]   或  tags: "高数, 极限"  或
//  tags:
//    - 高数
//    - 极限
//  date: 2024-01-01
//  ---

import Foundation

struct FrontmatterParseResult {
    let title: String?
    let tags: [String]
    let createdAt: Date?
    let body: String           // 去掉 Frontmatter 后的正文内容
}

enum MarkdownFrontmatterParser {
    
    /// 解析一个 Markdown 字符串，返回 Frontmatter 解析结果 + 正文
    /// 构建带 frontmatter 的 Markdown 内容
    static func build(title: String, tags: [String], body: String) -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(title)")
        if !tags.isEmpty {
            let tagsStr = tags.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("tags: [\(tagsStr)]")
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        lines.append("date: \(dateFormatter.string(from: Date()))")
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
    
    static func parse(_ content: String) -> FrontmatterParseResult {
        let trimmed = content
        guard trimmed.hasPrefix("---\n") || trimmed.hasPrefix("---\r\n") else {
            return FrontmatterParseResult(title: nil, tags: [], createdAt: nil, body: content)
        }
        
        // 按行拆分
        let newline: Character = "\n"
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else {
            return FrontmatterParseResult(title: nil, tags: [], createdAt: nil, body: content)
        }
        
        // 找第二个 --- 结束线
        var endIdx: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIdx = i
                break
            }
        }
        guard let end = endIdx else {
            return FrontmatterParseResult(title: nil, tags: [], createdAt: nil, body: content)
        }
        
        let yamlLines = Array(lines[1..<end])
        let bodyLines = end + 1 < lines.count ? Array(lines[(end + 1)...]) : []
        let body = bodyLines.joined(separator: "\n")
        
        // 简单解析 key: value / 列表块
        var title: String?
        var tags: [String] = []
        var createdAt: Date?
        
        var i = 0
        while i < yamlLines.count {
            let line = yamlLines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { i += 1; continue }
            
            // 列表式 tag 不在这里处理（由 tags: 键进入后往下扫）
            if trimmedLine.starts(with: "- ") { i += 1; continue }
            
            // 匹配 "key: value"
            if let colonRange = trimmedLine.range(of: ":") {
                let key = String(trimmedLine[trimmedLine.startIndex..<colonRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let rawValue = String(trimmedLine[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                
                switch key {
                case "title":
                    title = stripQuotes(rawValue)
                    
                case "tags", "tag", "categories", "category":
                    let parsed = parseTagsInline(rawValue)
                    if !parsed.0.isEmpty {
                        tags.append(contentsOf: parsed.0)
                    }
                    // 如果 inline 解析为空，可能下面是列表块
                    if rawValue.isEmpty || parsed.1 {
                        var j = i + 1
                        while j < yamlLines.count {
                            let next = yamlLines[j].trimmingCharacters(in: .whitespaces)
                            if next.starts(with: "- ") {
                                let t = String(next.dropFirst(2))
                                    .trimmingCharacters(in: .whitespaces)
                                if !t.isEmpty { tags.append(stripQuotes(t)) }
                                j += 1
                            } else if next.isEmpty {
                                j += 1
                            } else {
                                break
                            }
                        }
                        i = j - 1 // 跳到最后读的列表行
                    }
                    
                case "date", "created", "created-at", "createdat", "creation-date":
                    createdAt = parseDate(stripQuotes(rawValue))
                    
                default:
                    break
                }
            }
            
            i += 1
        }
        
        return FrontmatterParseResult(
            title: title,
            tags: Array(NSOrderedSet(array: tags)) as! [String], // 去重
            createdAt: createdAt,
            body: body
        )
    }
    
    // MARK: - 工具
    
    private static func stripQuotes(_ s: String) -> String {
        var r = s
        if r.count >= 2 {
            let first = r.first!, last = r.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                r = String(r.dropFirst().dropLast())
            }
        }
        return r.trimmingCharacters(in: .whitespaces)
    }
    
    /// 返回 (tags, isListSyntax/需要继续扫列表块)
    private static func parseTagsInline(_ s: String) -> ([String], Bool) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return ([], true) }
        // [a, b, c] 数组语法
        if t.first == "[" && t.last == "]" {
            let inner = String(t.dropFirst().dropLast())
            let parts = inner.split(separator: ",").map { stripQuotes(String($0)) }.filter { !$0.isEmpty }
            return (parts, false)
        }
        // 字符串逗号分隔："高数, 极限, 重点"
        if t.contains(",") {
            let parts = t.split(separator: ",").map { stripQuotes(String($0)) }.filter { !$0.isEmpty }
            return (parts, false)
        }
        // 单个 tag
        let one = stripQuotes(t)
        return (one.isEmpty ? [] : [one], t.hasPrefix("[") || t.isEmpty)
    }
    
    private static func parseDate(_ s: String) -> Date? {
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in fmts {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        // ISO8601 兜底
        if #available(iOS 16.0, *) {
            return ISO8601DateFormatter().date(from: s)
        } else {
            return nil
        }
    }
}
