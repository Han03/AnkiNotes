//
//  TTSService.swift
//  AnkiNotes
//
//  TTS 语音合成服务：支持 Edge-TTS 和 iOS 原生 TTS
//

import Foundation
import AVFoundation

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

final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSService()
    
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var downloadTask: URLSessionDataTask?
    
    // Edge-TTS WebSocket 相关
    private var edgeTTSWebSocketTask: URLSessionWebSocketTask?
    private var edgeTTSAudioData = Data()
    
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
            synthesizer.pauseSpeaking(at: .immediate)  // 使用 .immediate 立即暂停，而不是 .word
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
            edgeTTSAudioData = Data()
            audioPlayer?.stop()
            audioPlayer = nil
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
            edgeTTSAudioData = Data()
            audioPlayer?.stop()
            audioPlayer = nil
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
    
    private func speakEdgeTTS(_ text: String) {
        actualProvider = .edgeTTS
        let ssml = buildSSML(text: text)
        
        // 取消之前的任务
        downloadTask?.cancel()
        edgeTTSWebSocketTask?.cancel()
        edgeTTSWebSocketTask = nil
        edgeTTSAudioData = Data()
        
        // Edge-TTS WebSocket URL
        let urlString = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        guard let url = URL(string: urlString) else {
            SyncLogger.shared.info("🔊 Edge-TTS: URL 无效，降级到 iOS 原生")
            actualProvider = .iOSNative
            speakiOSNative(text)
            return
        }
        
        let requestId = UUID().uuidString
        let task = URLSession.shared.webSocketTask(with: url)
        edgeTTSWebSocketTask = task
        task.resume()
        
        SyncLogger.shared.info("🔊 Edge-TTS: 正在建立 WebSocket 连接...")
        
        // 发送 speech.config 消息
        let speechConfigMessage = buildSpeechConfigMessage(requestId: requestId)
        task.send(.string(speechConfigMessage)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                SyncLogger.shared.info("🔊 Edge-TTS: 发送 speech.config 失败 - \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.actualProvider = .iOSNative
                    self.speakiOSNative(text)
                }
                return
            }
            
            // 发送 ssml 消息
            let ssmlMessage = buildSSMLMessage(requestId: requestId, ssml: ssml)
            task.send(.string(ssmlMessage)) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    SyncLogger.shared.info("🔊 Edge-TTS: 发送 ssml 失败 - \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.actualProvider = .iOSNative
                        self.speakiOSNative(text)
                    }
                    return
                }
                
                SyncLogger.shared.info("🔊 Edge-TTS: 消息已发送，开始接收音频数据...")
                // 开始接收消息
                self.receiveEdgeTTSMessages(task: task, originalText: text)
            }
        }
    }
    
    /// 构建 speech.config 消息
    private func buildSpeechConfigMessage(requestId: String) -> String {
        let configJSON = """
        {"context":{"system":{"name":"SpeechSDK","version":"1.12.1-rc.1","build":"JavaScript","lang":"JavaScript","os":{"platform":"Browser/Linux x86_64","name":"Mozilla/5.0 (X11; Linux x86_64; rv:78.0) Gecko/20100101 Firefox/78.0","version":"5.0"}}}}
        """
        return "Path: speech.config\r\nX-RequestId: \(requestId)\r\nContent-Type: application/json\r\n\r\n\(configJSON)"
    }
    
    /// 构建 ssml 消息
    private func buildSSMLMessage(requestId: String, ssml: String) -> String {
        return "Path: ssml\r\nX-RequestId: \(requestId)\r\nContent-Type: application/ssml+xml\r\n\r\n\(ssml)"
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
                    if text.contains("Path: turn.end") {
                        // 合成结束，播放音频
                        SyncLogger.shared.info("🔊 Edge-TTS: 合成结束，音频大小 \(self.edgeTTSAudioData.count) 字节")
                        DispatchQueue.main.async {
                            if !self.edgeTTSAudioData.isEmpty {
                                self.playAudio(data: self.edgeTTSAudioData)
                            } else {
                                SyncLogger.shared.info("🔊 Edge-TTS: 音频数据为空，降级到 iOS 原生")
                                self.actualProvider = .iOSNative
                                self.speakiOSNative(originalText)
                            }
                        }
                        return
                    } else if text.contains("Path: turn.start") {
                        SyncLogger.shared.info("🔊 Edge-TTS: 开始合成")
                    }
                    // 其他文本消息（audio.metadata 等）忽略
                    
                case .data(let data):
                    // 音频数据，累积起来
                    self.edgeTTSAudioData.append(data)
                    if self.edgeTTSAudioData.count % 10000 < 1000 {
                        SyncLogger.shared.info("🔊 Edge-TTS: 已接收音频数据 \(self.edgeTTSAudioData.count) 字节")
                    }
                }
                
                // 继续接收下一条消息
                self.receiveEdgeTTSMessages(task: task, originalText: originalText)
                
            case .failure(let error):
                SyncLogger.shared.info("🔊 Edge-TTS: 接收消息失败 - \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if !self.edgeTTSAudioData.isEmpty {
                        // 即使失败了，如果有已接收的音频数据，也尝试播放
                        SyncLogger.shared.info("🔊 Edge-TTS: 接收失败但有部分音频数据，尝试播放 \(self.edgeTTSAudioData.count) 字节")
                        self.playAudio(data: self.edgeTTSAudioData)
                    } else {
                        self.actualProvider = .iOSNative
                        self.speakiOSNative(originalText)
                    }
                }
            }
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
    
    private func playAudio(data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            // 播放失败，降级到 iOS 原生
            SyncLogger.shared.info("🔊 TTSService: Edge-TTS 播放失败，降级到 iOS 原生")
            actualProvider = .iOSNative
            let sentence = currentText.isEmpty ? (currentSentenceIndex < sentences.count ? sentences[currentSentenceIndex] : "") : currentText
            if !sentence.isEmpty {
                speakiOSNative(sentence)
            }
        }
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard isSpeaking, !isPaused else { return }
        sentenceFinished()
    }
}

// MARK: - AVAudioPlayerDelegate

extension TTSService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard isSpeaking, !isPaused else { return }
        sentenceFinished()
    }
}
