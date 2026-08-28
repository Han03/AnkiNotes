//
//  Folder.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 文件夹模型，用于组织笔记
struct Folder: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var parentId: UUID?   // 父文件夹ID，nil表示根目录
    var createdAt: Date
    var updatedAt: Date
    
    init(id: UUID = UUID(),
         name: String,
         parentId: UUID? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
