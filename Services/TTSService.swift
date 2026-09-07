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
    
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var totalSentences = 0
    @Published private(set) var currentText = ""
    
    private var sentences: [String] = []
    private var config: TTSConfig
    private var onSentenceComplete: ((Int) -> Void)?
    private var onComplete: (() -> Void)?
    
    private override init() {
        self.config = TTSConfig()
        super.init()
        synthesizer.delegate = self
    }
    
    func updateConfig(_ config: TTSConfig) {
        self.config = config
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
        switch config.provider {
        case .edgeTTS:
            audioPlayer?.pause()
        case .iOSNative:
            synthesizer.pauseSpeaking(at: .word)
        }
    }
    
    func resume() {
        guard isSpeaking, isPaused else { return }
        isPaused = false
        switch config.provider {
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
        
        switch config.provider {
        case .edgeTTS:
            downloadTask?.cancel()
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
        switch config.provider {
        case .edgeTTS:
            downloadTask?.cancel()
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
    
    // MARK: - Edge-TTS
    
    private func speakEdgeTTS(_ text: String) {
        let ssml = buildSSML(text: text)
        downloadTask?.cancel()
        
        // Edge-TTS WebSocket URL
        let urlString = "https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        
        // 使用 HTTP POST 方式获取音频（简化实现）
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("ringtone", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.httpBody = ssml.data(using: .utf8)
        
        downloadTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }
            
            guard let data = data, !data.isEmpty else {
                // Edge-TTS HTTP 方式可能不工作，降级到 iOS 原生
                DispatchQueue.main.async {
                    self.speakiOSNative(text)
                }
                return
            }
            
            DispatchQueue.main.async {
                self.playAudio(data: data)
            }
        }
        downloadTask?.resume()
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
            if let sentence = currentText.isEmpty ? sentences[currentSentenceIndex] : currentText {
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
