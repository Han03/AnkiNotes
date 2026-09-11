//
//  ReviewLog.swift
//  AnkiNotes
//
//  复习历史记录：嵌入 .meta sidecar，无需 noteId（天然属于该笔记）
//

import Foundation

/// 复习历史记录（存储在 NoteMetaFile.reviewLogs 中）
struct ReviewLog: Codable, Hashable {
    var rating: ReviewRating
    var oldInterval: Int      // 复习前间隔（天）
    var newInterval: Int      // 复习后间隔（天）
    var oldEase: Double       // 复习前EF
    var newEase: Double       // 复习后EF
    var reviewDate: Date
    var timeSpent: TimeInterval  // 本次复习耗时

    init(rating: ReviewRating,
         oldInterval: Int,
         newInterval: Int,
         oldEase: Double,
         newEase: Double,
         reviewDate: Date = Date(),
         timeSpent: TimeInterval = 0) {
        self.rating = rating
        self.oldInterval = oldInterval
        self.newInterval = newInterval
        self.oldEase = oldEase
        self.newEase = newEase
        self.reviewDate = reviewDate
        self.timeSpent = timeSpent
    }
}

/// 统计汇总数据
struct StatsSummary: Codable, Hashable {
    var totalNotes: Int = 0
    var dueToday: Int = 0
    var newToday: Int = 0
    var reviewedToday: Int = 0
    var masteredCount: Int = 0       // EF >= 2.5 & interval >= 21 的
    var learningCount: Int = 0       // 学习中的数量
    var newCount: Int = 0            // 新卡片数量

    // 过去7天复习数量
    var weeklyReviewCounts: [Int] = Array(repeating: 0, count: 7)

    // 累计数据
    var totalReviews: Int = 0
    var streakDays: Int = 0
}
