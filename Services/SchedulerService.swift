//
//  SchedulerService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 复习调度服务：生成今日复习队列、处理用户评级
final class SchedulerService: ObservableObject {
    
    private unowned let storage: StorageService
    
    // 每日配额（Anki 风格）
    var dailyNewCardLimit: Int = 20
    var dailyReviewCardLimit: Int = 200
    
    init(storage: StorageService) {
        self.storage = storage
    }
    
    // MARK: - 获取今日到期的复习队列
    
    /// 获取今日复习队列：到期复习卡片 + 新卡片 + 学习中短间隔到期
    /// - Parameter folderId: 指定文件夹；nil 为全部
    func getTodayReviewQueue(in folderId: UUID? = nil) -> [Note] {
        let allNotes = folderId == nil
            ? storage.getAllNotes()
            : storage.getNotes(in: folderId)
        
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!
        
        // 今日已复习的数量
        let todayReviewedIds = Set(
            storage.getReviewLogs(since: startOfDay).map { $0.noteId }
        )
        
        // 1) 到期的复习卡（review / relearning 已毕业的）/ 短间隔到期的学习卡
        var dueCards: [Note] = []
        var reviewDueCount = 0
        
        for note in allNotes {
            let isDue = note.srs.dueDate <= endOfDay
            guard isDue else { continue }
            switch note.srs.cardState {
            case .new:
                continue  // 新卡片后面单独处理
            case .learning, .relearning:
                // 学习中卡片：只要 dueDate <= now 就进入队列
                if note.srs.dueDate <= now {
                    dueCards.append(note)
                }
            case .review:
                if reviewDueCount < dailyReviewCardLimit || todayReviewedIds.contains(note.id) {
                    dueCards.append(note)
                    reviewDueCount += 1
                }
            }
        }
        
        // 2) 新卡片：按“今日还没复习过”的优先，限制 dailyNewCardLimit
        var newCards: [Note] = []
        _ = todayReviewedIds.count  // 供未来扩展每日已复习上限判断
        for note in allNotes where note.srs.cardState == .new {
            if todayReviewedIds.contains(note.id) { continue }
            if newCards.count >= dailyNewCardLimit { break }
            newCards.append(note)
        }
        
        // 排序：先学（短间隔到期）-> 到期复习 -> 新卡片；内部按到期时间升序
        dueCards.sort { $0.srs.dueDate < $1.srs.dueDate }
        newCards.sort { $0.createdAt > $1.createdAt }  // 最近创建的新卡片先学
        
        return dueCards + newCards
    }
    
    /// 今日到期的卡片总数（用于主界面小红点）
    func getTodayDueCount(in folderId: UUID? = nil) -> Int {
        getTodayReviewQueue(in: folderId).count
    }
    
    // MARK: - 处理一次复习评级
    
    /// 对指定笔记应用评级，返回更新后的 Note
    @discardableResult
    func rate(noteId: UUID, rating: ReviewRating, timeSpent: TimeInterval = 0) -> Note? {
        guard var note = storage.getNote(id: noteId) else { return nil }
        let oldInterval = note.srs.interval
        let oldEase = note.srs.easeFactor
        
        let newSRS = SM2Algorithm.applyRating(current: note.srs, rating: rating)
        note.srs = newSRS
        
        // 更新存储
        storage.updateNoteSRS(noteId: noteId, srs: newSRS)
        
        // 记录复习日志
        let log = ReviewLog(
            noteId: noteId, rating: rating,
            oldInterval: oldInterval, newInterval: newSRS.interval,
            oldEase: oldEase, newEase: newSRS.easeFactor,
            reviewDate: Date(), timeSpent: timeSpent
        )
        storage.addReviewLog(log)
        
        return note
    }
    
    // MARK: - 评级预览（UI 按钮上显示的下次间隔）
    
    func previewNextInterval(note: Note, rating: ReviewRating) -> String {
        SM2Algorithm.nextIntervalPreview(current: note.srs, rating: rating)
    }
    
    // MARK: - 统计数据
    
    func computeStats() -> StatsSummary {
        let notes = storage.getAllNotes()
        let startOfDay = Calendar.current.startOfDay(for: Date())
        
        var stats = StatsSummary()
        stats.totalNotes = notes.count
        
        let queue = getTodayReviewQueue()
        stats.dueToday = queue.count
        stats.newCount = notes.filter { $0.srs.cardState == .new }.count
        stats.learningCount = notes.filter { $0.srs.cardState == .learning || $0.srs.cardState == .relearning }.count
        stats.masteredCount = notes.filter {
            $0.srs.easeFactor >= 2.3 && $0.srs.interval >= 21
        }.count
        
        let todayLogs = storage.getReviewLogs(since: startOfDay)
        stats.reviewedToday = todayLogs.count
        stats.newToday = todayLogs.filter { log in
            log.oldInterval == 0 && log.newInterval > 0
        }.count
        
        stats.totalReviews = storage.getReviewLogs(since: .distantPast).count
        
        // 过去 7 天
        for i in 0..<7 {
            if let dayStart = Calendar.current.date(byAdding: .day, value: -(6 - i), to: startOfDay),
               let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) {
                let count = storage.getReviewLogs(since: .distantPast)
                    .filter { $0.reviewDate >= dayStart && $0.reviewDate < dayEnd }
                    .count
                stats.weeklyReviewCounts[i] = count
            }
        }
        
        stats.streakDays = computeStreakDays()
        return stats
    }
    
    private func computeStreakDays() -> Int {
        let cal = Calendar.current
        var streak = 0
        let allLogs = storage.getReviewLogs(since: .distantPast)
        guard !allLogs.isEmpty else { return 0 }
        
        var checkDate = cal.startOfDay(for: Date())
        while true {
            let dayLogs = allLogs.filter { log in
                cal.isDate(log.reviewDate, inSameDayAs: checkDate)
            }
            if !dayLogs.isEmpty {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: checkDate) else { break }
                checkDate = prev
            } else {
                // 今天还没复习，不应该打断昨天的连续打卡
                if streak == 0 && cal.isDateInToday(checkDate) {
                    guard let prev = cal.date(byAdding: .day, value: -1, to: checkDate) else { break }
                    checkDate = prev
                    continue
                }
                break
            }
            if streak > 3650 { break } // 安全上限
        }
        return streak
    }
}
