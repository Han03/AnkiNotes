//
//  QuizSessionView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 刷题会话视图
struct QuizSessionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let questionCount: Int

    @State private var questions: [Question] = []
    @State private var currentIndex = 0
    @State private var selectedAnswer: String? = nil  // 选择题选中的选项
    @State private var essayAnswer: String = ""        // 填空题用户答案
    @State private var showAnswer = false              // 是否显示答案
    @State private var isCorrect: Bool? = nil          // 本次作答是否正确
    @State private var correctCount = 0
    @State private var finished = false

    private var currentQuestion: Question? {
        guard currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    var body: some View {
        Group {
            if finished {
                resultView
            } else if let q = currentQuestion {
                questionView(q)
            } else {
                ProgressView("加载题目中...")
            }
        }
        .navigationTitle("刷题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("退出") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !finished {
                    Text("\(currentIndex + 1)/\(questions.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            loadQuestions()
        }
    }

    // MARK: - 加载题目

    private func loadQuestions() {
        guard let quiz = appState.quizService else { return }
        questions = quiz.selectQuestions(count: questionCount)
        if questions.isEmpty {
            finished = true
        }
    }

    // MARK: - 题目视图

    private func questionView(_ q: Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 题目来源
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)
                    Text(q.noteTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(q.type == .singleChoice ? "选择题" : "填空题")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(q.type == .singleChoice ? Color.blue.opacity(0.1) : Color.orange.opacity(0.1))
                        .foregroundColor(q.type == .singleChoice ? .blue : .orange)
                        .clipShape(Capsule())
                }

                // 题干
                Text(q.question)
                    .font(.body)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)

                // 选择题选项
                if q.type == .singleChoice, let options = q.options {
                    VStack(spacing: 10) {
                        ForEach(options, id: \.key) { option in
                            choiceButton(option: option, question: q)
                        }
                    }
                }

                // 填空题输入
                if q.type == .fillBlank {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的答案")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("请输入答案", text: $essayAnswer)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .disabled(showAnswer)
                    }
                }

                // 提交答案按钮
                if !showAnswer {
                    Button {
                        submitAnswer()
                    } label: {
                        HStack {
                            Spacer()
                            Text("提交答案")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple))
                    }
                    .buttonStyle(.plain)
                    .disabled(q.type == .singleChoice ? selectedAnswer == nil : essayAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(q.type == .singleChoice ? (selectedAnswer == nil ? 0.5 : 1) : (essayAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1))
                }

                // 答案解析
                if showAnswer {
                    answerView(question: q)
                }

                // 下一题按钮
                if showAnswer {
                    Button {
                        nextQuestion()
                    } label: {
                        HStack {
                            Spacer()
                            Text(currentIndex == questions.count - 1 ? "查看结果" : "下一题")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 选择题按钮

    private func choiceButton(option: ChoiceOption, question: Question) -> some View {
        let isSelected = selectedAnswer == option.key
        let isCorrectAnswer = showAnswer && option.key.uppercased() == question.answer.uppercased()
        let isWrongSelected = showAnswer && isSelected && !isCorrectAnswer

        return Button {
            if !showAnswer {
                selectedAnswer = option.key
            }
        } label: {
            HStack(spacing: 12) {
                Text(option.key)
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isCorrectAnswer ? Color.green : (isWrongSelected ? Color.red : (isSelected ? Color.purple.opacity(0.2) : Color(.secondarySystemBackground))))
                    )
                    .foregroundColor(isCorrectAnswer || isWrongSelected ? .white : (isSelected ? .purple : .primary))
                Text(option.content)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if isCorrectAnswer {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if isWrongSelected {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCorrectAnswer ? Color.green.opacity(0.1) : (isWrongSelected ? Color.red.opacity(0.1) : (isSelected ? Color.purple.opacity(0.05) : Color(.systemBackground))))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCorrectAnswer ? Color.green : (isWrongSelected ? Color.red : (isSelected ? Color.purple : Color.clear)), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 答案视图

    private func answerView(question: Question) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 作答结果
            HStack(spacing: 8) {
                if let correct = isCorrect {
                    Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(correct ? .green : .red)
                    Text(correct ? "回答正确！" : "回答错误")
                        .font(.headline)
                        .foregroundColor(correct ? .green : .red)
                }
                Spacer()
            }

            // 参考答案
            VStack(alignment: .leading, spacing: 6) {
                Text("参考答案")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Text(question.answer)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 答案解析
            if let explanation = question.explanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("答案解析")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(explanation)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
    }

    // MARK: - 结果视图

    private var accuracyPercent: Int {
        guard questions.count > 0 else { return 0 }
        return Int(Double(correctCount) / Double(questions.count) * 100)
    }

    private var resultView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 完成图标
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.purple, Color.purple.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 80, height: 80)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white)
                }

                // 统计
                VStack(spacing: 8) {
                    Text("刷题完成！")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("共 \(questions.count) 题，答对 \(correctCount) 题")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // 正确率
                VStack(spacing: 8) {
                    Text("正确率")
                        .font(.headline)
                    Text("\(accuracyPercent)%")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.purple)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.08)))

                // 按钮
                VStack(spacing: 12) {
                    Button {
                        // 重新刷题
                        currentIndex = 0
                        correctCount = 0
                        finished = false
                        selectedAnswer = nil
                        essayAnswer = ""
                        showAnswer = false
                        isCorrect = nil
                        loadQuestions()
                    } label: {
                        HStack {
                            Spacer()
                            Text("再刷一组")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple))
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("返回题库")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 提交答案

    private func submitAnswer() {
        guard let q = currentQuestion else { return }

        if q.type == .singleChoice {
            guard let selected = selectedAnswer else { return }
            let correct = q.isCorrect(userAnswer: selected)
            isCorrect = correct
            if correct { correctCount += 1 }
            appState.quizService?.recordAnswer(questionId: q.id, isCorrect: correct)
        } else {
            // 填空题：自动判分
            let correct = q.isCorrect(userAnswer: essayAnswer)
            isCorrect = correct
            if correct { correctCount += 1 }
            appState.quizService?.recordAnswer(questionId: q.id, isCorrect: correct)
        }

        showAnswer = true
    }

    // MARK: - 下一题

    private func nextQuestion() {
        if currentIndex < questions.count - 1 {
            currentIndex += 1
            selectedAnswer = nil
            essayAnswer = ""
            showAnswer = false
            isCorrect = nil
        } else {
            finished = true
        }
    }
}
