//
//  Question.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 题目类型
enum QuestionType: String, Codable {
    case singleChoice = "single_choice"  // 选择题（单选）
    case essay = "essay"                   // 问答题
}

/// 题目作答状态
enum QuestionStatus: String, Codable {
    case unanswered = "unanswered"  // 未作答
    case correct = "correct"        // 答对
    case wrong = "wrong"            // 答错
}

/// 选择题选项
struct ChoiceOption: Codable, Hashable {
    let key: String      // A/B/C/D
    let content: String  // 选项内容
}

/// 题目模型
struct Question: Identifiable, Codable, Hashable {
    let id: UUID
    let noteId: UUID              // 来源笔记 ID
    let noteTitle: String         // 来源笔记标题（冗余，便于显示）
    let type: QuestionType        // 题目类型
    let question: String          // 题干
    var options: [ChoiceOption]?  // 选择题选项（问答题为 nil）
    let answer: String            // 参考答案（选择题为正确选项 key，如 "A"；问答题为参考答案文本）
    let explanation: String?      // 答案解析
    var status: QuestionStatus    // 作答状态
    var answerCount: Int          // 作答次数
    var correctCount: Int         // 答对次数
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         noteId: UUID,
         noteTitle: String,
         type: QuestionType,
         question: String,
         options: [ChoiceOption]? = nil,
         answer: String,
         explanation: String? = nil,
         status: QuestionStatus = .unanswered,
         answerCount: Int = 0,
         correctCount: Int = 0,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.noteId = noteId
        self.noteTitle = noteTitle
        self.type = type
        self.question = question
        self.options = options
        self.answer = answer
        self.explanation = explanation
        self.status = status
        self.answerCount = answerCount
        self.correctCount = correctCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 判断用户答案是否正确
    func isCorrect(userAnswer: String) -> Bool {
        switch type {
        case .singleChoice:
            return userAnswer.uppercased().trimmingCharacters(in: .whitespaces) == answer.uppercased().trimmingCharacters(in: .whitespaces)
        case .essay:
            // 问答题不自动判分，由用户自行判断
            return false
        }
    }

    /// 记录作答结果
    mutating func recordAnswer(isCorrect: Bool) {
        answerCount += 1
        if isCorrect {
            correctCount += 1
            status = .correct
        } else {
            status = .wrong
        }
        updatedAt = Date()
    }
}

/// 题库统计
struct QuizStats: Codable {
    var totalQuestions: Int = 0
    var unansweredCount: Int = 0
    var correctCount: Int = 0
    var wrongCount: Int = 0
    var singleChoiceCount: Int = 0
    var essayCount: Int = 0
    var totalAnswerCount: Int = 0
    var totalCorrectCount: Int = 0
    var coveredNoteCount: Int = 0  // 已生成题目的笔记数

    /// 正确率
    var accuracy: Double {
        guard totalAnswerCount > 0 else { return 0 }
        return Double(totalCorrectCount) / Double(totalAnswerCount)
    }
}
