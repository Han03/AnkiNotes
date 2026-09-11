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
/// 知识点详解打字机状态机（与网络完全解耦）
/// - appendChunk：网络 chunk 只入缓冲，不直接显示
/// - 50ms 固定节拍从缓冲刷出（40字/tick），无论网络快慢都形成稳定打字机效果
/// - complete：网络流结束，剩余缓冲继续按节拍刷完后再结束加载（不一次性刷空）
/// - fail：出错时保留已生成内容，刷完剩余后显示错误提示
final class KnowledgeExplanationStore: ObservableObject {
    @Published private(set) var displayedText = ""
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    private var pendingBuffer = ""      // 待刷出的累积内容
    private var flushTimer: Timer?      // 50ms 节流定时器
    private var didFinish = false       // 网络流是否已结束（正常 complete 或失败）
    private let charsPerTick = 40       // 每 tick 显示的字符数（约 800 字/秒）

    /// 追加一段网络内容到缓冲（不直接显示，由节拍刷出）
    func appendChunk(_ chunk: String) {
        pendingBuffer += chunk
        ensureFlushTimer()
    }

    /// 网络流正常结束：剩余缓冲继续按节拍刷出，刷完自动结束加载
    func complete() {
        didFinish = true
        if pendingBuffer.isEmpty {
            finish()
        } else {
            ensureFlushTimer()  // 保险：Timer 意外未运行则补启动
        }
    }

    /// 网络流失败：保留已生成内容，刷完剩余后进入错误态
    func fail(_ message: String) {
        didFinish = true
        errorMessage = message
        // 已到达的内容不丢失：剩余缓冲直接刷出（错误场景不再追求打字机节奏）
        if !pendingBuffer.isEmpty {
            displayedText += pendingBuffer
            pendingBuffer = ""
        }
        finish()
    }

    /// 直接展示缓存内容（无打字机）
    func setCached(_ text: String) {
        displayedText = text
        pendingBuffer = ""
        didFinish = true
        finish()
    }

    func reset() {
        displayedText = ""
        pendingBuffer = ""
        errorMessage = nil
        didFinish = false
        isLoading = true
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func ensureFlushTimer() {
        guard flushTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.flushPending()
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func flushPending() {
        guard !pendingBuffer.isEmpty else {
            if didFinish { finish() }
            return
        }
        let take = min(pendingBuffer.count, charsPerTick)
        displayedText += pendingBuffer.prefix(take)
        pendingBuffer.removeFirst(take)
        if didFinish && pendingBuffer.isEmpty { finish() }
    }

    private func finish() {
        flushTimer?.invalidate()
        flushTimer = nil
        isLoading = false
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

/// 知识点服务：提取知识点关键字、生成详解、缓存管理
final class KnowledgeService: ObservableObject {
    static let shared = KnowledgeService()
    
    @Published var isExtracting = false
    @Published var isExplaining = false
    
    private let fileManager = FileManager.default
    private weak var storageService: StorageService?
    /// 云端文件系统（用于知识点缓存文件的直接上传）
    weak var cloudFS: CloudFileSystem?
    /// 同步快照服务（上传后更新快照，避免下次同步冗余 GET 比对）
    weak var syncSnapshotService: SyncSnapshotService?
    
    /// 配置 StorageService 引用（用于获取文件夹路径）
    func configure(storageService: StorageService) {
        self.storageService = storageService
    }
    /// 知识点缓存根目录（通过 FileSystemService 获取，位于 Notes/ 下）
    private var cacheDirectory: URL {
        guard let storage = storageService else {
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent("Notes", isDirectory: true)
        }
        return storage.fileSystem.notesRootDirectory
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
    
    /// 笔记对应的缓存目录：Notes/{folderPath}/.knowledge_cache/{title}/
    private func cacheDirectoryFor(note: Note) -> URL {
        guard let storage = storageService else { return cacheDirectory }
        let dir = storage.fileSystem.knowledgeCacheDirectory(title: note.title, folderPath: note.folderPath)
        return dir.deletingLastPathComponent() // 返回 .knowledge_cache/ 目录（不含 title 子目录）
    }
    
    /// 将关键字转换为安全的文件名（替换文件系统不允许的字符）
    private func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
    
    /// 将知识点缓存文件直接上传到云端（与题库上传 syncToCloud 同模式，无锁无防抖）
    private func syncKnowledgeFileToCloud(localURL: URL, data: Data) {
        guard let cloudFS = cloudFS else { return }
        let docsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let relativePath = localURL.path.replacingOccurrences(of: docsPath, with: "")
        // 去掉前导 "/"，与 pullKnowledgeCache 中的快照 key 格式一致
        let snapshotKey = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        // 在异步块前捕获修改时间，避免竞态
        let modDate = (try? fileManager.attributesOfItem(atPath: localURL.path))?[.modificationDate] as? Date
        let cloudURL = cloudFS.rootDirectory.appendingPathComponent(relativePath)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try cloudFS.createDirectoryIfNeeded(at: cloudURL.deletingLastPathComponent())
                try cloudFS.writeData(data, to: cloudURL)
                // 上传成功后更新快照，避免下次同步时冗余 GET 比对
                if let modDate = modDate {
                    self?.syncSnapshotService?.updateFile(relativePath: snapshotKey, lastModified: modDate)
                }
            } catch {
                print("⚠️ 知识点缓存上传失败: \(error.localizedDescription)")
            }
        }
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
            return KnowledgePoint(id: p.id, notePath: p.notePath, keyword: keyword,
                                  explanation: p.explanation, createdAt: p.createdAt)
        }
        if changed {
            saveExtraction(for: note, points: cleaned)
        }
        return cleaned
    }
    
    /// 保存知识点提取缓存
    func saveExtraction(for note: Note, points: [KnowledgePoint]) {
        let result = KnowledgeExtractionResult(notePath: note.notePath, noteTitle: note.title, points: points)
        if let data = try? JSONEncoder().encode(result) {
            let url = extractionCacheURL(for: note)
            try? data.write(to: url, options: .atomic)
            syncKnowledgeFileToCloud(localURL: url, data: data)
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
            syncKnowledgeFileToCloud(localURL: url, data: data)
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
                        
                        let point = KnowledgePoint(notePath: note.notePath, keyword: sanitized)
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
                        let point = KnowledgePoint(notePath: note.notePath, keyword: sanitized)
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
    ///   - onChunk: 每收到一段文本时回调（主线程）
    ///   - onError: 网络/解析失败时回调（主线程）
    ///   - completion: 完成回调（主线程），无论成功失败都会调用
    /// - Returns: Task 句柄（调用方可通过 cancel() 取消），缓存命中时返回 nil
    /// 
    /// 技术要点（针对历史多轮"非流式"问题）：
    /// 1. TTFT：URLSession.shared 共享连接池跨请求复用 TCP/TLS（原实现每次新建
    ///    URLSession(delegate:) 导致每次全新握手——日志实证第一次 TTFT 0.7s、第二次 26.3s）
    /// 2. 消费端：Task.detached 后台逐行消费（主 actor for-await 会一次性批量消费全部缓冲，
    ///    打字机失效；bytes 流本身不缓冲）
    /// 3. 打字机节奏：由 KnowledgeExplanationStore 的 50ms 节拍刷出，与网络 chunk 到达节奏
    ///    解耦（网络快时内容整体到达也不影响打字机效果）
    func explainKeyword(
        point: KnowledgePoint,
        note: Note,
        noteContent: String,
        config: BailianConfig,
        onChunk: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        completion: @escaping (String) -> Void
    ) -> Task<Void, Never>? {
        // 缓存优先：直接回放
        if let cached = loadExplanation(for: point, note: note) {
            DispatchQueue.main.async {
                onChunk(cached)
                completion(cached)
            }
            return nil
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
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var fullText = ""
            // SSEStreamManager：共享 URLSession（连接复用保 TTFT）+ delegate 逐段接收（真流式）。
            // 不用 URLSession.shared.bytes(for:)：AsyncBytes 在 iOS 上缓冲整个响应，
            // 首字节后几十毫秒全量到达（日志实证），打字机失去真实流式基础。
            var chunkCount = 0
            let stream = SSEStreamManager.shared.stream(for: request)
            for await chunk in stream {
                fullText += chunk
                chunkCount += 1
                let c = chunk
                DispatchQueue.main.async {
                    onChunk(c)
                }
            }
            SyncLogger.shared.info("📡 流结束: 共消费 \(chunkCount) 个 chunk, fullText长度=\(fullText.count), 总耗时=\(String(format: "%.2f", Date().timeIntervalSince(requestStartTime)))秒（含TTFT）")
            
            let finalText = fullText
            DispatchQueue.main.async {
                self?.saveExplanation(for: point, note: note, explanation: finalText)
                self?.isExplaining = false
                completion(finalText)
            }
        }
        
        return task
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
        // 围绕知识点截取上下文（而非全文前缀 2000 字）：
        // 知识点必为原文精确出现的片段，定位后截取前后各 400 字，prompt 从 2000+ 降到约 900，
        // 显著降低服务端输入处理耗时（TTFT）
        let context = contextAround(keyword: keyword, in: noteContent, radius: 400)
        return """
        请用通俗易懂的语言解释笔记中的知识点"\(keyword)"，让初学者也能理解，可以适当举例，300字以内。
        
        笔记内容（节选）：
        \(context)
        """
    }
    
    /// 在笔记原文中定位知识点并截取上下文（找不到时回退前缀）
    private func contextAround(keyword: String, in content: String, radius: Int) -> String {
        guard !keyword.isEmpty, let range = content.range(of: keyword) else {
            return String(content.prefix(radius))
        }
        let lower = content.index(range.lowerBound, offsetBy: -radius, limitedBy: content.startIndex) ?? content.startIndex
        let upper = content.index(range.upperBound, offsetBy: radius, limitedBy: content.endIndex) ?? content.endIndex
        return String(content[lower..<upper])
    }
}
