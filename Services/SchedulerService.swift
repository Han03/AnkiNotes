//
//  SchedulerService.swift
//  AnkiNotes
//
//  复习调度服务：生成今日复习队列、处理用户评级
//

import Foundation

/// 复习调度服务：生成今日复习队列、处理用户评级
final class SchedulerService: ObservableObject {

    private unowned let storage: StorageService

    var dailyNewCardLimit: Int = 500
    var dailyReviewCardLimit: Int = 500

    /// 缓存：按文件夹路径统计的今日到期数量 (folderPath -> count)
    private var dueCountByFolderCache: [String: Int] = [:]
    private var lastCacheUpdateTime: Date = .distantPast

    init(storage: StorageService) {
        self.storage = storage
        refreshDueCountCache()
    }

    func refreshDueCountCache() {
        dueCountByFolderCache.removeAll()
        lastCacheUpdateTime = Date()
        let allQueue = getTodayReviewQueue(in: nil)
        dueCountByFolderCache[""] = allQueue.count
    }

    // MARK: - 获取今日到期的复习队列

    func getTodayReviewQueue(in folderPath: String? = nil) -> [Note] {
        let allNotes: [Note]
        if let folderPath = folderPath {
            allNotes = storage.getAllNotesRecursive(in: folderPath)
        } else {
            allNotes = storage.getAllNotes()
        }

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay)!

        // 今日已复习的笔记路径
        let todayReviewedPaths = storage.getReviewedNotePaths(since: startOfDay)

        // 1) 到期的复习卡 / 短间隔到期的学习卡
        var dueCards: [Note] = []
        var reviewDueCount = 0

        for note in allNotes {
            let isDue = note.srs.dueDate <= endOfDay
            guard isDue else { continue }
            switch note.srs.cardState {
            case .new:
                continue
            case .learning, .relearning:
                if note.srs.dueDate <= now {
                    dueCards.append(note)
                }
            case .review:
                if todayReviewedPaths.contains(note.notePath) { continue }
                if reviewDueCount < dailyReviewCardLimit {
                    dueCards.append(note)
                    reviewDueCount += 1
                }
            }
        }

        // 2) 新卡片
        var newCards: [Note] = []
        for note in allNotes where note.srs.cardState == .new {
            if todayReviewedPaths.contains(note.notePath) { continue }
            if newCards.count >= dailyNewCardLimit { break }
            newCards.append(note)
        }

        dueCards.sort { $0.srs.dueDate < $1.srs.dueDate }
        newCards.sort { $0.createdAt < $1.createdAt }

        return dueCards + newCards
    }

    func getTodayDueCount(in folderPath: String? = nil) -> Int {
        let key = folderPath ?? ""
        let now = Date()
        if now.timeIntervalSince(lastCacheUpdateTime) > 60 || dueCountByFolderCache[key] == nil {
            let count = getTodayReviewQueue(in: folderPath).count
            dueCountByFolderCache[key] = count
            lastCacheUpdateTime = now
            return count
        }
        return dueCountByFolderCache[key] ?? 0
    }

    // MARK: - 处理一次复习评级

    @discardableResult
    func rate(notePath: String, rating: ReviewRating, timeSpent: TimeInterval = 0) -> Note? {
        guard var note = storage.getNote(notePath: notePath) else { return nil }
        let oldInterval = note.srs.interval
        let oldEase = note.srs.easeFactor

        let newSRS = SM2Algorithm.applyRating(current: note.srs, rating: rating)
        note.srs = newSRS

        storage.updateNoteSRS(notePath: notePath, srs: newSRS)

        // 记录复习日志（直接写入该笔记的 .meta）
        let log = ReviewLog(
            rating: rating,
            oldInterval: oldInterval, newInterval: newSRS.interval,
            oldEase: oldEase, newEase: newSRS.easeFactor,
            reviewDate: Date(), timeSpent: timeSpent
        )
        storage.addReviewLog(log, for: notePath)

        dueCountByFolderCache.removeAll()
        lastCacheUpdateTime = .distantPast

        return note
    }

    // MARK: - 评级预览

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
                if streak == 0 && cal.isDateInToday(checkDate) {
                    guard let prev = cal.date(byAdding: .day, value: -1, to: checkDate) else { break }
                    checkDate = prev
                    continue
                }
                break
            }
            if streak > 3650 { break }
        }
        return streak
    }
}
