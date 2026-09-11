//
//  KnowledgePoint.swift
//  AnkiNotes
//
//  知识点模型：notePath 替代 noteId，路径即身份
//

import Foundation

/// 知识点模型：从笔记中提取的关键字及其详解
struct KnowledgePoint: Identifiable, Codable, Hashable {
    let id: UUID
    let notePath: String        // 所属笔记路径（folderPath/title）
    let keyword: String         // 知识点关键字
    var explanation: String?    // 详解内容（缓存，为空表示未生成）
    var createdAt: Date

    init(id: UUID = UUID(),
         notePath: String,
         keyword: String,
         explanation: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.notePath = notePath
        self.keyword = keyword
        self.explanation = explanation
        self.createdAt = createdAt
    }
}

/// 笔记的知识点提取结果（用于缓存）
struct KnowledgeExtractionResult: Codable {
    let notePath: String
    let noteTitle: String
    var points: [KnowledgePoint]
    var extractedAt: Date

    init(notePath: String, noteTitle: String, points: [KnowledgePoint] = [], extractedAt: Date = Date()) {
        self.notePath = notePath
        self.noteTitle = noteTitle
        self.points = points
        self.extractedAt = extractedAt
    }
}
