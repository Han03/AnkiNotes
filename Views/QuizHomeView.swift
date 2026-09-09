//
//  QuizHomeView.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import SwiftUI

/// 刷题主页：题库统计、开始刷题、生成题目
struct QuizHomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingQuiz = false
    @State private var selectedCount = 10
    @State private var stats = QuizStats()

    private let countOptions = [5, 10, 20, 30, 50]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // 正在生成题目提示
                if appState.isGeneratingQuestions {
                    generatingBanner
                }

                // 未配置百炼引导
                if !appState.bailianConfig.isConfigured {
                    notConfiguredCard
                }

                // 题库统计
                statsCard

                // 开始刷题
                if stats.totalQuestions > 0 {
                    startQuizCard
                }

                // 生成题目
                generateCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("刷题")
        .onAppear {
            refreshStats()
        }
        // 刷题结束返回后刷新统计
        .onChange(of: showingQuiz) { showing in
            if !showing {
                refreshStats()
            }
        }
        .fullScreenCover(isPresented: $showingQuiz) {
            NavigationStack {
                QuizSessionView(questionCount: selectedCount)
            }
        }
        // 生成题目报错提示
        .alert(
            "生成题目报错",
            isPresented: Binding(
                get: { appState.quizError != nil },
                set: { if !$0 { appState.quizError = nil } }
            ),
            presenting: appState.quizError
        ) { _ in
            Button("确定", role: .cancel) {
                appState.quizError = nil
            }
        } message: { error in
            Text(error)
        }
    }

    // MARK: - 正在生成提示

    private var generatingBanner: some View {
        VStack(spacing: 10) {
            HStack(spacing: AppSpacing.md) {
                ProgressView()
                    .scaleEffect(1.2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在更新题库...")
                        .font(.headline)
                        .foregroundColor(.brandPrimary)
                    if let progress = appState.generationProgress {
                        Text("正在处理：\(progress.noteTitle)（\(progress.current + 1)/\(progress.total)）")
                            .font(.appBody)
                            .foregroundColor(.textSecondary)
                        // 显示已生成字数（流式响应实时更新）
                        if appState.quizService?.generatedCharCount ?? 0 > 0 {
                            Text("已生成：\(appState.quizService?.generatedCharCount ?? 0) 字")
                                .font(.appCaption)
                                .foregroundColor(.brandPrimary.opacity(0.8))
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(AppSpacing.lg)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.xl).fill(Color.brandPrimaryLight))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.xl)
                .stroke(Color.brandPrimary.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 未配置引导

    private var notConfiguredCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.title)
                    .foregroundColor(.brandPrimary)
                Text("开启 AI 题库")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
            }
            Text("配置百炼大模型平台后，系统会自动为每篇笔记生成选择题和填空题，帮助你高效复习。")
                .font(.appBody)
                .foregroundColor(.textSecondary)
            Button {
                appState.mainTabIndex = 3  // 切换到设置页
            } label: {
                Text("去配置 →")
                    .font(.appBody)
                    .fontWeight(.medium)
                    .foregroundColor(.brandPrimary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 题库统计

    private var statsCard: some View {
        VStack(spacing: AppSpacing.lg) {
            HStack {
                Text("题库统计")
                    .font(.headline)
                Spacer()
                Text("共 \(stats.totalQuestions) 题")
                    .font(.appBody)
                    .foregroundColor(.textSecondary)
            }

            // 状态分布
            HStack(spacing: AppSpacing.md) {
                StatBox(title: "未作答", value: "\(stats.unansweredCount)", color: .gray)
                StatBox(title: "答对", value: "\(stats.correctCount)", color: .green)
                StatBox(title: "答错", value: "\(stats.wrongCount)", color: .red)
            }

            // 题型分布
            HStack(spacing: AppSpacing.md) {
                StatBox(title: "选择题", value: "\(stats.singleChoiceCount)", color: .brandPrimary)
                StatBox(title: "填空题", value: "\(stats.fillBlankCount)", color: .brandPrimary)
                StatBox(title: "正确率", value: "\(Int(stats.accuracy * 100))%", color: .brandPrimary)
            }

            // 覆盖笔记
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.brandPrimary.opacity(0.6))
                Text("覆盖 \(stats.coveredNoteCount) 篇笔记")
                    .font(.appBody)
                    .foregroundColor(.textSecondary)
                Spacer()
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 开始刷题

    private var startQuizCard: some View {
        VStack(spacing: AppSpacing.lg) {
            HStack {
                Text("开始刷题")
                    .font(.headline)
                Spacer()
            }

            // 选择题数
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("题目数量")
                    .font(.appBody)
                    .foregroundColor(.textSecondary)
                Picker("题目数量", selection: $selectedCount) {
                    ForEach(countOptions, id: \.self) { count in
                        Text("\(count) 题").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button {
                showingQuiz = true
            } label: {
                HStack(spacing: AppSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.brandPrimary, Color.brandPrimary.opacity(0.6)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 48, height: 48)
                        Image(systemName: "play.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text("开始刷题")
                            .font(.headline)
                        Text("随机抽取 \(min(selectedCount, stats.totalQuestions)) 道题，答错和未答的题目优先")
                            .font(.appCaption)
                            .foregroundColor(.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(.textSecondary)
                }
                .padding(AppSpacing.lg)
                .background(RoundedRectangle(cornerRadius: AppCornerRadius.xl).fill(Color.brandPrimaryLight))
            }
            .buttonStyle(.plain)
            .disabled(appState.isGeneratingQuestions)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 生成题目

    private var generateCard: some View {
        VStack(spacing: AppSpacing.md) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.brandPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 生成题目")
                        .font(.headline)
                    Text(appState.bailianConfig.isConfigured ? "为未生成题目的笔记生成选择题和填空题" : "请先在设置页配置百炼平台")
                        .font(.appCaption)
                        .foregroundColor(.textSecondary)
                }
                Spacer()
            }

            if appState.isGeneratingQuestions {
                // 生成中：显示取消按钮
                Button {
                    appState.cancelQuestionGeneration()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "xmark.circle.fill")
                        Text("取消生成")
                            .font(.appBody)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: AppCornerRadius.standard).fill(Color.red))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else {
                // 未生成：显示生成按钮
                Button {
                    appState.generateQuestionsForAllNotes { newCount, processedCount, wasCancelled in
                        refreshStats()
                    }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "wand.and.stars")
                        Text("生成题目")
                            .font(.appBody)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.standard)
                            .fill(appState.bailianConfig.isConfigured ? Color.brandPrimary : Color.gray)
                    )
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(!appState.bailianConfig.isConfigured)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: AppCornerRadius.huge).fill(Color.bgCard))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - 辅助

    private func refreshStats() {
        if let quiz = appState.quizService {
            stats = quiz.getStats()
        }
    }
}

// MARK: - 统计小方块

private struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }
}
