//
//  TTSService.swift
//  AnkiNotes
//
//  TTS 语音合成服务：支持 Edge-TTS 和 iOS 原生 TTS
//

import Foundation
import AVFoundation
import CryptoKit
import MediaPlayer


// MARK: - TTS 配置

enum TTSProvider: String, Codable, CaseIterable, Identifiable {
    case edgeTTSService = "edge_service"  // Edge-TTS HTTP 服务
    case iOSNative = "ios"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .edgeTTSService: return "Edge-TTS（在线，高质量）"
        case .iOSNative: return "iOS 原生（离线，系统音色）"
        }
    }
    
    // 兼容旧数据：旧版本的 edgeTTS("edge") 映射为 edgeTTSService
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "edge" {
            self = .edgeTTSService
        } else if let provider = TTSProvider(rawValue: rawValue) {
            self = provider
        } else {
            self = .edgeTTSService
        }
    }
}

struct TTSConfig: Codable, Hashable {
    var provider: TTSProvider
    var edgeVoice: String       // Edge-TTS 音色
    var iOSVoice: String        // iOS 原生音色
    var rate: Double            // 语速 0.5 - 2.0
    var pitch: Double           // 音调 -50 到 +50（Edge-TTS）
    var serviceURL: String      // Edge-TTS 服务 URL（Cloudflare Workers）
    
    enum CodingKeys: CodingKey { case provider, edgeVoice, iOSVoice, rate, pitch, serviceURL }
    
    init(provider: TTSProvider = .edgeTTSService,
         edgeVoice: String = "zh-CN-YunxiNeural",
         iOSVoice: String = "",
         rate: Double = 1.0,
         pitch: Double = 0,
         serviceURL: String = "https://tts.maxh.ccwu.cc") {
        self.provider = provider
        self.edgeVoice = edgeVoice
        self.iOSVoice = iOSVoice
        self.rate = rate
        self.pitch = pitch
        self.serviceURL = serviceURL
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
    
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false  // 是否正在下载音频
    @Published private(set) var currentSentenceIndex = 0
    @Published private(set) var totalSentences = 0
    @Published private(set) var currentText = ""
    
    @Published public private(set) var sentences: [String] = []
    private var config: TTSConfig
    private var onSentenceComplete: ((Int) -> Void)?
    private var onComplete: (() -> Void)?
    
    // MARK: - 音频预缓存
    private var audioCache: [Int: Data] = [:]  // 句子索引 -> 音频数据
    private var preloadTask: URLSessionDataTask?  // 预下载任务（保留兼容）
    private var preloadTasks: [Int: URLSessionDataTask] = [:]  // 多句预下载任务管理
    private var pendingPlayIndex: Int?  // 暂停时下载完成，待播放的句子索引
    
    // MARK: - 后台音频保活
    private var isAudioSessionActive = false  // 音频会话是否已激活
    private var isRemoteCommandSetup = false  // 远程控制是否已注册（避免重复注册）
    private var interruptionObserver: NSObjectProtocol?  // 音频中断通知观察者
    
    private override init() {
        self.config = TTSConfig()
        super.init()
        synthesizer.delegate = self
        setupAudioInterruptionHandling()
    }
    
    func updateConfig(_ config: TTSConfig) {
        let oldRate = self.config.rate
        self.config = config
        SyncLogger.shared.info("🔊 TTSService.updateConfig: provider=\(config.provider.displayName), rate=\(config.rate)")
        
        // 【新增】如果正在播放 Edge-TTS 且语速变化，实时调整播放速度
        // 因为 TTS 合成时使用默认语速，播放时通过 AVAudioPlayer.rate 后处理
        if oldRate != config.rate, let player = audioPlayer, player.isPlaying {
            player.rate = Float(config.rate)
            SyncLogger.shared.info("🔊 实时调整播放速度: \(oldRate)x -> \(config.rate)x")
        }
    }
    
    // MARK: - 文本分句
    
    /// 将文本分句（公开静态方法，供视图层使用以确保分句一致）
    public static func splitIntoSentences(_ text: String) -> [String] {
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
    
    /// 播放讲稿文本
    /// - Parameters:
    ///   - lecturePath: 讲稿相对路径（如 "JAVA高级/01-Java核心/IO与NIO"），用于TTS缓存按讲稿目录分层存储
    ///   - startSentenceIndex: 从指定句子索引开始播放（用于跳转播放，避免对子文本重新分句导致索引不一致）
    func speak(text: String, lecturePath: String? = nil, startSentenceIndex: Int = 0, onSentenceComplete: ((Int) -> Void)? = nil, onComplete: (() -> Void)? = nil) {
        stop()
        self.sentences = Self.splitIntoSentences(text)
        self.totalSentences = sentences.count
        self.currentSentenceIndex = min(max(startSentenceIndex, 0), max(sentences.count - 1, 0))
        self.onSentenceComplete = onSentenceComplete
        self.onComplete = onComplete
        self.audioCache = [:]
        self.pendingPlayIndex = nil
        
        // 设置TTS缓存的讲稿路径上下文（按讲稿目录分层存储）
        TTSCacheManager.shared.setLecturePath(lecturePath)
        
        SyncLogger.shared.info("🔊 speak: 开始播放，共\(sentences.count)句，起始=\(currentSentenceIndex)，provider=\(config.provider.displayName)，lecturePath=\(lecturePath ?? "nil")")
        
        guard !sentences.isEmpty else {
            onComplete?()
            return
        }
        
        isSpeaking = true
        isPaused = false
        
        // 后台音频保活准备：激活音频会话、注册远程控制
        prepareForBackgroundPlayback()
        
        speakCurrentSentence()
    }
    
    private func speakCurrentSentence() {
        guard currentSentenceIndex < sentences.count else {
            finishSpeaking()
            return
        }
        
        // 检查暂停状态：如果已暂停，不自动播放，记录待播放索引
        guard !isPaused else {
            SyncLogger.shared.info("🔊 speakCurrentSentence: 已暂停，跳过自动播放，index=\(currentSentenceIndex)")
            pendingPlayIndex = currentSentenceIndex
            return
        }
        
        let sentence = sentences[currentSentenceIndex]
        currentText = sentence
        
        SyncLogger.shared.info("🔊 speakCurrentSentence: index=\(currentSentenceIndex)/\(sentences.count), provider=\(config.provider.displayName)")
        
        // iOS 原生 TTS 不需要缓存，直接播放
        guard config.provider == .edgeTTSService else {
            isLoading = true
            speakiOSNative(sentence)
            isLoading = false
            return
        }
        
        // 计算缓存 key（不包含语速，语速通过播放时后处理实现）
        let cacheKey = TTSCacheManager.shared.cacheKey(
            for: sentence,
            voice: config.edgeVoice,
            pitch: Int(config.pitch)
        )
        
        // 一级缓存：内存缓存（audioCache，按索引存储，快速访问）
        if let cachedData = audioCache[currentSentenceIndex] {
            SyncLogger.shared.info("🔊 speakCurrentSentence: 内存命中，直接播放，index=\(currentSentenceIndex)")
            playAudioData(cachedData)
            preloadNextSentence()
            return
        }
        
        // 二级缓存：磁盘缓存（TTSCacheManager）
        isLoading = true
        TTSCacheManager.shared.getCache(forKey: cacheKey) { [weak self] cachedData in
            guard let self = self else { return }
            
            // 检查是否还是同一句子（可能用户已经切换了句子）
            guard self.currentSentenceIndex < self.sentences.count,
                  self.sentences[self.currentSentenceIndex] == sentence else {
                SyncLogger.shared.info("🔊 speakCurrentSentence: 缓存返回时句子已切换，忽略")
                return
            }
            
            if let data = cachedData {
                SyncLogger.shared.info("🔊 speakCurrentSentence: 磁盘命中，播放并写入内存缓存，index=\(self.currentSentenceIndex)")
                self.audioCache[self.currentSentenceIndex] = data
                self.playAudioData(data)
                self.preloadNextSentence()
            } else {
                // 缓存未命中，需要网络下载
                SyncLogger.shared.info("🔊 speakCurrentSentence: 缓存未命中，开始网络下载，index=\(self.currentSentenceIndex)")
                self.speakEdgeTTSService(sentence)
            }
        }
    }
    
    /// 播放音频数据（统一入口）
    private func playAudioData(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 再次检查暂停状态
            guard !self.isPaused else {
                SyncLogger.shared.info("🔊 playAudioData: 已暂停，不播放")
                self.pendingPlayIndex = self.currentSentenceIndex
                return
            }
            do {
                self.audioPlayer?.stop()
                self.audioPlayer = try AVAudioPlayer(data: data)
                self.audioPlayer?.delegate = self
                
                // 【新增】启用变速播放，语速通过播放时后处理实现
                // TTS 合成时始终使用默认语速 1.0，播放时根据用户设置变速
                self.audioPlayer?.enableRate = true
                self.audioPlayer?.rate = Float(self.config.rate)
                
                self.audioPlayer?.prepareToPlay()
                self.audioPlayer?.play()
                self.isLoading = false
                // 更新锁屏/控制中心的现在播放信息
                self.updateNowPlayingInfo()
                SyncLogger.shared.info("🔊 playAudioData: 开始播放，index=\(self.currentSentenceIndex)，语速=\(self.config.rate)x")
            } catch {
                SyncLogger.shared.warning("🔊 playAudioData: 播放失败 - \(error.localizedDescription)，跳过当前句子")
                self.isLoading = false
                self.sentenceFinished()
            }
        }
    }
    
    /// 预下载接下来的10句音频（后台播放保活优化：确保熄屏后有足够缓存连续播放）
    private func preloadNextSentence() {
        guard config.provider == .edgeTTSService else { return }
        
        let preloadCount = 10  // 预下载接下来的10句
        var startedCount = 0
        var skippedCacheCount = 0
        
        for offset in 1...preloadCount {
            let targetIndex = currentSentenceIndex + offset
            guard targetIndex < sentences.count else { break }
            
            // 内存已缓存，跳过
            guard audioCache[targetIndex] == nil else { continue }
            // 正在下载，跳过
            guard preloadTasks[targetIndex] == nil else { continue }
            
            // 【优化】检查磁盘缓存，已缓存的不需要网络下载
            let sentence = sentences[targetIndex]
            let cacheKey = TTSCacheManager.shared.cacheKey(
                for: sentence,
                voice: config.edgeVoice,
                pitch: Int(config.pitch)
            )
            guard !TTSCacheManager.shared.hasDiskCache(forKey: cacheKey) else {
                skippedCacheCount += 1
                continue
            }
            
            // 开始预下载
            startedCount += 1
            preloadSentence(at: targetIndex)
        }
        
        if startedCount > 0 || skippedCacheCount > 0 {
            SyncLogger.shared.info("🔊 preloadNextSentence: 启动 \(startedCount) 个预下载，跳过磁盘缓存 \(skippedCacheCount) 个（当前句=\(currentSentenceIndex)，预下载接下来\(preloadCount)句）")
        }
    }
    
    /// 预下载指定索引的句子音频
    private func preloadSentence(at index: Int) {
        guard index < sentences.count else { return }
        guard audioCache[index] == nil else { return }
        guard preloadTasks[index] == nil else { return }
        
        let sentence = sentences[index]
        let serviceURL = config.serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceURL.isEmpty, let url = URL(string: "\(serviceURL)/v1/audio/speech") else { return }
        
        let body: [String: Any] = [
            "input": sentence,
            "voice": config.edgeVoice,
            "speed": 1.0,  // 合成时始终使用默认语速，语速通过播放时后处理实现
            "pitch": "\(Int(config.pitch))",
            "style": "general",
            "volume": "0"
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch { return }
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            // 下载完成后从任务字典中移除
            defer {
                DispatchQueue.main.async {
                    self.preloadTasks.removeValue(forKey: index)
                }
            }
            
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let audioData = data, !audioData.isEmpty else {
                SyncLogger.shared.warning("🔊 preloadSentence: 预下载失败，index=\(index)")
                return
            }
            
            // 写入内存缓存
            self.audioCache[index] = audioData
            
            // 【新增】写入磁盘缓存（持久化，下次播放直接使用）
            TTSCacheManager.shared.setDiskCache(
                audioData,
                forKey: TTSCacheManager.shared.cacheKey(
                    for: sentence,
                    voice: self.config.edgeVoice,
                    pitch: Int(self.config.pitch)
                ),
                sentence: sentence,
                voice: self.config.edgeVoice,
                pitch: Int(self.config.pitch)
            )
            
            SyncLogger.shared.info("🔊 preloadSentence: 预下载成功，index=\(index)，大小=\(audioData.count)字节")
        }
        
        preloadTasks[index] = task
        task.resume()
    }
    
    func pause() {
        guard isSpeaking else { return }
        guard !isPaused else { return }
        isPaused = true
        pendingPlayIndex = nil
        // 更新锁屏/控制中心的播放状态（暂停）
        updateNowPlayingInfo()
        SyncLogger.shared.info("🔊 TTSService.pause: provider=\(config.provider.displayName)")
        switch config.provider {
        case .edgeTTSService:
            audioPlayer?.pause()
            // 不取消 downloadTask，让下载完成后缓存起来
        case .iOSNative:
            synthesizer.pauseSpeaking(at: .immediate)
        }
    }
    
    func resume() {
        guard isSpeaking, isPaused else { return }
        isPaused = false
        // 更新锁屏/控制中心的播放状态（播放中）
        updateNowPlayingInfo()
        SyncLogger.shared.info("🔊 TTSService.resume: provider=\(config.provider.displayName)")
        
        // 如果有待播放的句子（暂停时下载完成的），直接播放
        if let pendingIndex = pendingPlayIndex {
            SyncLogger.shared.info("🔊 TTSService.resume: 播放待播放句子，index=\(pendingIndex)")
            pendingPlayIndex = nil
            currentSentenceIndex = pendingIndex
            currentText = sentences[pendingIndex]
            if let cachedData = audioCache[pendingIndex] {
                playAudioData(cachedData)
                preloadNextSentence()
            } else {
                speakCurrentSentence()
            }
            return
        }
        
        switch config.provider {
        case .edgeTTSService:
            // 如果 audioPlayer 存在且已准备好，直接继续播放
            if audioPlayer != nil {
                // 【新增】恢复播放时重新设置语速，确保使用最新的语速配置
                audioPlayer?.rate = Float(config.rate)
                audioPlayer?.play()
            } else {
                // 否则重新播放当前句子
                speakCurrentSentence()
            }
        case .iOSNative:
            synthesizer.continueSpeaking()
        }
    }
    
    func stop() {
        isSpeaking = false
        isPaused = false
        isLoading = false
        currentSentenceIndex = 0
        totalSentences = 0
        currentText = ""
        pendingPlayIndex = nil
        
        // 取消所有下载任务
        downloadTask?.cancel()
        downloadTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        // 取消所有多句预下载任务
        for (_, task) in preloadTasks {
            task.cancel()
        }
        preloadTasks.removeAll()
        
        // 清理缓存（保留是为了下次播放，但这里 stop 是完全停止，所以清理）
        // audioCache = [:]  // 不清理，下次播放相同文本时可以复用
        
        switch config.provider {
        case .edgeTTSService:
            audioPlayer?.stop()
            audioPlayer = nil
        case .iOSNative:
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        // 停止播放后清理远程控制中心和音频会话
        clearNowPlayingInfo()
        deactivateAudioSessionIfNeeded()
    }
    
    // MARK: - 后台音频保活
    
    /// 激活音频会话（播放前调用）
    private func activateAudioSessionIfNeeded() {
        guard !isAudioSessionActive else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [])
            try audioSession.setActive(true)
            isAudioSessionActive = true
            SyncLogger.shared.info("🔊 音频会话已激活（后台播放模式）")
        } catch {
            SyncLogger.shared.warning("🔊 音频会话激活失败: \(error.localizedDescription)")
        }
    }
    
    /// 取消激活音频会话（停止播放后调用，允许其他应用播放音频）
    private func deactivateAudioSessionIfNeeded() {
        guard isAudioSessionActive else { return }
        // 只有在完全停止播放时才取消激活，暂停时保持激活以便快速恢复
        guard !isSpeaking else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isAudioSessionActive = false
            SyncLogger.shared.info("🔊 音频会话已取消激活")
        } catch {
            SyncLogger.shared.warning("🔊 音频会话取消激活失败: \(error.localizedDescription)")
        }
    }
    
    /// 设置音频中断处理（来电、闹钟、其他应用播放音频等）
    private func setupAudioInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
        SyncLogger.shared.info("🔊 音频中断监听已注册")
    }
    
    /// 处理音频中断
    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // 中断开始（来电、闹钟等），自动暂停播放
            SyncLogger.shared.info("🔊 音频中断开始，自动暂停播放")
            if isSpeaking && !isPaused {
                pause()
            }
        case .ended:
            // 中断结束，检查是否应该恢复播放
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                SyncLogger.shared.info("🔊 音频中断结束，系统建议恢复播放")
                // 自动恢复播放（如果之前是播放状态被中断的）
                if isSpeaking && isPaused {
                    resume()
                }
            } else {
                SyncLogger.shared.info("🔊 音频中断结束，系统不建议恢复播放，保持暂停状态")
            }
        @unknown default:
            break
        }
    }
    
    /// 更新控制中心/锁屏的现在播放信息
    private func updateNowPlayingInfo() {
        guard isSpeaking else { return }
        
        var nowPlayingInfo: [String: Any] = [:]
        
        // 标题：当前句子内容（截断显示）
        let title = currentText.count > 50 ? String(currentText.prefix(50)) + "..." : currentText
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        
        // 副标题：播放进度
        nowPlayingInfo[MPMediaItemPropertyArtist] = "第 \(currentSentenceIndex + 1)/\(totalSentences) 句"
        
        // 专辑名：应用名称
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Anki 笔记 - 课堂讲稿"
        
        // 播放进度（如果有 audioPlayer）
        if let player = audioPlayer, player.duration > 0 {
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        } else {
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    /// 清除现在播放信息
    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    
    /// 注册远程控制命令（锁屏/控制中心的播放控制），只注册一次
    private func setupRemoteCommandCenter() {
        guard !isRemoteCommandSetup else { return }
        isRemoteCommandSetup = true
        
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // 播放/暂停
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isSpeaking && self.isPaused {
                self.resume()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isSpeaking && !self.isPaused {
                self.pause()
                return .success
            }
            return .commandFailed
        }
        
        // 上一句/下一句
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isSpeaking {
                self.skipToNext()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isSpeaking {
                self.skipToPrevious()
                return .success
            }
            return .commandFailed
        }
        
        SyncLogger.shared.info("🔊 远程控制命令已注册（锁屏/控制中心播放控制）")
    }
    
    /// 开始播放前的保活准备（激活音频会话、注册远程控制）
    private func prepareForBackgroundPlayback() {
        activateAudioSessionIfNeeded()
        setupRemoteCommandCenter()
    }
    
    /// 跳转到指定句子索引并开始播放（用于视图层跳转，确保 TTSService 内部索引与视图一致）
    func skipToSentence(at index: Int) {
        guard index >= 0 && index < sentences.count else { return }
        stopCurrentOnly()
        currentSentenceIndex = index
        currentText = sentences[index]
        isSpeaking = true
        isPaused = false
        speakCurrentSentence()
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
        downloadTask?.cancel()
        downloadTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        isLoading = false
        
        switch config.provider {
        case .edgeTTSService:
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
        // 检查是否已暂停：如果已暂停，不自动播放下一句
        guard !isPaused else {
            SyncLogger.shared.info("🔊 sentenceFinished: 已暂停，不自动播放下一句，currentIndex=\(currentSentenceIndex)")
            pendingPlayIndex = currentSentenceIndex + 1
            return
        }
        
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
        // 更新锁屏/控制中心的现在播放信息
        updateNowPlayingInfo()
    }
    
    // MARK: - Edge-TTS 服务（HTTP API，Cloudflare Workers 部署）
    
    /// 使用 Edge-TTS HTTP 服务合成语音
    /// API 文档: POST /v1/audio/speech
    /// 请求体: { input, voice, speed, pitch, style, volume }
    /// 响应: MP3 音频二进制数据
    private func speakEdgeTTSService(_ text: String) {
        let serviceURL = config.serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serviceURL.isEmpty, let url = URL(string: "\(serviceURL)/v1/audio/speech") else {
            SyncLogger.shared.warning("🔊 Edge-TTS 服务: URL 无效，跳过当前句子")
            isLoading = false
            sentenceFinished()
            return
        }
        
        SyncLogger.shared.info("🔊 Edge-TTS 服务: 开始合成，URL=\(url.absoluteString)")
        SyncLogger.shared.info("🔊 Edge-TTS 服务: 文本前50字=\(String(text.prefix(50)))")
        
        // 构建请求体
        let body: [String: Any] = [
            "input": text,
            "voice": config.edgeVoice,
            "speed": 1.0,  // 合成时始终使用默认语速，语速通过播放时后处理实现
            "pitch": "\(Int(config.pitch))",
            "style": "general",
            "volume": "0"
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            SyncLogger.shared.warning("🔊 Edge-TTS 服务: 请求体编码失败，跳过当前句子")
            isLoading = false
            sentenceFinished()
            return
        }
        
        // 使用 URLSessionDataTask 下载音频
        downloadTask?.cancel()
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                // 如果是取消错误，忽略
                if (error as NSError).code == NSURLErrorCancelled {
                    SyncLogger.shared.info("🔊 Edge-TTS 服务: 任务被取消")
                    return
                }
                SyncLogger.shared.warning("🔊 Edge-TTS 服务: 请求失败 - \(error.localizedDescription)，跳过当前句子")
                self.isLoading = false
                self.sentenceFinished()
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                SyncLogger.shared.warning("🔊 Edge-TTS 服务: 无效响应，跳过当前句子")
                self.isLoading = false
                self.sentenceFinished()
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "无"
                SyncLogger.shared.warning("🔊 Edge-TTS 服务: HTTP \(httpResponse.statusCode)，响应体=\(errorBody.prefix(200))，跳过当前句子")
                self.isLoading = false
                self.sentenceFinished()
                return
            }
            
            guard let audioData = data, !audioData.isEmpty else {
                SyncLogger.shared.warning("🔊 Edge-TTS 服务: 音频数据为空，跳过当前句子")
                self.isLoading = false
                self.sentenceFinished()
                return
            }
            
            SyncLogger.shared.info("🔊 Edge-TTS 服务: 合成成功，音频大小=\(audioData.count) 字节")
            
            // 缓存音频数据到内存
            self.audioCache[self.currentSentenceIndex] = audioData
            
            // 【新增】写入磁盘缓存（持久化，下次播放直接使用）
            TTSCacheManager.shared.setDiskCache(
                audioData,
                forKey: TTSCacheManager.shared.cacheKey(
                    for: text,
                    voice: self.config.edgeVoice,
                    pitch: Int(self.config.pitch)
                ),
                sentence: text,
                voice: self.config.edgeVoice,
                pitch: Int(self.config.pitch)
            )
            
            // 检查暂停状态：如果已暂停，只缓存不播放
            guard !self.isPaused else {
                SyncLogger.shared.info("🔊 Edge-TTS 服务: 已暂停，缓存音频但不播放，index=\(self.currentSentenceIndex)")
                self.isLoading = false
                self.pendingPlayIndex = self.currentSentenceIndex
                return
            }
            
            // 播放音频（使用统一入口）
            self.playAudioData(audioData)
            
            // 预下载下一句
            self.preloadNextSentence()
        }
        
        downloadTask = task
        task.resume()
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
