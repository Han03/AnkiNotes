//
//  SRSData.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// Anki SM-2 算法所需的间隔重复数据
struct SRSData: Codable, Hashable {
    /// 间隔（天）
    var interval: Int = 0
    /// 容易度因子 EF，默认 2.5
    var easeFactor: Double = 2.5
    /// 复习次数
    var repetitions: Int = 0
    /// 下次复习时间
    var dueDate: Date = Date()
    /// 最后复习时间
    var lastReviewDate: Date? = nil
    /// 卡片状态：新卡片、学习中、已复习
    var cardState: CardState = .new
    
    enum CardState: String, Codable, Hashable {
        case new          // 新卡片，从未复习过
        case learning     // 学习中，正在短间隔复习
        case review       // 已复习，正常间隔复习
        case relearning   // 重新学习，遗忘后进入
    }
}

/// 用户对复习的评级
enum ReviewRating: Int, Codable, CaseIterable, Identifiable {
    case again   = 1  // 完全忘记，需重学
    case hard    = 2  // 很困难
    case good    = 3  // 刚好记得
    case easy    = 4  // 非常容易
    
    var id: Int { rawValue }
    
    var description: String {
        switch self {
        case .again: return "重来"
        case .hard:  return "困难"
        case .good:  return "良好"
        case .easy:  return "简单"
        }
    }
    
    var color: String {
        switch self {
        case .again: return "FF3B30"  // 红
        case .hard:  return "FF9500"  // 橙
        case .good:  return "34C759"  // 绿
        case .easy:  return "007AFF"  // 蓝
        }
    }
    
    var shortLabel: String {
        switch self {
        case .again: return "Again"
        case .hard:  return "Hard"
        case .good:  return "Good"
        case .easy:  return "Easy"
        }
    }
}
