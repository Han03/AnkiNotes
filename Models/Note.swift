//
//  Note.swift
//  AnkiNotes
//
//  笔记模型：路径即身份，无 UUID
//  .md 文件存储纯内容，.meta sidecar 存储 tags/srs/dates/reviewLogs
//

import Foundation

/// 笔记模型，以单个 Markdown 文件存储内容，.meta sidecar 存储附属数据
struct Note: Identifiable, Hashable {
    /// 唯一标识：folderPath/title（路径即身份）
    var id: String { notePath }

    var title: String            // 标题（文件名，无 .md 后缀）
    var folderPath: String       // 所属文件夹路径（相对 Notes/），空字符串 = 根目录
    var markdownContent: String  // Markdown 原文内容（.md 文件）
    var tags: [String]           // 标签（.meta）
    var srs: SRSData             // Anki SRS 数据（.meta）
    var createdAt: Date          // 创建时间（.meta）
    var updatedAt: Date          // 更新时间（.meta）
    var reviewLogs: [ReviewLog]  // 复习历史记录（.meta）

    /// 笔记路径：folderPath/title
    var notePath: String {
        folderPath.isEmpty ? title : "\(folderPath)/\(title)"
    }

    /// 卡片正面（问题），默认取第一个标题
    var cardFront: String {
        extractFront(from: markdownContent)
    }

    /// 卡片背面（答案），默认取第一个标题之后的内容
    var cardBack: String {
        extractBack(from: markdownContent)
    }

    init(title: String,
         folderPath: String = "",
         markdownContent: String = "",
         tags: [String] = [],
         srs: SRSData = SRSData(),
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         reviewLogs: [ReviewLog] = []) {
        self.title = title
        self.folderPath = folderPath
        self.markdownContent = markdownContent
        self.tags = tags
        self.srs = srs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewLogs = reviewLogs
    }

    // MARK: - 卡片正反面提取逻辑

    /// 提取卡片正面：第一个 # 标题，若无标题则取第一行
    private func extractFront(from content: String) -> String {
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)

        if let titleLine = lines.first(where: {
            $0.starts(with: "# ") || $0.starts(with: "## ") || $0.starts(with: "### ")
        }) {
            return titleLine
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

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
            guard lines.count > 1 else { return "" }
            return lines.dropFirst().joined(separator: "\n")
        }

        return lines.dropFirst(titleIndex + 1).joined(separator: "\n")
    }
}

// MARK: - .meta sidecar 文件格式（JSON）

/// 笔记附属数据，存储在 {title}.meta 文件中
struct NoteMetaFile: Codable {
    var tags: [String]
    var srs: SRSData
    var createdAt: Date
    var updatedAt: Date
    var reviewLogs: [ReviewLog]

    init(tags: [String] = [],
         srs: SRSData = SRSData(),
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         reviewLogs: [ReviewLog] = []) {
        self.tags = tags
        self.srs = srs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewLogs = reviewLogs
    }
}
