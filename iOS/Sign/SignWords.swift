import AVFoundation
import Speech

/// The words being sung, for the Sign scene (Cole, 2026-11-01: fingerspell each word of a song's lyrics in ASL).
///
/// Listens to the same 16 kHz audio the note reader hears (the microphone, or this phone's own audio through the
/// broadcast) with Apple's speech recogniser, on the device where it can be, and hands out each new word once it has
/// settled: a word is taken when the recogniser has moved on past it, so its guesses at the word still being sung aren't
/// spelled. Nothing runs unless the Sign scene is showing. A recognition task is limited to about a minute, so it is
/// renewed every fifty seconds.
///
/// FELT_SIGN_WORDS="some words": instead of listening, hands out those words in turn, one every couple of seconds (for
/// checking the hands without a singer).
final class SignWords: @unchecked Sendable {
    static let shared = SignWords()

    private let lock = NSLock()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date.distantPast
    private var taken = 0                   // words of the current task already handed out
    private var ready: [String] = []
    private var active = false, asked = false
    private let testWords: [String]? = ProcessInfo.processInfo.environment["FELT_SIGN_WORDS"]
        .map { $0.split(separator: " ").map(String.init) }
    private var testIndex = 0, testAt = Date.distantPast

    /// Turns listening on while the Sign scene shows, off when it goes. (Main thread.)
    func setActive(_ on: Bool) {
        lock.lock()
        let was = active
        active = on
        lock.unlock()
        guard on != was else { return }
        if !on { stop(); return }
        if testWords != nil { return }
        if !asked {
            asked = true
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                guard status == .authorized else { return }
                DispatchQueue.main.async { self?.renew() }
            }
        } else if SFSpeechRecognizer.authorizationStatus() == .authorized {
            renew()
        }
    }

    /// The newest settled words since the last call. (Main thread.)
    func take() -> [String] {
        if let words = testWords, !words.isEmpty {
            guard active, Date().timeIntervalSince(testAt) > 2.2 else { return [] }
            testAt = Date()
            defer { testIndex += 1 }
            return [words[testIndex % words.count]]
        }
        lock.lock()
        defer { lock.unlock() }
        let out = ready
        ready = []
        if active, Date().timeIntervalSince(taskStarted) > 50 { DispatchQueue.main.async { self.renew() } }
        return out
    }

    /// 16 kHz mono samples, from the note reader's queue.
    func feed(_ samples: [Float]) {
        lock.lock()
        let req = active ? request : nil
        lock.unlock()
        guard let req, !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        req.append(buf)
    }

    private func stop() {
        lock.lock()
        let t = task, r = request
        task = nil; request = nil; taken = 0
        lock.unlock()
        r?.endAudio()
        t?.cancel()
    }

    /// A fresh recognition task (the last one ended, ran its minute, or the scene just came on).
    private func renew() {
        stop()
        lock.lock()
        let on = active
        lock.unlock()
        guard on, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        lock.lock()
        request = req; taken = 0; taskStarted = Date()
        lock.unlock()
        let t = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let words = result.bestTranscription.segments.map { $0.substring }
                // settled: every word but the one still being heard, unless the task has finished
                let settled = result.isFinal ? words.count : max(0, words.count - 1)
                self.lock.lock()
                if self.request === req, settled > self.taken {
                    self.ready += words[self.taken..<settled]
                    self.taken = settled
                }
                self.lock.unlock()
            }
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async {
                    self.lock.lock()
                    let mine = self.request === req
                    self.lock.unlock()
                    if mine { self.renew() }
                }
            }
        }
        lock.lock()
        if request === req { task = t } else { t.cancel() }
        lock.unlock()
    }
}
