//
//  KnowledgeService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/9/5.
//

import Foundation

/// 知识点服务：提取知识点关键字、生成详解、缓存管理
final class KnowledgeService: ObservableObject {
    static let shared = KnowledgeService()
    
    @Published var isExtracting = false
    @Published var isExplaining = false
    
    private let fileManager = FileManager.default
    private var cacheDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(".knowledge_cache", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    private init() {}
    
    // MARK: - 缓存路径
    
    private func extractionCacheURL(for noteId: UUID) -> URL {
        cacheDirectory.appendingPathComponent("extraction_\(noteId.uuidString).json")
    }
    
    private func explanationCacheURL(for pointId: UUID) -> URL {
        cacheDirectory.appendingPathComponent("explain_\(pointId.uuidString).json")
    }
    
    // MARK: - 知识点提取缓存
    
    /// 读取笔记的知识点提取缓存
    func loadExtraction(for noteId: UUID) -> [KnowledgePoint]? {
        let url = extractionCacheURL(for: noteId)
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(KnowledgeExtractionResult.self, from: data) else {
            return nil
        }
        return result.points
    }
    
    /// 保存知识点提取缓存
    func saveExtraction(for noteId: UUID, points: [KnowledgePoint]) {
        let result = KnowledgeExtractionResult(noteId: noteId, points: points)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: extractionCacheURL(for: noteId))
        }
    }
    
    // MARK: - 详解缓存
    
    /// 读取知识点详解缓存
    func loadExplanation(for pointId: UUID) -> String? {
        let url = explanationCacheURL(for: pointId)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
    
    /// 保存知识点详解缓存
    func saveExplanation(for pointId: UUID, explanation: String) {
        if let data = explanation.data(using: .utf8) {
            try? data.write(to: explanationCacheURL(for: pointId))
        }
    }
    
    // MARK: - 流式提取知识点
    
    /// 流式提取知识点关键字（按行输出，每识别到一个完整知识点就回调）
    /// - Parameters:
    ///   - note: 笔记
    ///   - config: 百炼配置
    ///   - onPoint: 每识别到一个知识点时回调（实时标记用）
    ///   - completion: 完成回调，返回所有知识点
    func extractKeywords(
        note: Note,
        config: BailianConfig,
        onPoint: @escaping (KnowledgePoint) -> Void,
        completion: @escaping ([KnowledgePoint]) -> Void
    ) {
        // 先检查缓存
        if let cached = loadExtraction(for: note.id) {
            DispatchQueue.main.async {
                for point in cached {
                    onPoint(point)
                }
                completion(cached)
            }
            return
        }
        
        isExtracting = true
        
        let prompt = buildExtractionPrompt(for: note)
        
        let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        
        let body: [String: Any] = [
            "model": config.modelCode,
            "messages": [
                ["role": "system", "content": "你是一个知识点提取专家。请从笔记内容中提取重要的知识点关键字，每个关键字必须是原文中出现的一段文字。每行输出一个知识点，不要输出其他内容，不要用序号，不要用markdown格式。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "max_tokens": 8000,
            "stream": true
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        var allPoints: [KnowledgePoint] = []
        var currentLine = ""
        
        let task = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    print("⚠️ 知识点提取 HTTP 错误: \(httpResponse.statusCode)")
                    DispatchQueue.main.async {
                        self.isExtracting = false
                        completion([])
                    }
                    return
                }
                
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    if jsonStr == "[DONE]" { break }
                    
                    guard let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let first = choices.first,
                          let delta = first["delta"] as? [String: Any],
                          let content = delta["content"] as? String else {
                        continue
                    }
                    
                    currentLine += content
                    
                    // 按行解析，每识别到一行完整的知识点就处理
                    while let newlineRange = currentLine.range(of: "\n") {
                        let lineText = String(currentLine[..<newlineRange.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        currentLine = String(currentLine[newlineRange.upperBound...])
                        
                        // 跳过空行和序号
                        let cleaned = lineText
                            .replacingOccurrences(of: #"^\d+[\.\、]\s*"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        guard !cleaned.isEmpty, cleaned.count >= 2 else { continue }
                        
                        // 验证关键字是否在原文中出现
                        guard note.markdownContent.localizedCaseInsensitiveContains(cleaned) else {
                            continue
                        }
                        
                        let point = KnowledgePoint(noteId: note.id, keyword: cleaned)
                        allPoints.append(point)
                        DispatchQueue.main.async {
                            onPoint(point)
                        }
                    }
                }
                
                // 处理最后一行
                let lastLine = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !lastLine.isEmpty, lastLine.count >= 2 {
                    let cleaned = lastLine
                        .replacingOccurrences(of: #"^\d+[\.\、]\s*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty, note.markdownContent.localizedCaseInsensitiveContains(cleaned) {
                        let point = KnowledgePoint(noteId: note.id, keyword: cleaned)
                        allPoints.append(point)
                        DispatchQueue.main.async {
                            onPoint(point)
                        }
                    }
                }
                
                // 保存缓存
                self.saveExtraction(for: note.id, points: allPoints)
                
                DispatchQueue.main.async {
                    self.isExtracting = false
                    completion(allPoints)
                }
            } catch {
                print("⚠️ 知识点提取失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isExtracting = false
                    completion(allPoints)
                }
            }
        }
        
        // 保存 task 引用以便取消（简化处理，不保存）
        _ = task
    }
    
    // MARK: - 流式生成详解
    
    /// 流式生成知识点详解（打字机效果）
    /// - Parameters:
    ///   - point: 知识点
    ///   - noteContent: 笔记原文（用于上下文）
    ///   - config: 百炼配置
    ///   - onChunk: 每收到一段文本时回调（打字机效果）
    ///   - completion: 完成回调
    func explainKeyword(
        point: KnowledgePoint,
        noteContent: String,
        config: BailianConfig,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (String) -> Void
    ) {
        // 先检查缓存
        if let cached = loadExplanation(for: point.id) {
            DispatchQueue.main.async {
                onChunk(cached)
                completion(cached)
            }
            return
        }
        
        isExplaining = true
        
        let prompt = buildExplanationPrompt(keyword: point.keyword, noteContent: noteContent)
        
        let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        
        let body: [String: Any] = [
            "model": config.modelCode,
            "messages": [
                ["role": "system", "content": "你是一个知识讲解专家。请用通俗易懂的语言解释这个知识点，结合笔记中的上下文，让初学者也能理解。可以适当举例，但不要过于冗长。"],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "max_tokens": 2000,
            "stream": true
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        var fullText = ""
        
        let task = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    DispatchQueue.main.async {
                        self.isExplaining = false
                        completion("")
                    }
                    return
                }
                
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let jsonStr = String(line.dropFirst(6))
                    if jsonStr == "[DONE]" { break }
                    
                    guard let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let first = choices.first,
                          let delta = first["delta"] as? [String: Any],
                          let content = delta["content"] as? String else {
                        continue
                    }
                    
                    fullText += content
                    DispatchQueue.main.async {
                        onChunk(content)
                    }
                }
                
                // 保存缓存
                self.saveExplanation(for: point.id, explanation: fullText)
                
                DispatchQueue.main.async {
                    self.isExplaining = false
                    completion(fullText)
                }
            } catch {
                print("⚠️ 知识点详解生成失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isExplaining = false
                    completion(fullText)
                }
            }
        }
        
        _ = task
    }
    
    // MARK: - Prompt 构建
    
    private func buildExtractionPrompt(for note: Note) -> String {
        return """
        请从以下笔记内容中提取重要的知识点关键字。
        
        要求：
        1. 每个关键字必须是原文中**精确出现**的一段文字（2-30个字）
        2. 提取核心概念、术语、原理、重要定义等
        3. 每行输出一个知识点，不要加序号，不要加markdown格式
        4. 不要输出任何其他内容，只输出知识点列表
        5. 知识点数量根据笔记内容决定，重要内容不要遗漏
        
        笔记标题：\(note.title)
        
        笔记内容：
        \(note.markdownContent)
        """
    }
    
    private func buildExplanationPrompt(keyword: String, noteContent: String) -> String {
        return """
        请解释以下知识点：\(keyword)
        
        笔记上下文（供参考）：
        \(noteContent.prefix(2000))
        
        要求：
        1. 用通俗易懂的语言解释，让初学者也能理解
        2. 说明这个知识点是什么、为什么重要
        3. 可以适当举例说明
        4. 不要过于冗长，300字以内
        """
    }
}
