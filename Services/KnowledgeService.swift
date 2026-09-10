//
//  KnowledgeService.swift
//  AnkiNotes
//
//  Created by AI Assistant on 2026/9/5.
//

import Foundation

/// 知识点详解状态存储（用于流式打字机效果，解决异步闭包中修改 @State 不生效的问题）
/// 打字机实现：网络/AsyncStream 的 chunk 到达节奏不可控（可能一次性积压全部行），
/// 因此 appendChunk 只做缓冲，由 50ms 定时器统一 flush 到 displayedText，
/// 保证 UI 以固定节奏逐批刷新，形成稳定的打字机效果。
final class KnowledgeExplanationStore: ObservableObject {
    @Published var displayedText = ""
    @Published var fullText = ""
    @Published var isLoading = true
    
    private var pendingBuffer = ""      // 待刷出的累积内容
    private var flushTimer: Timer?      // 节流刷新定时器
    private var totalChunks = 0         // 累计收到的 chunk 数（日志用）
    /// 每个 tick（50ms）显示的字符数（约 800 字/秒）
    /// 关键：LLM 输出可能瞬间全部到达（网络缓冲），若一次性刷出全部 buffer 则打字机失效，
    /// 因此限速刷出，剩余内容留到下一 tick，保证稳定的打字机视觉效果。
    private let charsPerTick = 40
    
    func appendChunk(_ chunk: String) {
        totalChunks += 1
        SyncLogger.shared.info("📝 appendChunk: #\(totalChunks), 长度=\(chunk.count), 内容前20=\(String(chunk.prefix(20)))")
        pendingBuffer += chunk
        // 启动/复用节流定时器（50ms 一次）
        ensureFlushTimer()
    }
    
    /// 启动节流刷新定时器（只启动一次，由 complete/reset 停止）
    private func ensureFlushTimer() {
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.flushPending()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
        SyncLogger.shared.info("📝 启动打字机节流定时器 (50ms, 每tick显示\(charsPerTick)字)")
    }
    
    /// 按限速节奏把部分累积内容刷到 displayedText（主线程调用）
    private func flushPending() {
        guard !pendingBuffer.isEmpty else { return }
        let takeCount = min(pendingBuffer.count, charsPerTick)
        let toDisplay = String(pendingBuffer.prefix(takeCount))
        displayedText += toDisplay
        pendingBuffer.removeFirst(takeCount)
        SyncLogger.shared.info("📝 打字机刷新: 本次显示\(takeCount)字, 剩余buffer=\(pendingBuffer.count), 总长=\(displayedText.count), 累计chunk=\(totalChunks)")
    }
    
    func complete(with text: String) {
        // 结束时把剩余内容一次性刷出（避免尾部滞留）
        if !pendingBuffer.isEmpty {
            displayedText += pendingBuffer
            pendingBuffer = ""
        }
        fullText = text
        isLoading = false
        flushTimer?.invalidate()
        flushTimer = nil
        SyncLogger.shared.info("📝 完成: fullText长度=\(fullText.count), displayedText长度=\(displayedText.count), 累计chunk=\(totalChunks)")
    }
    
    func setCached(_ text: String) {
        displayedText = text
        fullText = text
        isLoading = false
        pendingBuffer = ""
        flushTimer?.invalidate()
        flushTimer = nil
    }
    
    func reset() {
        displayedText = ""
        fullText = ""
        isLoading = true
        pendingBuffer = ""
        totalChunks = 0
        flushTimer?.invalidate()
        flushTimer = nil
    }
    
    deinit {
        flushTimer?.invalidate()
    }
}

/// 知识点状态存储（用于 View 中实时更新，解决异步闭包中修改 @State 不生效的问题）
final class KnowledgePointsStore: ObservableObject {
    @Published var points: [KnowledgePoint] = []
    @Published var isExtracting = false
    
    func addPoint(_ point: KnowledgePoint) {
        // 去重：避免重复添加相同关键字
        guard !points.contains(where: { $0.keyword == point.keyword }) else { return }
        points.append(point)
    }
    
    func setPoints(_ newPoints: [KnowledgePoint]) {
        points = newPoints
    }
    
    func reset() {
        points = []
        isExtracting = false
    }
}

// MARK: - SSE 流式解析器

/// SSE 流式解析器：通过 URLSession delegate 模式实现真正的逐 chunk 流式接收
/// 解决 URLSession.shared.bytes(for:) 缓冲整个响应导致流式效果失效的问题
final class SSEStreamParser: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: AsyncStream<String>.Continuation
    private var pendingData = ""  // 跨 chunk 的不完整数据缓冲
    private var didReceiveFirstByte = false  // 首字节标记（用于测 TTFT）

    init(continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    /// 每收到一段网络数据时立即调用（delegate 模式，不缓冲）
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !didReceiveFirstByte {
            didReceiveFirstByte = true
            SyncLogger.shared.info("📡 SSE 首字节到达: \(Date())")
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        pendingData += text

        // 按行切分，最后一个不完整行保留到下次
        while let newlineRange = pendingData.range(of: "\n") {
            let line = String(pendingData[..<newlineRange.lowerBound])
            pendingData = String(pendingData[newlineRange.upperBound...])
            processSSELine(line)
        }
    }

    /// 请求结束时调用（成功或失败）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 处理最后残留的不完整行
        if !pendingData.isEmpty {
            let remaining = pendingData.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingData = ""
            if !remaining.isEmpty {
                processSSELine(remaining)
            }
        }
        continuation.finish()
    }

    /// 解析单行 SSE 事件，提取 delta content 并 yield 到 AsyncStream
    private func processSSELine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data: ") else { return }
        let jsonStr = String(trimmed.dropFirst(6))
        if jsonStr == "[DONE]" { return }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return
        }

        // 过滤空 delta（部分模型会输出空 content 行），避免无意义的空派发
        guard !content.isEmpty else { return }

        SyncLogger.shared.info("📡 SSE 收到行并 yield: 长度=\(content.count), 内容前20=\(String(content.prefix(20)))")
        continuation.yield(content)
    }
}

/// 知识点服务：提取知识点关键字、生成详解、缓存管理
final class KnowledgeService: ObservableObject {
    static let shared = KnowledgeService()
    
    @Published var isExtracting = false
    @Published var isExplaining = false
    
    private let fileManager = FileManager.default
    private weak var storageService: StorageService?
    
    /// 配置 StorageService 引用（用于获取文件夹路径）
    func configure(storageService: StorageService) {
        self.storageService = storageService
    }
    private var cacheDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(".knowledge_cache", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    private init() {}
    
    // MARK: - 缓存路径（按笔记目录层级存储）
    
    /// 知识点提取缓存路径：.knowledge_cache/[笔记文件夹路径]/[笔记标题].json
    private func extractionCacheURL(for note: Note) -> URL {
        let dir = cacheDirectoryFor(note: note)
        return dir.appendingPathComponent("\(note.title).json")
    }
    
    /// 知识点详解缓存目录：.knowledge_cache/[笔记文件夹路径]/[笔记标题]/
    private func explanationCacheDirectory(for note: Note) -> URL {
        let dir = cacheDirectoryFor(note: note).appendingPathComponent(note.title, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    /// 知识点详解缓存路径：.knowledge_cache/[笔记文件夹路径]/[笔记标题]/[知识点关键字].md
    private func explanationCacheURL(for point: KnowledgePoint, note: Note) -> URL {
        let dir = explanationCacheDirectory(for: note)
        let safeFileName = sanitizeFileName(point.keyword)
        return dir.appendingPathComponent("\(safeFileName).md")
    }
    
    /// 笔记对应的缓存目录：.knowledge_cache/[笔记文件夹路径]/
    private func cacheDirectoryFor(note: Note) -> URL {
        var dir = cacheDirectory
        // 通过 StorageService 获取笔记的文件夹路径
        if let storage = storageService {
            let folderPath = storage.getFolderPath(for: note.folderId)
            if !folderPath.isEmpty && folderPath != "根目录" {
                dir = dir.appendingPathComponent(folderPath, isDirectory: true)
            }
        }
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    /// 将关键字转换为安全的文件名（替换文件系统不允许的字符）
    private func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
    
    /// 计算缓存文件相对 .knowledge_cache 根目录的路径（形如 .knowledge_cache/笔记路径/文件.md），
    /// 用于登记"待推送的知识点缓存文件"实现精准推送（避免全量 GET 比对触发云端限流）
    private func knowledgeRelativePath(of url: URL) -> String {
        let base = cacheDirectory.path
        let full = url.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        let rel = String(full.dropFirst(base.count))
        return ".knowledge_cache" + rel
    }
    
    // MARK: - 知识点提取缓存
    
    /// 清洗关键字中的行内 Markdown 符号（**、*、`、链接语法），返回纯文本
    private func sanitizeKeyword(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// 读取笔记的知识点提取缓存（历史脏数据含 markdown 符号时统一清洗）
    func loadExtraction(for note: Note) -> [KnowledgePoint]? {
        let url = extractionCacheURL(for: note)
        guard let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode(KnowledgeExtractionResult.self, from: data) else {
            return nil
        }
        // 清洗历史脏数据（带 ** 等符号的旧缓存）
        var changed = false
        let cleaned = result.points.map { p -> KnowledgePoint in
            let keyword = sanitizeKeyword(p.keyword)
            if keyword.isEmpty || keyword == p.keyword { return p }
            changed = true
            return KnowledgePoint(id: p.id, noteId: p.noteId, keyword: keyword,
                                  explanation: p.explanation, createdAt: p.createdAt)
        }
        if changed {
            saveExtraction(for: note, points: cleaned)
        }
        return cleaned
    }
    
    /// 保存知识点提取缓存
    func saveExtraction(for note: Note, points: [KnowledgePoint]) {
        let result = KnowledgeExtractionResult(noteId: note.id, noteTitle: note.title, points: points)
        if let data = try? JSONEncoder().encode(result) {
            let url = extractionCacheURL(for: note)
            try? data.write(to: url, options: .atomic)
            // 标记知识点缓存已变更：精准推送该文件到云端（不做全量 GET 比对，避免限流）
            MetadataSyncService.shared.markKnowledgeFileDirty(relativePath: knowledgeRelativePath(of: url))
        }
    }
    
    // MARK: - 详解缓存
    
    /// 读取知识点详解缓存
    func loadExplanation(for point: KnowledgePoint, note: Note) -> String? {
        let url = explanationCacheURL(for: point, note: note)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }
        return text
    }
    
    /// 保存知识点详解缓存
    func saveExplanation(for point: KnowledgePoint, note: Note, explanation: String) {
        guard !explanation.isEmpty else { return }
        if let data = explanation.data(using: .utf8) {
            let url = explanationCacheURL(for: point, note: note)
            try? data.write(to: url, options: .atomic)
            // 标记知识点缓存已变更：精准推送该文件到云端（不做全量 GET 比对，避免限流）
            MetadataSyncService.shared.markKnowledgeFileDirty(relativePath: knowledgeRelativePath(of: url))
        }
    }
    
    /// 检查知识点详解是否已生成
    func hasExplanation(for point: KnowledgePoint, note: Note) -> Bool {
        let url = explanationCacheURL(for: point, note: note)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return false
        }
        return true
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
        if let cached = loadExtraction(for: note) {
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
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
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
                        
                        guard !cleaned.isEmpty else { continue }
                        // 清洗行内 markdown 符号（**、*、`），避免符号进入知识点
                        let sanitized = sanitizeKeyword(cleaned)
                        guard !sanitized.isEmpty, sanitized.count >= 2 else { continue }
                        
                        // 验证关键字是否在原文中出现
                        guard note.markdownContent.localizedCaseInsensitiveContains(sanitized) else {
                            continue
                        }
                        
                        let point = KnowledgePoint(noteId: note.id, keyword: sanitized)
                        allPoints.append(point)
                        DispatchQueue.main.async {
                            onPoint(point)
                        }
                    }
                }
                
                // 处理最后一行
                let lastLine = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !lastLine.isEmpty {
                    let cleaned = lastLine
                        .replacingOccurrences(of: #"^\d+[\.\、]\s*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let sanitized = sanitizeKeyword(cleaned)
                    if !sanitized.isEmpty, sanitized.count >= 2,
                       note.markdownContent.localizedCaseInsensitiveContains(sanitized) {
                        let point = KnowledgePoint(noteId: note.id, keyword: sanitized)
                        allPoints.append(point)
                        DispatchQueue.main.async {
                            onPoint(point)
                        }
                    }
                }
                
                // 保存缓存 + 状态回写统一回主线程（避免跨线程触碰单例状态）
                let savedPoints = allPoints
                DispatchQueue.main.async {
                    self.saveExtraction(for: note, points: savedPoints)
                    self.isExtracting = false
                    completion(savedPoints)
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
    ///   - note: 所属笔记（用于计算缓存路径）
    ///   - noteContent: 笔记原文（用于上下文）
    ///   - config: 百炼配置
    ///   - onChunk: 每收到一段文本时回调（打字机效果）
    ///   - completion: 完成回调
    func explainKeyword(
        point: KnowledgePoint,
        note: Note,
        noteContent: String,
        config: BailianConfig,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (String) -> Void
    ) {
        // 先检查缓存
        if let cached = loadExplanation(for: point, note: note) {
            DispatchQueue.main.async {
                onChunk(cached)
                completion(cached)
            }
            return
        }
        
        isExplaining = true
        
        let prompt = buildExplanationPrompt(keyword: point.keyword, noteContent: noteContent)
        let requestStartTime = Date()
        SyncLogger.shared.info("📡 详解请求准备: model=\(config.modelCode), prompt长度=\(prompt.count), 笔记内容长度=\(noteContent.count), 发起时间=\(requestStartTime)")
        
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
        
        // 使用自定义 URLSession + delegate 实现真正的 SSE 流式接收
        // URLSession.shared.bytes(for:) 会缓冲整个响应，导致打字机效果失效
        var fullText = ""
        
        // 关键：必须用 Task.detached 在后台线程消费流。
        // 若用 Task{}（继承主 actor），AsyncStream 缓冲的多个值会被主 actor job
        // 一次性连续消费，所有 onChunk 排队到流结束后批量执行，打字机效果失效。
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let byteStream: AsyncStream<String>
            let sessionDelegate: SSEStreamParser
            let streamSession: URLSession
            do {
                var continuation: AsyncStream<String>.Continuation!
                let stream = AsyncStream<String> { continuation = $0 }
                let parser = SSEStreamParser(continuation: continuation)
                sessionDelegate = parser
                byteStream = stream

                let session = URLSession(
                    configuration: .default,
                    delegate: sessionDelegate,
                    delegateQueue: nil  // 系统创建串行 OperationQueue，保证 SSE 行按序处理
                )
                streamSession = session

                // 创建但不启动任务（session 级 delegate 已挂载 SSEStreamParser，无需 task 级 delegate）
                let dataTask = session.dataTask(with: request)

                // 启动网络请求（同步返回，delegate 回调在后台队列异步执行）
                dataTask.resume()
                SyncLogger.shared.info("📡 详解请求已发出（dataTask.resume），等待首字节...")

                // 消费流：后台线程逐 chunk 消费，每个 chunk 独立回主线程刷新 UI
                var chunkCount = 0
                for try await chunk in byteStream {
                    fullText += chunk
                    chunkCount += 1
                    let n = chunkCount
                    let len = chunk.count
                    DispatchQueue.main.async {
                        SyncLogger.shared.info("📡 派发UI: chunk#\(n), 长度=\(len)")
                        onChunk(chunk)
                    }
                }
                SyncLogger.shared.info("📡 流结束: 共消费 \(chunkCount) 个 chunk, fullText长度=\(fullText.count), 总耗时=\(String(format: "%.2f", Date().timeIntervalSince(requestStartTime)))秒（含TTFT）")

                streamSession.invalidateAndCancel()
            } catch {
                print("⚠️ 知识点详解生成失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.isExplaining = false
                    completion(fullText)
                }
                return
            }

            // 保存缓存 + 状态回写统一回主线程（避免跨线程触碰单例状态）
            let finalText = fullText
            DispatchQueue.main.async {
                self?.saveExplanation(for: point, note: note, explanation: finalText)
                self?.isExplaining = false
                completion(finalText)
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
