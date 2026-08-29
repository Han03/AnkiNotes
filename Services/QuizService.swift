//
//  QuizService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/8/29.
//

import Foundation

/// 百炼平台配置
struct BailianConfig: Codable, Hashable {
    var apiKey: String      // 百炼 API Key
    var modelCode: String   // 模型编码，如 qwen-plus、qwen-turbo 等

    enum CodingKeys: CodingKey { case apiKey, modelCode }

    init(apiKey: String = "", modelCode: String = "qwen-plus") {
        self.apiKey = apiKey
        self.modelCode = modelCode
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 题库服务：管理题目存储、生成、选题
final class QuizService {
    private(set) var questions: [Question] = []
    private(set) var generatedNoteIds: Set<UUID> = []  // 已生成题目的笔记 ID
    private(set) var isGenerating = false  // 是否正在生成题目
    private(set) var isCancelled = false    // 是否被用户取消
    private(set) var failedNoteIds: Set<UUID> = []  // 生成失败的笔记ID（可重试）

    private let fileURL: URL
    private let generatedIdsURL: URL

    init(fileSystem: FileSystemService) {
        self.fileURL = fileSystem.metadataDirectory.appendingPathComponent("quiz_questions.json")
        self.generatedIdsURL = fileSystem.metadataDirectory.appendingPathComponent("quiz_generated_notes.json")
        load()
    }

    // MARK: - 持久化

    private func load() {
        // 加载题目
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Question].self, from: data) {
            questions = decoded
        }
        // 加载已生成笔记 ID
        if let data = try? Data(contentsOf: generatedIdsURL),
           let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            generatedNoteIds = Set(decoded)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(questions) {
            try? data.write(to: fileURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(Array(generatedNoteIds)) {
            try? data.write(to: generatedIdsURL, options: .atomic)
        }
    }

    // MARK: - 题库统计

    func getStats() -> QuizStats {
        var stats = QuizStats()
        stats.totalQuestions = questions.count
        stats.unansweredCount = questions.filter { $0.status == .unanswered }.count
        stats.correctCount = questions.filter { $0.status == .correct }.count
        stats.wrongCount = questions.filter { $0.status == .wrong }.count
        stats.singleChoiceCount = questions.filter { $0.type == .singleChoice }.count
        stats.fillBlankCount = questions.filter { $0.type == .fillBlank }.count
        stats.totalAnswerCount = questions.reduce(0) { $0 + $1.answerCount }
        stats.totalCorrectCount = questions.reduce(0) { $0 + $1.correctCount }
        stats.coveredNoteCount = Set(questions.map { $0.noteId }).count
        return stats
    }

    // MARK: - 题目作答

    func recordAnswer(questionId: UUID, isCorrect: Bool) {
        guard let idx = questions.firstIndex(where: { $0.id == questionId }) else { return }
        questions[idx].recordAnswer(isCorrect: isCorrect)
        save()
    }

    // MARK: - 选题算法

    /// 从题库中随机选取指定数量的题目
    /// 算法：加权随机，做对的题目权重低，答错/未做的题目权重高
    /// 保证不同题目被选中的实际概率相同（在相同状态下）
    func selectQuestions(count: Int) -> [Question] {
        guard !questions.isEmpty else { return [] }
        let targetCount = min(count, questions.count)

        // 计算每个题目的权重
        // 未作答: 权重 3.0
        // 答错: 权重 2.5
        // 答对: 权重 1.0
        // 答对次数越多，权重越低（最低 0.5）
        var weighted: [(question: Question, weight: Double)] = []
        for q in questions {
            var weight: Double
            switch q.status {
            case .unanswered:
                weight = 3.0
            case .wrong:
                weight = 2.5
            case .correct:
                // 答对次数越多，权重越低
                let reduction = min(Double(q.correctCount) * 0.3, 0.5)
                weight = max(1.0 - reduction, 0.5)
            }
            weighted.append((q, weight))
        }

        // 加权随机选取（不重复）
        var selected: [Question] = []
        var remaining = weighted
        while selected.count < targetCount && !remaining.isEmpty {
            let totalWeight = remaining.reduce(0.0) { $0 + $1.weight }
            let random = Double.random(in: 0..<totalWeight)
            var cumulative = 0.0
            var selectedIndex = 0
            for (i, item) in remaining.enumerated() {
                cumulative += item.weight
                if random < cumulative {
                    selectedIndex = i
                    break
                }
            }
            selected.append(remaining[selectedIndex].question)
            remaining.remove(at: selectedIndex)
        }

        return selected
    }

    // MARK: - 大模型生成题目

    /// 取消正在进行的题目生成
    func cancelGeneration() {
        isCancelled = true
    }
    
    /// 为所有未生成题目的笔记生成题目（后台异步执行）
    /// - Parameters:
    ///   - notes: 所有笔记
    ///   - config: 百炼配置
    ///   - onProgress: 进度回调 (当前处理索引, 总数, 当前笔记标题)
    ///   - completion: 完成回调
    func generateQuestionsForAllNotes(
        notes: [Note],
        config: BailianConfig,
        onProgress: @escaping (Int, Int, String) -> Void,
        completion: @escaping (Int, Int, Bool) -> Void  // (新增题目数, 处理笔记数, 是否被取消)
    ) {
        guard config.isConfigured else {
            completion(0, 0, false)
            return
        }
        guard !isGenerating else {
            completion(0, 0, false)
            return
        }

        isGenerating = true
        isCancelled = false

        // 筛选未生成题目的笔记（排除之前失败的，允许重试）
        let pendingNotes = notes.filter { !generatedNoteIds.contains($0.id) }
        guard !pendingNotes.isEmpty else {
            isGenerating = false
            completion(0, 0, false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var totalNewQuestions = 0
            var processedNotes = 0
            var wasCancelled = false

            for (index, note) in pendingNotes.enumerated() {
                // 检查是否被取消
                if self.isCancelled {
                    wasCancelled = true
                    break
                }

                DispatchQueue.main.async {
                    onProgress(index, pendingNotes.count, note.title)
                }

                // 为单篇笔记生成题目
                let newQuestions = self.generateQuestionsForNote(note: note, config: config)
                if !newQuestions.isEmpty {
                    self.questions.append(contentsOf: newQuestions)
                    totalNewQuestions += newQuestions.count
                    // 生成成功，标记该笔记已生成
                    self.generatedNoteIds.insert(note.id)
                    self.failedNoteIds.remove(note.id)
                } else {
                    // 生成失败，记录到失败集合，不标记为已生成（下次可重试）
                    self.failedNoteIds.insert(note.id)
                }
                processedNotes += 1

                // 每完成一个笔记就立即保存，确保中断不丢失已生成题目
                self.save()
            }

            self.isGenerating = false
            self.isCancelled = false

            DispatchQueue.main.async {
                completion(totalNewQuestions, processedNotes, wasCancelled)
            }
        }
    }

    /// 为单篇笔记生成题目
    private func generateQuestionsForNote(note: Note, config: BailianConfig) -> [Question] {
        let prompt = buildPrompt(for: note)
        guard let response = callBailianAPI(prompt: prompt, config: config) else {
            return []
        }
        return parseQuestions(from: response, note: note)
    }

    /// 构建生成题目的 Prompt
    private func buildPrompt(for note: Note) -> String {
        return """
        你是一个专业的题库生成助手。请根据以下笔记内容，生成选择题和问答题，用于复习和测试。

        笔记标题：\(note.title)

        笔记内容：
        \(note.markdownContent)

        要求：
        1. 仔细阅读笔记的全部内容，不要遗漏任何知识点，尽可能完整地覆盖笔记内容。
        2. 根据知识点的性质自动判断题目的合适类型：
           - 对于概念辨析、定义判断、原理选择等，使用选择题（single_choice），提供4个选项
           - 对于关键术语、定义填空、数值记忆等，使用填空题（fill_blank），题干中用____表示空缺
        3. 不限制题目数量，笔记内容越多，生成的题目也应该越多，确保每个重要知识点都有对应的题目。
        4. 每道题都要有明确的参考答案和简要解析。
        5. 选择题的选项要合理，干扰项要有迷惑性。
        6. 填空题的答案要唯一且明确，如果有多个可接受的答案，用 / 分隔。
        7. 题目难度适中，既能检验理解，又不会过于偏门。

        请严格按照以下 JSON 格式输出，不要输出任何其他内容：

        {
          "questions": [
            {
              "type": "single_choice",
              "question": "题目内容",
              "options": [
                {"key": "A", "content": "选项A内容"},
                {"key": "B", "content": "选项B内容"},
                {"key": "C", "content": "选项C内容"},
                {"key": "D", "content": "选项D内容"}
              ],
              "answer": "A",
              "explanation": "答案解析"
            },
            {
              "type": "fill_blank",
              "question": "Swift中，声明可选类型使用____符号。",
              "answer": "?",
              "explanation": "答案解析"
            }
          ]
        }
        """
    }

    /// 调用百炼 API
    private func callBailianAPI(prompt: String, config: BailianConfig) -> String? {
        let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.modelCode,
            "messages": [
                ["role": "system", "content": "你是一个专业的题库生成助手，严格按照要求的 JSON 格式输出。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "max_tokens": 4000
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil else {
                print("⚠️ 百炼 API 请求失败: \(error?.localizedDescription ?? "unknown")")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                result = content
            } else {
                print("⚠️ 百炼 API 响应解析失败: \(String(data: data, encoding: .utf8) ?? "")")
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 120)  // 超时 120 秒
        return result
    }

    /// 解析大模型返回的题目
    private func parseQuestions(from response: String, note: Note) -> [Question] {
        // 提取 JSON 部分（可能包含 markdown 代码块）
        var jsonString = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // 移除 ```json 前缀和 ``` 后缀
        if jsonString.hasPrefix("```json") {
            jsonString = String(jsonString.dropFirst(7))
        } else if jsonString.hasPrefix("```") {
            jsonString = String(jsonString.dropFirst(3))
        }
        if jsonString.hasSuffix("```") {
            jsonString = String(jsonString.dropLast(3))
        }
        jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let questionsData = json["questions"] as? [[String: Any]] else {
            print("⚠️ 题目 JSON 解析失败: \(response.prefix(200))")
            return []
        }

        var questions: [Question] = []
        for qData in questionsData {
            guard let typeStr = qData["type"] as? String,
                  let questionText = qData["question"] as? String,
                  let answer = qData["answer"] as? String else {
                continue
            }

            let type: QuestionType = typeStr == "single_choice" ? .singleChoice : .fillBlank
            let explanation = qData["explanation"] as? String

            var options: [ChoiceOption]? = nil
            if type == .singleChoice,
               let optsData = qData["options"] as? [[String: Any]] {
                options = optsData.compactMap { opt in
                    guard let key = opt["key"] as? String,
                          let content = opt["content"] as? String else {
                        return nil
                    }
                    return ChoiceOption(key: key, content: content)
                }
            }

            let question = Question(
                noteId: note.id,
                noteTitle: note.title,
                type: type,
                question: questionText,
                options: options,
                answer: answer,
                explanation: explanation
            )
            questions.append(question)
        }

        return questions
    }
}
