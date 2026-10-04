import AVFoundation
import MediaPlayer
import Observation
import ReadiumShared
import ReadiumNavigator

private final class SpeechRateDelegate: AVTTSEngineDelegate {
    func avTTSEngine(_ engine: AVTTSEngine, didCreateUtterance utterance: AVSpeechUtterance) {
        let speed = UserDefaults.standard.double(forKey: "playbackRate")
        utterance.rate = min(0.65, max(0.2, AVSpeechUtteranceDefaultSpeechRate * Float(speed == 0 ? 1 : speed)))
    }
}

@MainActor @Observable final class PlaybackController: NSObject, PublicationSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    var title = ""
    var subtitle = ""
    var bookID: String?
    var isPlaying = false
    var error: String?
    var duration: Double = 0
    var elapsed: Double = 0
    var sleepUntil: Date?
    var rate: Double = UserDefaults.standard.double(forKey: "playbackRate") == 0 ? 1 : UserDefaults.standard.double(forKey: "playbackRate") {
        didSet { UserDefaults.standard.set(rate, forKey: "playbackRate"); player?.rate = Float(rate); nowPlaying() }
    }
    var speechLocator: Locator?
    var speechChapters: [ReadiumShared.Link] = []
    var chapterTitle = ""
    private var speechPublication: Publication?
    var onLocator: ((Locator) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFinished: (() -> Void)?
    private var speech: PublicationSpeechSynthesizer?
    private var player: AVAudioPlayer?
    private let rateDelegate = SpeechRateDelegate()
    private var sleepTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(15) }; return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in if type == AVAudioSession.InterruptionType.began.rawValue { self?.pause() } }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() } }
        })
    }
    func speak(publication: Publication, book: LocalBook, from locator: Locator?) {
        stop()
        error = nil
        title = book.title; subtitle = "On-device voice"; bookID = book.id
        speechPublication = publication
        func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
        speechChapters = flatten(publication.manifest.tableOfContents)
        if speechChapters.isEmpty { speechChapters = publication.readingOrder }
        let delegate = rateDelegate
        speech = PublicationSpeechSynthesizer(publication: publication, config: .init(voiceIdentifier: UserDefaults.standard.string(forKey: "speechVoice")), engineFactory: { AVTTSEngine(delegate: delegate) }, delegate: self)
        guard let speech else { error = "This publication does not contain text that can be read aloud."; return }
        speech.start(from: locator)
    }
    func selectSpeechChapter(_ chapter: ReadiumShared.Link) async -> Bool {
        error = nil
        guard let publication = speechPublication, let synthesizer = speech,
              let locator = await publication.locate(chapter), synthesizer === speech else {
            error = "This chapter cannot be opened for narration. Open it in the reader and choose Read aloud."
            return false
        }
        chapterTitle = chapter.title ?? "Chapter"
        speechLocator = locator; onLocator?(locator)
        synthesizer.start(from: locator)
        return true
    }
    func play(url: URL, book: LocalBook, start: Double = 0) throws {
        stop()
        error = nil
        // Playback already supports AirPlay and Bluetooth A2DP. Explicit
        // allowAirPlay is only valid for playAndRecord and can throw OSStatus -50.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.delegate = self; audio.enableRate = true; audio.rate = Float(rate)
        audio.currentTime = min(max(0, start), audio.duration)
        player = audio; duration = audio.duration; elapsed = audio.currentTime; title = book.title; subtitle = "Downloaded narration"; bookID = book.id
        isPlaying = audio.play(); nowPlaying()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let player = self.player else { return }
                // A paused recording must not pull a manually turned page back
                // to its old locator. Explicit seek still publishes below.
                guard player.isPlaying else { continue }
                self.elapsed = player.currentTime; self.onProgress?(self.elapsed); self.nowPlaying()
            }
        }
    }
    func toggle() { isPlaying ? pause() : resume() }
    func pause() {
        speech?.pause()
        if let player {
            let wasPlaying = player.isPlaying
            player.pause(); elapsed = player.currentTime
            if wasPlaying { onProgress?(elapsed) }
        }
        isPlaying = false; nowPlaying()
    }
    func resume() { speech?.resume(); if let player { isPlaying = player.play() }; nowPlaying() }
    func stop() { speech?.stop(); speech = nil; speechPublication = nil; speechChapters = []; chapterTitle = ""; player?.stop(); player = nil; tickTask?.cancel(); isPlaying = false; duration = 0; elapsed = 0; onProgress = nil; onFinished = nil; onLocator = nil; speechLocator = nil; bookID = nil; title = ""; subtitle = ""; nowPlaying() }
    func skip(_ seconds: Double) { if let player { seek(player.currentTime + seconds) } else if seconds > 0 { speech?.next() } else { speech?.previous() } }
    func seek(_ value: Double) { guard let player else { return }; player.currentTime = min(max(0, value), player.duration); elapsed = player.currentTime; onProgress?(elapsed); nowPlaying() }
    func sleep(minutes: Int?) {
        sleepTask?.cancel(); sleepUntil = minutes.map { Date().addingTimeInterval(Double($0 * 60)) }
        guard let minutes else { return }
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
            self?.pause(); self?.sleepUntil = nil
        }
    }
    private func nowPlaying() {
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: subtitle, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration; info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, stateDidChange state: PublicationSpeechSynthesizer.State) {
        guard synthesizer === speech else { return }
        switch state {
        case .stopped: isPlaying = false
        case .paused: isPlaying = false
        case .playing(let utterance, let range):
            isPlaying = true; speechLocator = range ?? utterance.locator; onLocator?(range ?? utterance.locator)
            let candidates = speechChapters.filter { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href((range ?? utterance.locator).href.string) }
            if candidates.count == 1, let title = candidates.first?.title { chapterTitle = title }
            else if chapterTitle.isEmpty, let title = speechLocator?.title { chapterTitle = title }
        }
        nowPlaying()
    }
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error) { guard synthesizer === speech else { return }; self.error = "Speech failed: \(error)"; pause() }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { Task { @MainActor in guard player === self.player else { return }; self.isPlaying = false; self.nowPlaying(); if flag { self.onFinished?() } else { self.error = "Audio playback could not finish." } } }
}
