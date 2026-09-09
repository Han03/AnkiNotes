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
                // 题目来源：笔记标题 + 完整路径
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    Image(systemName: "folder")
                        .foregroundColor(.textSecondary)
                        .font(.appCaption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.noteTitle)
                            .font(.appCaption)
                            .foregroundColor(.textSecondary)
                        if let note = appState.storage?.getNote(id: q.noteId) {
                            let folderPath = appState.storage?.getNoteFolderPath(for: note) ?? ""
                            if !folderPath.isEmpty {
                                Text(folderPath)
                                    .font(.appCaption)
                                    .foregroundColor(.textTertiary)
                            }
                        }
                    }
                    Spacer()
                    Text(q.type == .singleChoice ? "选择题" : "填空题")
                        .font(.appCaption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.brandPrimaryLight)
                        .foregroundColor(.brandPrimary)
                        .clipShape(Capsule())
                }

                // 题干
                Text(q.question)
                    .font(.appBody)
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
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("你的答案")
                            .font(.appBody)
                            .foregroundColor(.textSecondary)
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
                        .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.brandPrimary))
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
                        .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.brandPrimary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color.bgPage)
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
            HStack(spacing: AppSpacing.md) {
                Text(option.key)
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(isCorrectAnswer ? Color.green : (isWrongSelected ? Color.red : (isSelected ? Color.brandPrimary.opacity(0.2) : Color.bgInput)))
                    )
                    .foregroundColor(isCorrectAnswer || isWrongSelected ? .white : (isSelected ? .brandPrimary : .textPrimary))
                Text(option.content)
                    .font(.appBody)
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
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.standard)
                    .fill(isCorrectAnswer ? Color.green.opacity(0.1) : (isWrongSelected ? Color.red.opacity(0.1) : (isSelected ? Color.brandPrimary.opacity(0.05) : Color.bgCard)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppCornerRadius.standard)
                    .stroke(isCorrectAnswer ? Color.green : (isWrongSelected ? Color.red : (isSelected ? Color.brandPrimary : Color.clear)), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 答案视图

    private func answerView(question: Question) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // 作答结果
            HStack(spacing: AppSpacing.sm) {
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
                    .font(.appBody)
                    .fontWeight(.medium)
                    .foregroundColor(.textSecondary)
                Text(question.answer)
                    .font(.appBody)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 答案解析
            if let explanation = question.explanation, !explanation.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("答案解析")
                        .font(.appBody)
                        .fontWeight(.medium)
                        .foregroundColor(.textSecondary)
                    Text(explanation)
                        .font(.appBody)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AppSpacing.lg)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.bgCard))
    }

    // MARK: - 结果视图

    private var accuracyPercent: Int {
        guard questions.count > 0 else { return 0 }
        return Int(Double(correctCount) / Double(questions.count) * 100)
    }

    private var resultView: some View {
        ScrollView {
            VStack(spacing: AppSpacing.xxl) {
                // 完成图标
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.brandPrimary, Color.brandPrimary.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 80, height: 80)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white)
                }

                // 统计
                VStack(spacing: AppSpacing.sm) {
                    Text("刷题完成！")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("共 \(questions.count) 题，答对 \(correctCount) 题")
                        .font(.appBody)
                        .foregroundColor(.textSecondary)
                }

                // 正确率
                VStack(spacing: AppSpacing.sm) {
                    Text("正确率")
                        .font(.headline)
                    Text("\(accuracyPercent)%")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.brandPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(AppSpacing.xxl)
                .background(RoundedRectangle(cornerRadius: AppCornerRadius.xxl).fill(Color.brandPrimaryLight))

                // 按钮
                VStack(spacing: AppSpacing.md) {
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
                        .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.brandPrimary))
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Text("返回题库")
                                .font(.headline)
                                .foregroundColor(.textPrimary)
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: AppCornerRadius.lg).fill(Color.bgInput))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color.bgPage)
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
