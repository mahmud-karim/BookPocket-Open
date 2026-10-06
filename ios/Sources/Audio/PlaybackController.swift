import AVFoundation
import MediaPlayer
import Observation
import ReadiumShared
import ReadiumNavigator

struct RecordingPart {
    var url: URL
    var start: Double = 0
    var end: Double? = nil
}
struct RecordingInterval {
    var start: Double
    var end: Double
    var sourceStart: Double
}

@MainActor @Observable final class PlaybackController: NSObject, PublicationSpeechSynthesizerDelegate {
    var title = ""
    var subtitle = ""
    var bookID: String?
    var isPlaying = false
    var error: String?
    var duration: Double = 0
    var elapsed: Double = 0
    var sleepUntil: Date?
    var miniPlayerDismissed = false
    var listeningSession: ListeningSession?
    var onSessionUpdate: ((Bool) -> Void)?
    private var preparedSpeechLocator: Locator?
    private var speechPrepared = false
    var rate: Double = UserDefaults.standard.double(forKey: "playbackRate") == 0 ? 1 : UserDefaults.standard.double(forKey: "playbackRate") {
        didSet { UserDefaults.standard.set(rate, forKey: "playbackRate"); if isPlaying { player?.rate = Float(rate) }; nowPlaying(); onSessionUpdate?(true) }
    }
    var speechLocator: Locator?
    var speechChapters: [ReadiumShared.Link] = []
    var chapterTitle = ""
    private var speechPublication: Publication?
    var onLocator: ((Locator) -> Void)?
    var onClearHighlight: (() -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFinished: (() -> Void)?
    private var speech: PublicationSpeechSynthesizer?
    private var player: AVPlayer?
    private var finishObserver: NSObjectProtocol?
    private var seekRevision = UUID()
    private var seeking = false
    var recordingID: String?
    private(set) var recordingIntervals: [RecordingInterval] = []

    /// Converts the single user timeline to the immutable asset-local clock.
    func recordingPosition(at seconds: Double) -> (index: Int, seconds: Double)? {
        guard !recordingIntervals.isEmpty else { return nil }
        let position = min(max(0, seconds), duration)
        let index = recordingIntervals.firstIndex(where: { position < $0.end }) ?? recordingIntervals.count - 1
        let interval = recordingIntervals[index]
        return (index, interval.sourceStart + max(0, position - interval.start))
    }
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
    func speak(publication: Publication, book: LocalBook, from locator: Locator?, autoplay: Bool = true) {
        stop()
        error = nil
        title = book.title; subtitle = "On-device voice"; bookID = book.id
        listeningSession = ListeningSession(bookID: book.id)
        listeningSession?.locatorJSON = try? locator?.jsonString()
        speechLocator = locator; preparedSpeechLocator = locator; speechPrepared = !autoplay
        speechPublication = publication
        func flatten(_ links: [ReadiumShared.Link]) -> [ReadiumShared.Link] { links.flatMap { [$0] + flatten($0.children) } }
        speechChapters = flatten(publication.manifest.tableOfContents)
        if speechChapters.isEmpty { speechChapters = publication.readingOrder }
        speech = PublicationSpeechSynthesizer(publication: publication, config: .init(voiceIdentifier: UserDefaults.standard.string(forKey: "speechVoice")), engineFactory: { SystemWordSpeechEngine() }, delegate: self)
        guard let speech else { error = "This publication does not contain text that can be read aloud."; return }
        if autoplay { speech.start(from: locator) }
        onSessionUpdate?(true)
    }
    func selectSpeechChapter(_ chapter: ReadiumShared.Link) async -> Bool {
        error = nil
        guard let publication = speechPublication, let synthesizer = speech,
              let locator = await publication.locate(chapter), synthesizer === speech else {
            error = "This chapter cannot be opened for narration. Open it in the reader and choose Read aloud."
            return false
        }
        chapterTitle = chapter.title ?? "Chapter"
        speechLocator = locator; onLocator?(locator); speechPrepared = false; miniPlayerDismissed = false
        synthesizer.start(from: locator)
        return true
    }
    func play(url: URL, book: LocalBook, start: Double = 0) throws {
        try play(parts: [RecordingPart(url: url)], book: book, start: start)
    }
    func play(parts: [RecordingPart], book: LocalBook, start: Double = 0, recordingID: String? = nil, autoplay: Bool = true) throws {
        stop()
        error = nil
        do {
            // Playback already permits AirPlay/A2DP. Explicit allowAirPlay is
            // valid only with playAndRecord, not this playback category.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            throw BookError.message("Unable to start the iPhone audio session: \(error.localizedDescription)")
        }
        guard !parts.isEmpty else { throw BookError.message("No downloaded audio is available for this selection.") }
        // One composition, one player item, one timeline. Files stay separate on
        // disk, but transport never reloads or resets at a passage boundary.
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw BookError.message("Unable to prepare the recording.") }
        var cursor = CMTime.zero
        var intervals: [RecordingInterval] = []
        for part in parts {
            let asset = AVURLAsset(url: part.url)
            guard let source = asset.tracks(withMediaType: .audio).first else { throw BookError.message("Unable to open a downloaded audio passage. Retry its download.") }
            let sourceDuration = source.timeRange.duration.seconds
            let end = part.end ?? sourceDuration
            guard sourceDuration.isFinite, sourceDuration > 0, part.start.isFinite, end.isFinite,
                  part.start >= 0, end > part.start, end <= sourceDuration + 0.05 else { throw BookError.message("Downloaded audio does not match its selected duration. Retry its download.") }
            let begin = CMTime(seconds: part.start, preferredTimescale: 60_000)
            let length = CMTime(seconds: min(end, sourceDuration) - part.start, preferredTimescale: 60_000)
            try track.insertTimeRange(CMTimeRange(start: source.timeRange.start + begin, duration: length), of: source, at: cursor)
            intervals.append(.init(start: cursor.seconds, end: (cursor + length).seconds, sourceStart: part.start))
            cursor = cursor + length
        }
        let item = AVPlayerItem(asset: composition)
        let audio = AVPlayer(playerItem: item)
        audio.automaticallyWaitsToMinimizeStalling = true
        player = audio; recordingIntervals = intervals; self.recordingID = recordingID
        duration = cursor.seconds; elapsed = min(max(0, start), duration)
        title = book.title; subtitle = "Downloaded narration"; bookID = book.id
        finishObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, item === self.player?.currentItem, self.isPlaying else { return }
                self.elapsed = self.duration; self.onProgress?(self.elapsed)
                self.isPlaying = false; self.nowPlaying(); self.onFinished?(); self.onSessionUpdate?(true)
            }
        }
        if elapsed > 0 { seek(elapsed) }
        isPlaying = autoplay
        if autoplay { audio.playImmediately(atRate: Float(rate)) }
        nowPlaying()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, let player = self.player else { return }
                // A paused recording must not pull a manually turned page back
                // to its old locator. Explicit seek still publishes below.
                guard self.isPlaying, !self.seeking else { continue }
                if player.currentItem?.status == .failed { self.error = "Audio playback failed. Retry the download."; self.pause(); continue }
                let seconds = player.currentTime().seconds
                guard seconds.isFinite else { continue }
                self.elapsed = min(self.duration, max(0, seconds)); self.onProgress?(self.elapsed); self.nowPlaying(); self.onSessionUpdate?(false)
            }
        }
    }
    func toggle() { isPlaying ? pause() : resume() }
    func pause() {
        speech?.pause()
        if let player {
            let wasPlaying = isPlaying
            player.pause()
            // AVPlayer's clock can settle a fraction later after pause. Route
            // loss or a repeated Pause must preserve the already frozen clock,
            // just as it preserves the reader's manually chosen location.
            if wasPlaying, !seeking, player.currentTime().seconds.isFinite { elapsed = player.currentTime().seconds }
            if wasPlaying { onProgress?(elapsed) }
        }
        isPlaying = false; nowPlaying(); onSessionUpdate?(true)
    }
    func dismissMiniPlayer() { pause(); miniPlayerDismissed = true; onSessionUpdate?(true) }
    func resume() {
        miniPlayerDismissed = false
        if speechPrepared { speechPrepared = false; speech?.start(from: preparedSpeechLocator) } else { speech?.resume() }
        if let player { if elapsed >= duration { seek(0) }; isPlaying = true; player.playImmediately(atRate: Float(rate)) }
        nowPlaying(); onSessionUpdate?(true)
    }
    func stop() { speech?.stop(); speech = nil; speechPublication = nil; speechPrepared = false; preparedSpeechLocator = nil; listeningSession = nil; miniPlayerDismissed = false; speechChapters = []; chapterTitle = ""; player?.pause(); player = nil; if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }; finishObserver = nil; tickTask?.cancel(); seekRevision = UUID(); seeking = false; recordingIntervals = []; recordingID = nil; isPlaying = false; duration = 0; elapsed = 0; onProgress = nil; onFinished = nil; onClearHighlight?(); onClearHighlight = nil; onLocator = nil; speechLocator = nil; bookID = nil; title = ""; subtitle = ""; nowPlaying() }
    func skip(_ seconds: Double) { if player != nil { seek(elapsed + seconds) } else if seconds > 0 { speech?.next() } else { speech?.previous() } }
    func seek(_ value: Double) {
        guard let player, value.isFinite else { return }
        let revision = UUID(); seekRevision = revision; seeking = true
        elapsed = min(max(0, value), duration); onProgress?(elapsed); nowPlaying()
        onSessionUpdate?(true)
        player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in guard let self, self.seekRevision == revision else { return }; self.seeking = false }
        }
    }
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
            isPlaying = true
            if let range { speechLocator = range; onLocator?(range) }
            else if speechLocator != nil { speechLocator = nil; onClearHighlight?() }
            let candidates = speechChapters.filter { ReaderSourceMapper.href($0.href) == ReaderSourceMapper.href((range ?? utterance.locator).href.string) }
            if candidates.count == 1, let title = candidates.first?.title { chapterTitle = title }
            else if chapterTitle.isEmpty, let title = speechLocator?.title { chapterTitle = title }
        }
        nowPlaying(); onSessionUpdate?(false)
    }
    func publicationSpeechSynthesizer(_ synthesizer: PublicationSpeechSynthesizer, utterance: PublicationSpeechSynthesizer.Utterance, didFailWithError error: PublicationSpeechSynthesizer.Error) { guard synthesizer === speech else { return }; self.error = "Speech failed: \(error)"; pause() }
}
