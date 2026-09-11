//
//  Folder.swift
//  AnkiNotes
//
//  文件夹模型：路径即身份，从目录结构推导，无 UUID
//

import Foundation

/// 文件夹模型，用于组织笔记
/// 路径即身份：path 是唯一标识，从 Notes/ 下的目录结构自动推导
struct Folder: Identifiable, Hashable {
    /// 唯一标识：path（路径即身份）
    var id: String { path }

    var name: String              // 文件夹名称（目录名）
    var path: String              // 相对 Notes/ 的路径，如 "JAVA高级/01-Java核心"
    var parentPath: String?       // 父文件夹路径，nil = 顶层

    init(name: String, path: String, parentPath: String? = nil) {
        self.name = name
        self.path = path
        self.parentPath = parentPath
    }
}
