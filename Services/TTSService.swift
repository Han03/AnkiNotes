//
//  TTSService.swift
//  AnkiNotes
//
//  TTS 语音合成服务：支持 Edge-TTS 和 iOS 原生 TTS
//

import Foundation
import AVFoundation
import CryptoKit

// MARK: - Edge-TTS WebSocket 连接处理器

/// Edge-TTS WebSocket 连接处理器，支持为每个 task 注册独立的连接回调
final class EdgeTTSWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    /// 单例（因为 URLSession 的 delegate 在创建时设置，需要共享）
    static let shared = EdgeTTSWebSocketDelegate()
    
    /// 存储每个 task 的连接回调（key: taskIdentifier）
    private var connectionHandlers: [Int: (onConnected: () -> Void, onError: (Error) -> Void)] = [:]
    
    /// 注册 task 的连接回调
    func registerHandler(for task: URLSessionWebSocketTask, onConnected: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        connectionHandlers[task.taskIdentifier] = (onConnected, onError)
    }
    
    /// 移除 task 的连接回调
    func removeHandler(for task: URLSessionWebSocketTask) {
        connectionHandlers.removeValue(forKey: task.taskIdentifier)
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        SyncLogger.shared.info("🔊 Edge-TTS: WebSocket 连接建立成功，协议=\(`protocol` ?? "无")")
        if let handler = connectionHandlers[webSocketTask.taskIdentifier] {
            handler.onConnected()
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "无"
        SyncLogger.shared.info("🔊 Edge-TTS: WebSocket 连接关闭，code=\(closeCode.rawValue), reason=\(reasonStr)")
        connectionHandlers.removeValue(forKey: webSocketTask.taskIdentifier)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            SyncLogger.shared.info("🔊 Edge-TTS: WebSocket 任务完成（错误）- \(error.localizedDescription)")
            if let handler = connectionHandlers[task.taskIdentifier] {
                handler.onError(error)
            }
        }
        connectionHandlers.removeValue(forKey: task.taskIdentifier)
    }
}

// MARK: - Edge-TTS 常量和工具函数

private enum EdgeTTSConstants {
    static let baseURL = "speech.platform.bing.com/consumer/speech/synthesize/readaloud"
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let chromiumFullVersion = "143.0.3650.75"
    static let chromiumMajorVersion = "143"
    static let secMsGecVersion = "1-\(chromiumFullVersion)"
    static let winEpoch: Double = 11644473600
    static let sToNs: Double = 1e9
}

/// 生成 Sec-MS-GEC token（参考 edge-tts Python 库的 DRM.generate_sec_ms_gec）
private func generateSecMsGec() -> String {
    // 获取当前 Unix 时间戳
    var ticks = Date().timeIntervalSince1970
    // 转换到 Windows 文件时间纪元（1601-01-01 00:00:00 UTC）
    ticks += EdgeTTSConstants.winEpoch
    // 向下取整到最近的5分钟（300秒）
    ticks -= ticks.truncatingRemainder(dividingBy: 300)
    // 转换为100纳秒间隔（Windows 文件时间格式）
    ticks *= EdgeTTSConstants.sToNs / 100
    // 拼接时间戳和 TrustedClientToken
    let strToHash = String(format: "%.0f", ticks) + EdgeTTSConstants.trustedClientToken
    // 计算 SHA256 哈希，返回大写的十六进制摘要
    let data = Data(strToHash.utf8)
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02X", $0) }.joined()
}

/// 生成随机 MUID（32位十六进制，大写）
private func generateMuid() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02X", $0) }.joined()
}

/// 生成 RFC 2616 格式的时间戳（如 "Tue, 08 Sep 2026 22:49:32 GMT"）
private func rfc2616Timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
}

/// 解析 Edge-TTS 二进制消息，提取音频数据
/// 二进制消息格式：[2字节头部长度(大端序)][头部文本][\r\n\r\n][音频数据]
private func parseEdgeTTSBinaryMessage(_ data: Data) -> Data? {
    guard data.count >= 2 else { return nil }
    // 前2字节是头部长度（大端序）
    let headerLength = Int(data[0]) << 8 | Int(data[1])
    guard headerLength + 2 <= data.count else { return nil }
    // 跳过头部长度 + 2字节（\r\n\r\n），剩下的是音频数据
    let audioStart = headerLength + 2
    guard audioStart <= data.count else { return nil }
    return data.subdata(in: audioStart..<data.count)
}

// MARK: - TTS 配置

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
    case edgeTTS = "edge"
    case iOSNative = "ios"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .edgeTTS: return "Edge-TTS（在线，高质量）"
        case .iOSNative: return "iOS 原生（离线，系统音色）"
        }
    }
}

struct TTSConfig: Codable, Hashable {
    var provider: TTSProvider
    var edgeVoice: String       // Edge-TTS 音色
    var iOSVoice: String        // iOS 原生音色
    var rate: Double            // 语速 0.5 - 2.0
    var pitch: Double           // 音调 -50 到 +50（Edge-TTS）
    
    enum CodingKeys: CodingKey { case provider, edgeVoice, iOSVoice, rate, pitch }
    
    init(provider: TTSProvider = .edgeTTS,
         edgeVoice: String = "zh-CN-YunxiNeural",
         iOSVoice: String = "",
         rate: Double = 1.0,
         pitch: Double = 0) {
        self.provider = provider
        self.edgeVoice = edgeVoice
        self.iOSVoice = iOSVoice
        self.rate = rate
        self.pitch = pitch
    }
}

// MARK: - Edge-TTS 可用音色

enum EdgeTTSVoice: String, CaseIterable, Identifiable {
    case zhCNYunxiNeural = "zh-CN-YunxiNeural"      // 云希（男声，年轻）
    case zhCNYunyangNeural = "zh-CN-YunyangNeural"  // 云扬（男声，新闻）
    case zhCNYunjianNeural = "zh-CN-YunjianNeural"  // 云健（男声，成熟）
    case zhCNXiaoxiaoNeural = "zh-CN-XiaoxiaoNeural" // 晓晓（女声，活泼）
    case zhCNXiaoyiNeural = "zh-CN-XiaoyiNeural"    // 晓伊（女声，温柔）
    case zhCNYunxiaNeural = "zh-CN-YunxiaNeural"    // 云夏（男声，少年）
    case zhCNXiaomoNeural = "zh-CN-XiaomoNeural"    // 晓墨（女声，知性）
    case zhCNYunhaoNeural = "zh-CN-YunhaoNeural"    // 云皓（男声，浑厚）
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .zhCNYunxiNeural: return "云希（男声·年轻）"
        case .zhCNYunyangNeural: return "云扬（男声·新闻）"
        case .zhCNYunjianNeural: return "云健（男声·成熟）"
        case .zhCNXiaoxiaoNeural: return "晓晓（女声·活泼）"
        case .zhCNXiaoyiNeural: return "晓伊（女声·温柔）"
        case .zhCNYunxiaNeural: return "云夏（男声·少年）"
        case .zhCNXiaomoNeural: return "晓墨（女声·知性）"
        case .zhCNYunhaoNeural: return "云皓（男声·浑厚）"
        }
    }
}

// MARK: - TTS 服务

final class TTSService: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = TTSService()
    
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var downloadTask: URLSessionDataTask?
    
    // Edge-TTS WebSocket 相关
    private var edgeTTSWebSocketTask: URLSessionWebSocketTask?
    private var edgeTTSAudioData = Data()  // 累积 Edge-TTS 音频数据
    
    /// 共享的 URLSession（用于 Edge-TTS，复用连接池，避免每次创建新 session）
    private static let edgeTTSSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpAdditionalHeaders = [:]
        return URLSession(configuration: config, delegate: EdgeTTSWebSocketDelegate.shared, delegateQueue: OperationQueue.main)
    }()
    
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var totalSentences = 0
    @Published private(set) var currentText = ""
    
    private var sentences: [String] = []
    private var config: TTSConfig
    private var actualProvider: TTSProvider = .edgeTTS  // 实际使用的 TTS 方案（可能因降级而与 config.provider 不同）
    private var onSentenceComplete: ((Int) -> Void)?
    private var onComplete: (() -> Void)?
    private var hasReceivedAudio = false  // 跟踪是否已接收到音频数据
    private var inactivityTimerWorkItem: DispatchWorkItem?  // 不活跃超时计时器
    
    private override init() {
        self.config = TTSConfig()
        super.init()
        synthesizer.delegate = self
    }
    
    func updateConfig(_ config: TTSConfig) {
        self.config = config
        self.actualProvider = config.provider
        SyncLogger.shared.info("🔊 TTSService.updateConfig: provider=\(config.provider.displayName), rate=\(config.rate)")
    }
    
    // MARK: - 文本分句
    
    private func splitIntoSentences(_ text: String) -> [String] {
        var result: [String] = []
        let separators = CharacterSet(charactersIn: "。！？!?\n")
        var current = ""
        
        for char in text {
            current.append(char)
            if separators.contains(char.unicodeScalars.first!) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }
        return result
    }
    
    // MARK: - 播放控制
    
    func speak(text: String, onSentenceComplete: ((Int) -> Void)? = nil, onComplete: (() -> Void)? = nil) {
        stop()
        self.sentences = splitIntoSentences(text)
        self.totalSentences = sentences.count
        self.currentSentenceIndex = 0
        self.onSentenceComplete = onSentenceComplete
        self.onComplete = onComplete
        
        guard !sentences.isEmpty else {
            onComplete?()
            return
        }
        
        isSpeaking = true
        isPaused = false
        speakCurrentSentence()
    }
    
    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentences.count else {
            finishSpeaking()
            return
        }
        
        let sentence = sentences[currentSentenceIndex]
        currentText = sentence
        
        switch config.provider {
        case .edgeTTS:
            speakEdgeTTS(sentence)
        case .iOSNative:
            speakiOSNative(sentence)
        }
    }
    
    func pause() {
        guard isSpeaking else { return }
        isPaused = true
        SyncLogger.shared.info("🔊 TTSService.pause: actualProvider=\(actualProvider.displayName)")
        switch actualProvider {
        case .edgeTTS:
            audioPlayer?.pause()
        case .iOSNative:
            synthesizer.pauseSpeaking(at: .immediate)
        }
    }
    
    func resume() {
        guard isSpeaking, isPaused else { return }
        isPaused = false
        SyncLogger.shared.info("🔊 TTSService.resume: actualProvider=\(actualProvider.displayName)")
        switch actualProvider {
        case .edgeTTS:
            audioPlayer?.play()
        case .iOSNative:
            synthesizer.continueSpeaking()
        }
    }
    
    func stop() {
        isSpeaking = false
        isPaused = false
        currentSentenceIndex = 0
        totalSentences = 0
        currentText = ""
        
        switch actualProvider {
        case .edgeTTS:
            downloadTask?.cancel()
            edgeTTSWebSocketTask?.cancel()
            edgeTTSWebSocketTask = nil
            audioPlayer?.stop()
            audioPlayer = nil
            edgeTTSAudioData = Data()
        case .iOSNative:
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
    
    func skipToNext() {
        guard isSpeaking else { return }
        currentSentenceIndex += 1
        if currentSentenceIndex >= sentences.count {
            finishSpeaking()
        } else {
            stopCurrentOnly()
            speakCurrentSentence()
        }
    }
    
    func skipToPrevious() {
        guard isSpeaking, currentSentenceIndex > 0 else { return }
        currentSentenceIndex -= 1
        stopCurrentOnly()
        speakCurrentSentence()
    }
    
    private func stopCurrentOnly() {
        switch actualProvider {
        case .edgeTTS:
            downloadTask?.cancel()
            edgeTTSWebSocketTask?.cancel()
            edgeTTSWebSocketTask = nil
            audioPlayer?.stop()
            audioPlayer = nil
            edgeTTSAudioData = Data()
        case .iOSNative:
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
    
    private func finishSpeaking() {
        isSpeaking = false
        isPaused = false
        currentText = ""
        onComplete?()
    }
    
    private func sentenceFinished() {
        onSentenceComplete?(currentSentenceIndex)
        currentSentenceIndex += 1
        if currentSentenceIndex >= sentences.count {
            finishSpeaking()
        } else {
            speakCurrentSentence()
        }
    }
    
    // MARK: - iOS 原生 TTS
    
    private func speakiOSNative(_ text: String) {
        actualProvider = .iOSNative
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(config.rate * 0.5) // AVSpeech 正常语速约 0.5
        utterance.pitchMultiplier = 1.0
        
        if !config.iOSVoice.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: config.iOSVoice)
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        
        synthesizer.speak(utterance)
    }
    
    // MARK: - Edge-TTS (WebSocket)
    
    /// 降级到 iOS 原生 TTS
    private func fallbackToiOSNative(text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            SyncLogger.shared.info("🔊 Edge-TTS: 降级到 iOS 原生 TTS")
            self.actualProvider = .iOSNative
            self.speakiOSNative(text)
        }
    }
    
    private func speakEdgeTTS(_ text: String) {
        actualProvider = .edgeTTS
        let ssml = buildSSML(text: text)
        
        // 取消之前的任务
        downloadTask?.cancel()
        edgeTTSWebSocketTask?.cancel()
        edgeTTSWebSocketTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        edgeTTSAudioData = Data()
        hasReceivedAudio = false
        inactivityTimerWorkItem?.cancel()
        inactivityTimerWorkItem = nil
        
        // 生成连接 ID 和请求 ID（不带连字符的全小写 UUID，与 Python edge-tts 库一致）
        let connectionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let requestId = connectionId
        
        // 生成 Sec-MS-GEC token（与 Python edge-tts 库的 DRM.generate_sec_ms_gec 算法完全一致）
        let secMsGec = generateSecMsGec()
        
        // 构建完整的 WebSocket URL（包含所有必要的参数，与 Python edge-tts 库一致）
        let urlString = "wss://\(EdgeTTSConstants.baseURL)/edge/v1" +
            "?TrustedClientToken=\(EdgeTTSConstants.trustedClientToken)" +
            "&ConnectionId=\(connectionId)" +
            "&Sec-MS-GEC=\(secMsGec)" +
            "&Sec-MS-GEC-Version=\(EdgeTTSConstants.secMsGecVersion)"
        
        guard let url = URL(string: urlString) else {
            SyncLogger.shared.info("🔊 Edge-TTS: URL 无效，降级到 iOS 原生")
            fallbackToiOSNative(text: text)
            return
        }
        
        SyncLogger.shared.info("🔊 Edge-TTS: connectionId=\(connectionId)")
        SyncLogger.shared.info("🔊 Edge-TTS: Sec-MS-GEC=\(secMsGec)")
        SyncLogger.shared.info("🔊 Edge-TTS: URL=\(urlString)")
        
        // 构建请求（请求头与 Python edge-tts 库的 WSS_HEADERS + headers_with_muid 完全一致）
        var request = URLRequest(url: url)
        // User-Agent：与 Python edge-tts 库的 BASE_HEADERS 一致
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" +
            " (KHTML, like Gecko) Chrome/\(EdgeTTSConstants.chromiumMajorVersion).0.0.0 Safari/537.36" +
            " Edg/\(EdgeTTSConstants.chromiumMajorVersion).0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        // Origin：必须是 Chrome 扩展 ID（与 Python edge-tts 库一致）
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        // Accept-Encoding：与 Python edge-tts 库一致
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "Accept-Encoding")
        // Accept-Language：与 Python edge-tts 库一致
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Pragma / Cache-Control：与 Python edge-tts 库一致
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // 注意：不手动设置 Sec-WebSocket-Version，由 URLSession 自动设置（手动设置可能冲突）
        // Cookie：包含随机的 muid（与 Python edge-tts 库的 DRM.headers_with_muid 一致）
        request.setValue("muid=\(generateMuid());", forHTTPHeaderField: "Cookie")
        
        // 使用共享的 URLSession 创建 WebSocket task（复用连接池）
        let task = TTSService.edgeTTSSession.webSocketTask(with: request)
        edgeTTSWebSocketTask = task
        
        let speechConfigMessage = buildSpeechConfigMessage(requestId: requestId)
        let ssmlMessage = buildSSMLMessage(requestId: requestId, ssml: ssml)
        
        // 注册连接回调：连接建立成功后发送消息，连接失败时降级
        EdgeTTSWebSocketDelegate.shared.registerHandler(
            for: task,
            onConnected: { [weak self] in
                guard let self = self else { return }
                SyncLogger.shared.info("🔊 Edge-TTS: 连接已建立，开始发送消息")
                
                // 发送 speech.config 消息
                task.send(.string(speechConfigMessage)) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        SyncLogger.shared.info("🔊 Edge-TTS: 发送 speech.config 失败 - \(error.localizedDescription)")
                        self.fallbackToiOSNative(text: text)
                        return
                    }
                    
                    SyncLogger.shared.info("🔊 Edge-TTS: speech.config 发送成功")
                    
                    // 发送 ssml 消息
                    task.send(.string(ssmlMessage)) { [weak self] error in
                        guard let self = self else { return }
                        if let error = error {
                            SyncLogger.shared.info("🔊 Edge-TTS: 发送 ssml 失败 - \(error.localizedDescription)")
                            self.fallbackToiOSNative(text: text)
                            return
                        }
                        
                        SyncLogger.shared.info("🔊 Edge-TTS: ssml 发送成功，SSML前100字=\(String(ssml.prefix(100)))")
                        SyncLogger.shared.info("🔊 Edge-TTS: 消息已发送，开始接收音频数据...")
                        // 开始接收消息
                        self.receiveEdgeTTSMessages(task: task, originalText: text)
                    }
                }
            },
            onError: { [weak self] error in
                guard let self = self else { return }
                SyncLogger.shared.info("🔊 Edge-TTS: 连接失败 - \(error.localizedDescription)，降级到 iOS 原生")
                self.fallbackToiOSNative(text: text)
            }
        )
        
        task.resume()
        
        SyncLogger.shared.info("🔊 Edge-TTS: 已创建 WebSocket task，正在建立连接... requestId=\(requestId)")
        SyncLogger.shared.info("🔊 Edge-TTS: 等待 didOpenWithProtocol 回调后发送消息")
        
        // 设置连接超时（15秒内未建立连接则降级）
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self else { return }
            // 如果已经降级或任务已更换，不再处理
            guard self.actualProvider == .edgeTTS, self.edgeTTSWebSocketTask === task else {
                SyncLogger.shared.info("🔊 Edge-TTS: 连接超时检查跳过 - provider=\(self.actualProvider), taskMatch=\(self.edgeTTSWebSocketTask === task)")
                return
            }
            if task.state != .running {
                // WebSocket 未连接，降级
                SyncLogger.shared.info("🔊 Edge-TTS: 连接建立超时（15秒），task.state=\(task.state.rawValue)，降级到 iOS 原生")
                task.cancel()
                EdgeTTSWebSocketDelegate.shared.removeHandler(for: task)
                self.fallbackToiOSNative(text: text)
            } else {
                // 连接已建立，启动不活跃超时计时器
                SyncLogger.shared.info("🔊 Edge-TTS: 连接已建立，启动不活跃超时计时器")
                self.resetInactivityTimer(task: task, originalText: text)
            }
        }
    }
    
    /// 构建 speech.config 消息（参考 edge-tts Python 库的 send_command_request，完全一致）
    private func buildSpeechConfigMessage(requestId: String) -> String {
        let timestamp = rfc2616Timestamp()
        // os 信息必须与 User-Agent 一致（Windows/Edge）
        // 注意：JSON 后面必须有 \r\n，与 Python edge-tts 库完全一致
        let configJSON = """
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
        """
        return "X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(configJSON)\r\n"
    }
    
    /// 构建 ssml 消息（参考 edge-tts Python 库的 ssml_headers_plus_data）
    private func buildSSMLMessage(requestId: String, ssml: String) -> String {
        let timestamp = rfc2616Timestamp()
        return "X-Timestamp:\(timestamp)\r\nContent-Type:application/ssml+xml\r\nX-RequestId:\(requestId)\r\nPath:ssml\r\n\r\n\(ssml)"
    }
    
    /// 重置不活跃超时计时器（收到音频数据时调用）
    private func resetInactivityTimer(task: URLSessionWebSocketTask, originalText: String) {
        // 取消之前的计时器
        inactivityTimerWorkItem?.cancel()
        
        // 创建新的计时器
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // 如果已经降级或任务已更换，不再处理
            guard self.actualProvider == .edgeTTS, self.edgeTTSWebSocketTask === task else { return }
            if !self.hasReceivedAudio {
                SyncLogger.shared.info("🔊 Edge-TTS: 15秒内未收到音频数据，降级到 iOS 原生")
                task.cancel()
                EdgeTTSWebSocketDelegate.shared.removeHandler(for: task)
                self.fallbackToiOSNative(text: originalText)
            }
        }
        
        inactivityTimerWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }
    
    /// 循环接收 Edge-TTS 消息
    private func receiveEdgeTTSMessages(task: URLSessionWebSocketTask, originalText: String) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            
            // 检查任务是否已被取消
            if task.state == .canceling || task.state == .completed {
                return
            }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    // 解析文本消息
                    SyncLogger.shared.info("🔊 Edge-TTS: 收到文本消息，大小=\(text.count)字符，前100字=\(String(text.prefix(100)))")
                    if text.contains("Path: turn.end") {
                        // 合成结束，播放累积的音频数据
                        SyncLogger.shared.info("🔊 Edge-TTS: 合成结束，累积音频数据大小=\(self.edgeTTSAudioData.count)字节")
                        if !self.edgeTTSAudioData.isEmpty {
                            self.playEdgeTTSAudio()
                        } else {
                            SyncLogger.shared.info("🔊 Edge-TTS: 未收到音频数据，降级到 iOS 原生")
                            self.fallbackToiOSNative(text: originalText)
                        }
                        return
                    } else if text.contains("Path: turn.start") {
                        SyncLogger.shared.info("🔊 Edge-TTS: 开始合成")
                    } else if text.contains("Path: response.end") {
                        SyncLogger.shared.info("🔊 Edge-TTS: 响应结束")
                    }
                    // 其他文本消息（audio.metadata 等）忽略
                    
                case .data(let data):
                    // Edge-TTS 二进制消息格式：[2字节头部长度(大端序)][头部文本][音频数据]
                    guard let audioData = parseEdgeTTSBinaryMessage(data) else {
                        SyncLogger.shared.info("🔊 Edge-TTS: 收到无效的二进制消息，大小=\(data.count)字节")
                        break
                    }
                    if !audioData.isEmpty {
                        self.hasReceivedAudio = true
                        // 累积音频数据
                        self.edgeTTSAudioData.append(audioData)
                        // 重置不活跃超时计时器
                        self.resetInactivityTimer(task: task, originalText: originalText)
                        // 每收到10个音频包记录一次日志
                        if self.edgeTTSAudioData.count % 7200 < 720 {
                            SyncLogger.shared.info("🔊 Edge-TTS: 累积音频数据=\(self.edgeTTSAudioData.count)字节，本次=\(audioData.count)字节，前8字节=\(audioData.prefix(8).map { String(format: "%02X", $0) }.joined())")
                        }
                    }
                }
                
                // 继续接收下一条消息
                self.receiveEdgeTTSMessages(task: task, originalText: originalText)
                
            case .failure(let error):
                SyncLogger.shared.info("🔊 Edge-TTS: 接收消息失败 - \(error.localizedDescription)")
                if !self.edgeTTSAudioData.isEmpty {
                    // 已接收到音频数据，尝试播放
                    SyncLogger.shared.info("🔊 Edge-TTS: 接收失败但已有音频数据（\(self.edgeTTSAudioData.count)字节），尝试播放")
                    self.playEdgeTTSAudio()
                } else {
                    // 未接收到音频数据，降级
                    DispatchQueue.main.async {
                        self.actualProvider = .iOSNative
                        self.speakiOSNative(originalText)
                    }
                }
            }
        }
    }
    
    /// 播放累积的 Edge-TTS 音频数据
    private func playEdgeTTSAudio() {
        let data = edgeTTSAudioData
        SyncLogger.shared.info("🔊 Edge-TTS: 准备播放音频，数据大小=\(data.count)字节，前16字节=\(data.prefix(16).map { String(format: "%02X", $0) }.joined())")
        
        do {
            // 设置 AVAudioSession
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [])
            try audioSession.setActive(true)
            
            // 创建 AVAudioPlayer
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            SyncLogger.shared.info("🔊 Edge-TTS: AVAudioPlayer 创建成功，时长=\(audioPlayer?.duration ?? 0)秒")
            
            let started = audioPlayer?.play() ?? false
            SyncLogger.shared.info("🔊 Edge-TTS: 音频播放开始，结果=\(started)")
            
            if !started {
                SyncLogger.shared.info("🔊 Edge-TTS: 播放失败，降级到 iOS 原生")
                fallbackToiOSNative(text: currentText)
            }
        } catch {
            SyncLogger.shared.info("🔊 Edge-TTS: 播放失败 - \(error.localizedDescription)，降级到 iOS 原生")
            fallbackToiOSNative(text: currentText)
        }
    }
    
    private func buildSSML(text: String) -> String {
        let ratePercent = Int((config.rate - 1.0) * 100)
        let rateStr = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let pitchHz = config.pitch
        let pitchStr = pitchHz >= 0 ? "+\(pitchHz)Hz" : "\(pitchHz)Hz"
        
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        
        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN">
            <voice name="\(config.edgeVoice)">
                <prosody rate="\(rateStr)" pitch="\(pitchStr)">
                    \(escapedText)
                </prosody>
            </voice>
        </speak>
        """
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard isSpeaking, !isPaused else { return }
        sentenceFinished()
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        SyncLogger.shared.info("🔊 Edge-TTS: audioPlayerDidFinishPlaying, flag=\(flag)")
        guard isSpeaking, !isPaused else { return }
        if flag {
            sentenceFinished()
        } else {
            SyncLogger.shared.info("🔊 Edge-TTS: 音频播放未成功完成")
        }
    }
}
