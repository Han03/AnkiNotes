//
//  ReviewQuizView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 复习时的测评界面：通过做题评估掌握程度，自动给出评级
struct ReviewQuizView: View {
    let note: Note
    let quizService: QuizService
    var onComplete: (ReviewRating) -> Void
    
    @State private var questions: [Question] = []
    @State private var currentIndex = 0
    @State private var userAnswers: [UUID: String] = [:]
    @State private var showResult = false
    @State private var fillBlankInput = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Group {
                if questions.isEmpty {
                    EmptyStateView("该笔记暂无题目", systemImage: "doc.questionmark")
                } else if showResult {
                    resultView
                } else {
                    quizView
                }
            }
            .navigationTitle("掌握程度测评")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                loadQuestions()
            }
        }
    }
    
    // MARK: - 加载题目
    
    private func loadQuestions() {
        // 从该笔记的题目中随机抽取最多 10 题
        let noteQuestions = quizService.questions.filter { $0.noteId == note.id }
        let shuffled = noteQuestions.shuffled()
        questions = Array(shuffled.prefix(10))
    }
    
    // MARK: - 答题界面
    
    private var quizView: some View {
        let question = questions[currentIndex]
        
        return VStack(spacing: 0) {
            // 进度条
            ProgressView(value: Double(currentIndex + 1), total: Double(questions.count))
                .padding(.horizontal)
                .padding(.vertical, 8)
            
            Text("第 \(currentIndex + 1) / \(questions.count) 题")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 题干
                    Text(question.question)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    // 选择题选项
                    if question.type == .singleChoice, let options = question.options {
                        ForEach(options, id: \.key) { option in
                            Button {
                                userAnswers[question.id] = option.key
                                nextQuestion()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(option.key)
                                        .font(.subheadline.bold())
                                        .frame(width: 28, height: 28)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundColor(.blue)
                                        .clipShape(Circle())
                                    Text(option.content)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // 填空题输入
                    if question.type == .fillBlank {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("请输入答案", text: $fillBlankInput)
                                .textFieldStyle(.roundedBorder)
                                .padding(.vertical, 4)
                            
                            Button {
                                userAnswers[question.id] = fillBlankInput
                                fillBlankInput = ""
                                nextQuestion()
                            } label: {
                                Text("提交答案")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            .disabled(fillBlankInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - 结果界面
    
    private var resultView: some View {
        let correctCount = calculateCorrectCount()
        let total = questions.count
        let accuracy = total > 0 ? Double(correctCount) / Double(total) : 0
        let rating = ratingForAccuracy(accuracy)
        
        return ScrollView {
            VStack(spacing: 20) {
                // 正确率圆环
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 12)
                        .frame(width: 100, height: 100)
                    
                    Circle()
                        .trim(from: 0, to: accuracy)
                        .stroke(colorForAccuracy(accuracy), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                    
                    VStack(spacing: 2) {
                        Text("\(Int(accuracy * 100))%")
                            .font(.title2.bold())
                        Text("正确率")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 8)
                
                // 答题统计 + 评级
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("\(correctCount)")
                            .font(.title.bold())
                            .foregroundColor(.green)
                        Text("答对")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 4) {
                        Text("\(total - correctCount)")
                            .font(.title.bold())
                            .foregroundColor(.red)
                        Text("答错")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 4) {
                        Text(rating.description)
                            .font(.title.bold())
                            .foregroundColor(Color(hex: rating.color))
                        Text("评级")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                // 答题详情
                VStack(alignment: .leading, spacing: 12) {
                    Text("答题详情")
                        .font(.headline)
                    
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        let userAnswer = userAnswers[question.id] ?? ""
                        let isCorrect = question.isCorrect(userAnswer: userAnswer)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            // 题目
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(isCorrect ? .green : .red)
                                    .font(.subheadline)
                                Text("\(index + 1). \(question.question)")
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                            // 用户答案
                            HStack(alignment: .top, spacing: 4) {
                                Text("你的答案：")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(userAnswer.isEmpty ? "未作答" : userAnswer)
                                    .font(.caption)
                                    .foregroundColor(isCorrect ? .green : .red)
                            }
                            
                            // 正确答案
                            HStack(alignment: .top, spacing: 4) {
                                Text("正确答案：")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(question.answer)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            
                            // 答案解析
                            if let explanation = question.explanation, !explanation.isEmpty {
                                HStack(alignment: .top, spacing: 4) {
                                    Text("解析：")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(explanation)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                    }
                }
                
                // 应用评级按钮
                Button {
                    onComplete(rating)
                    dismiss()
                } label: {
                    Text("应用评级并继续")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(hex: rating.color))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.bottom, 8)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - 逻辑
    
    private func nextQuestion() {
        if currentIndex < questions.count - 1 {
            currentIndex += 1
        } else {
            showResult = true
        }
    }
    
    private func calculateCorrectCount() -> Int {
        var count = 0
        for question in questions {
            if let userAnswer = userAnswers[question.id],
               question.isCorrect(userAnswer: userAnswer) {
                count += 1
            }
        }
        return count
    }
    
    /// 根据正确率给出评级
    private func ratingForAccuracy(_ accuracy: Double) -> ReviewRating {
        if accuracy >= 0.9 {
            return .easy    // 简单：90%以上正确率
        } else if accuracy >= 0.7 {
            return .good    // 良好：70-89%
        } else if accuracy >= 0.4 {
            return .hard    // 困难：40-69%
        } else {
            return .again   // 极难：40%以下
        }
    }
    
    private func ratingDescription(for rating: ReviewRating) -> String {
        switch rating {
        case .again: return "掌握程度较低，需要重点复习"
        case .hard: return "掌握程度一般，需要加强记忆"
        case .good: return "掌握程度良好，继续保持"
        case .easy: return "掌握程度优秀，可以延长间隔"
        }
    }
    
    private func colorForAccuracy(_ accuracy: Double) -> Color {
        if accuracy >= 0.9 { return .green }
        if accuracy >= 0.7 { return .blue }
        if accuracy >= 0.4 { return .orange }
        return .red
    }
}
