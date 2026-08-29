//
//  Note.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 笔记模型，以单个Markdown文件存储
struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String            // 标题（文件名）
    var folderId: UUID?          // 所属文件夹ID，nil表示根目录
    var markdownContent: String  // Markdown 原文内容
    var srs: SRSData             // Anki SRS 数据
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]           // 标签
    
    /// Markdown 中的卡片正面（问题），默认取第一个标题
    var cardFront: String {
        extractFront(from: markdownContent)
    }
    
    /// Markdown 中的卡片背面（答案），默认取第一个标题之后的内容
    var cardBack: String {
        extractBack(from: markdownContent)
    }
    
    init(id: UUID = UUID(),
         title: String,
         folderId: UUID? = nil,
         markdownContent: String = "",
         srs: SRSData = SRSData(),
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         tags: [String] = []) {
        self.id = id
        self.title = title
        self.folderId = folderId
        self.markdownContent = markdownContent
        self.srs = srs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
    }
    
    // MARK: - 卡片正反面提取逻辑
    
    /// 提取卡片正面：第一个 # 标题，若无标题则取第一行
    private func extractFront(from content: String) -> String {
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        
        // 找第一个 Markdown 标题
        if let titleLine = lines.first(where: { $0.starts(with: "# ") || $0.starts(with: "## ") || $0.starts(with: "### ") }) {
            return titleLine
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        
        // 否则取第一非空行
        if let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return firstLine.trimmingCharacters(in: .whitespaces)
        }
        
        return title
    }
    
    /// 提取卡片背面：第一个标题之后的所有内容
    private func extractBack(from content: String) -> String {
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        
        guard let titleIndex = lines.firstIndex(where: {
            $0.starts(with: "# ") || $0.starts(with: "## ") || $0.starts(with: "### ")
        }) else {
            // 若无标题，则从第二行开始作为背面
            guard lines.count > 1 else { return "" }
            return lines.dropFirst().joined(separator: "\n")
        }
        
        return lines.dropFirst(titleIndex + 1).joined(separator: "\n")
    }
}

// MARK: - NoteMeta（笔记索引元数据，与 Note 一对一保存在 .metadata/notes_index.json，便于快速枚举而不用读每个 Markdown 文件）

/// 笔记索引条目（避免每次启动全量解析 Markdown）
struct NoteMeta: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var folderId: UUID?
    /// 物理文件名（含 .md 后缀，可能带 UUID 前缀 & 非法字符占位）
    var fileName: String
    var srs: SRSData
    var createdAt: Date
    var updatedAt: Date
    var tags: [String]

    init(id: UUID, title: String, folderId: UUID?, fileName: String,
         srs: SRSData, createdAt: Date, updatedAt: Date, tags: [String]) {
        self.id = id
        self.title = title
        self.folderId = folderId
        self.fileName = fileName
        self.srs = srs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tags = tags
    }
}
