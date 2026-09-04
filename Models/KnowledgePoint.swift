//
//  KnowledgePoint.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/9/5.
//

import Foundation

/// 知识点模型：从笔记中提取的关键字及其详解
struct KnowledgePoint: Identifiable, Codable, Hashable {
    let id: UUID
    let noteId: UUID              // 所属笔记 ID
    let keyword: String           // 知识点关键字（原文中的一段文字）
    var explanation: String?      // 详解内容（缓存，为空表示未生成）
    var createdAt: Date
    
    init(id: UUID = UUID(),
         noteId: UUID,
         keyword: String,
         explanation: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.noteId = noteId
        self.keyword = keyword
        self.explanation = explanation
        self.createdAt = createdAt
    }
}

/// 笔记的知识点提取结果（用于缓存）
struct KnowledgeExtractionResult: Codable {
    let noteId: UUID
    var points: [KnowledgePoint]
    var extractedAt: Date
    
    init(noteId: UUID, points: [KnowledgePoint] = [], extractedAt: Date = Date()) {
        self.noteId = noteId
        self.points = points
        self.extractedAt = extractedAt
    }
}
