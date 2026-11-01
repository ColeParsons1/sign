import AVFoundation
import SoundAnalysis

/// Runs the note reader and Apple's on-device sound classifier (which names the instruments it hears) on their own
/// queue, fed by the microphone, or by this phone's own audio while "Hear this phone" is on, and keeps the latest
/// score for the picture to read at any moment.
final class Reading: NSObject, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.supremelabssoftware.felt.reading", qos: .userInitiated)
    private let reader = NoteReader()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: NoteReader.rate, channels: 1, interleaved: false)!
    private var classifier: SNAudioStreamAnalyzer?
    private var position: AVAudioFramePosition = 0
    // touched only by the microphone's thread
    private var converter: AVAudioConverter?
    // guarded by lock
    private let lock = NSLock()
    private var latest = Score()
    private var phoneUntil = 0.0
    /// The classifier's labels for speaking rather than singing (only those this version of it knows).
    private var speechLabels: Set<String> = []

    override init() {
        super.init()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16000)
            request.overlapFactor = 0.5
            speechLabels = Set(["speech", "shout", "yell", "whispering"]).intersection(request.knownClassifications)
            if (try? analyzer.add(request, withObserver: self)) != nil { classifier = analyzer }
        }
    }

    /// The latest score.
    var score: Score {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Microphone audio, in its own format. Ignored while this phone's own audio is coming through.
    func feedMic(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let phone = Date().timeIntervalSince1970 < phoneUntil
        lock.unlock()
        guard !phone, let samples = resample(buffer) else { return }
        queue.async { self.process(samples) }
    }

    /// This phone's own audio, already at 16 kHz (the broadcast extension resamples it).
    func feedPhone(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        phoneUntil = Date().timeIntervalSince1970 + 0.5
        lock.unlock()
        queue.async { self.process(samples) }
    }

    func reset() {
        queue.async {
            self.reader.reset()
            self.reader.heard = self.reader.heard.map { _ in 0 }
            self.publish()
        }
    }

    #if DEBUG
    /// For the test harness: waits for everything fed so far to be read.
    func drain() { queue.sync {} }
    #endif

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * NoteReader.rate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    private func process(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { reader.push($0) }
        SignWords.shared.feed(samples)          // (the Sign scene's words: nothing unless it is showing)
        if let classifier, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) {
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            classifier.analyze(buf, atAudioFramePosition: position)
            position += AVAudioFramePosition(samples.count)
        }
        publish()
    }

    private func publish() {
        let s = reader.score(wall: Date().timeIntervalSince1970)
        lock.lock()
        latest = s
        lock.unlock()
    }

    // MARK: SNResultsObserving

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var heard = [Float](repeating: 0, count: Player.allCases.count)
        var rap: Float = 0, speech: Float = 0, choir: Float = 0, solo: Float = 0
        for c in result.classifications {
            if let p = Player.labels[c.identifier] { heard[p.rawValue] = max(heard[p.rawValue], Float(c.confidence)) }
            if c.identifier == "rapping" { rap = Float(c.confidence) }
            if c.identifier == "choir_singing" { choir = Float(c.confidence) }
            if c.identifier == "singing" { solo = Float(c.confidence) }
            if speechLabels.contains(c.identifier) { speech = max(speech, Float(c.confidence)) }
        }
        queue.async {
            self.reader.heard = heard; self.reader.heardRap = rap; self.reader.heardSpeech = speech
            self.reader.heardChoir = choir; self.reader.heardSolo = solo
        }
    }
}
