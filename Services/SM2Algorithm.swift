//
//  SM2Algorithm.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// Anki SM-2 间隔重复算法实现
/// 参考: https://super-memory.com/english/ol/sm2.htm
/// 并融合 Anki 官方桌面端的常用调整
enum SM2Algorithm {
    
    // MARK: - 学习阶段的短间隔（分钟）
    private static let learningIntervalsMinutes: [Int] = [1, 10]   // 学习阶段 Again 回到 1min，Hard/Graduate
    private static let graduatingIntervalDays: Int = 1              // 学习阶段 Good => 1天
    private static let easyIntervalDays: Int = 4                    // 学习阶段 Easy => 4天
    
    // MARK: - 应用评级
    
    /// 根据当前 SRS 数据和用户评级，返回更新后的 SRS 数据与新间隔
    static func applyRating(current srs: SRSData, rating: ReviewRating) -> SRSData {
        var new = srs
        new.lastReviewDate = Date()
        
        switch srs.cardState {
        case .new, .learning:
            return applyLearningRating(current: &new, rating: rating)
        case .review:
            return applyReviewRating(current: &new, rating: rating)
        case .relearning:
            return applyRelearningRating(current: &new, rating: rating)
        }
    }
    
    // MARK: - 四个评级对应的下一次间隔（用于UI显示）
    
    static func nextIntervalPreview(current srs: SRSData, rating: ReviewRating) -> String {
        let nextSRS = applyRating(current: srs, rating: rating)
        return formatInterval(srs: nextSRS, rating: rating)
    }
    
    // MARK: - 学习阶段 (New / Learning)
    
    private static func applyLearningRating(current srs: inout SRSData, rating: ReviewRating) -> SRSData {
        switch rating {
        case .again:
            // Again: 回到学习第0步（1分钟）
            srs.repetitions = 0
            srs.cardState = .learning
            srs.dueDate = Date().addingTimeInterval(TimeInterval(learningIntervalsMinutes[0] * 60))
        case .hard:
            // Hard: 当前学习步骤延长，约中间值 5 分钟
            srs.cardState = .learning
            srs.dueDate = Date().addingTimeInterval(5 * 60)
        case .good:
            // Good: 毕业了，进入 review，间隔 1 天
            srs.repetitions = 1
            srs.interval = graduatingIntervalDays
            srs.cardState = .review
            srs.dueDate = Calendar.current.date(byAdding: .day, value: srs.interval, to: startOfDay())!
        case .easy:
            // Easy: 直接跳，间隔 4 天，EF +0.15
            srs.repetitions = 1
            srs.interval = easyIntervalDays
            srs.easeFactor = max(1.3, srs.easeFactor + 0.15)
            srs.cardState = .review
            srs.dueDate = Calendar.current.date(byAdding: .day, value: srs.interval, to: startOfDay())!
        }
        return srs
    }
    
    // MARK: - 复习阶段 (Review)
    
    private static func applyReviewRating(current srs: inout SRSData, rating: ReviewRating) -> SRSData {
        let currentEF = srs.easeFactor
        let currentInterval = srs.interval
        
        switch rating {
        case .again:
            // 遗忘，进入重新学习
            srs.repetitions = 0
            srs.interval = 0
            srs.cardState = .relearning
            srs.easeFactor = max(1.3, srs.easeFactor - 0.20)
            srs.dueDate = Date().addingTimeInterval(TimeInterval(learningIntervalsMinutes[0] * 60))
            
        case .hard:
            // 当前间隔 × 1.2，EF - 0.15
            let newInterval = max(1, Int(round(Double(currentInterval) * 1.2)))
            srs.interval = newInterval
            srs.easeFactor = max(1.3, srs.easeFactor - 0.15)
            srs.repetitions += 1
            srs.dueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: startOfDay())!
            
        case .good:
            // 标准 SM-2: I(n) = I(n-1) × EF
            let newInterval: Int
            if srs.repetitions == 0 {
                newInterval = 1
            } else if srs.repetitions == 1 {
                newInterval = max(currentInterval, 6)
            } else {
                newInterval = max(1, Int(round(Double(currentInterval) * currentEF)))
            }
            srs.interval = newInterval
            srs.repetitions += 1
            srs.dueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: startOfDay())!
            
        case .easy:
            // Easy Bonus: × EF × 1.3，EF + 0.15
            let multiplied = Double(currentInterval) * currentEF * 1.3
            let newInterval = max(1, Int(round(multiplied)))
            srs.interval = newInterval
            srs.easeFactor = srs.easeFactor + 0.15
            srs.repetitions += 1
            srs.dueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: startOfDay())!
        }
        return srs
    }
    
    // MARK: - 重新学习阶段 (Relearning)
    
    private static func applyRelearningRating(current srs: inout SRSData, rating: ReviewRating) -> SRSData {
        switch rating {
        case .again:
            // Again: 回到 1 分钟
            srs.cardState = .relearning
            srs.dueDate = Date().addingTimeInterval(TimeInterval(learningIntervalsMinutes[0] * 60))
        case .hard:
            srs.cardState = .relearning
            srs.dueDate = Date().addingTimeInterval(5 * 60)
        case .good:
            // 重新毕业：使用原间隔（至少1天）作为恢复起点
            let newInterval = max(1, srs.interval == 0 ? 1 : srs.interval)
            srs.interval = newInterval
            srs.repetitions = 1
            srs.cardState = .review
            srs.dueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: startOfDay())!
        case .easy:
            let newInterval = max(4, srs.interval == 0 ? 4 : Int(Double(srs.interval) * 1.5))
            srs.interval = newInterval
            srs.easeFactor = min(3.0, srs.easeFactor + 0.10)
            srs.repetitions = 1
            srs.cardState = .review
            srs.dueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: startOfDay())!
        }
        return srs
    }
    
    // MARK: - 工具
    
    private static func startOfDay() -> Date {
        Calendar.current.startOfDay(for: Date())
    }
    
    /// 格式化间隔显示
    static func formatInterval(srs: SRSData, rating: ReviewRating) -> String {
        let seconds = srs.dueDate.timeIntervalSinceNow
        if seconds <= 0 { return "即将" }
        let minutes = Int(round(seconds / 60))
        if minutes < 60 { return "< \(max(1, minutes)) 分" }
        let hours = Int(round(Double(minutes) / 60))
        if hours < 24 { return "\(hours) 小时" }
        let days = Int(round(Double(hours) / 24))
        if days < 30 { return "\(days) 天" }
        let months = days / 30
        if months < 12 { return "\(months) 月" }
        return String(format: "%.1f 年", Double(days) / 365.0)
    }
    
    /// 人类可读的剩余到期时间
    static func dueDescription(_ dueDate: Date) -> String {
        let seconds = dueDate.timeIntervalSinceNow
        if seconds <= 0 { return "到期" }
        let days = seconds / 86400
        if days < 1 { return "今日到期" }
        if days < 2 { return "明日到期" }
        return "\(Int(days)) 天后"
    }
}
