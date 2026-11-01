import AVFoundation
import QuartzCore
import ReplayKit
import ShazamKit

/// Runs while "Hear this phone" is on. iOS hands it the audio every app on the phone is playing,
/// wherever it is going (headphones, AirPods, speaker). It analyses that audio and recognises the
/// song, then passes the results to the Felt app through the shared App Group.
/// Screen frames also arrive here and are ignored.
final class SampleHandler: RPBroadcastSampleHandler, SHSessionDelegate {
    private let channel = SharedChannel()
    private let shazam = SHSession()
    private var analyzer: Analyzer?
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var outFormat: AVAudioFormat?
    private var toRing: AVAudioConverter?
    private let ringFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SharedChannel.audioRate, channels: 1, interleaved: false)!
    private let clockOffset = Date().timeIntervalSince1970 - CACurrentMediaTime()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        shazam.delegate = self
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .audioApp, let pcm = convert(sampleBuffer) else { return }
        // presentation times are on the host clock; fall back to arrival time if they look wrong
        let duration = Double(pcm.frameLength) / pcm.format.sampleRate
        let arrival = Date().timeIntervalSince1970 - duration
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds + clockOffset
        analyzer?.process(pcm, startTime: abs(pts - arrival) < 2 ? pts : arrival)
        shazam.matchStreamingBuffer(pcm, at: nil)
        passOn(pcm)
    }

    /// The audio itself, at 16 kHz, for the app to read the notes in.
    private func passOn(_ pcm: AVAudioPCMBuffer) {
        if toRing?.inputFormat != pcm.format { toRing = AVAudioConverter(from: pcm.format, to: ringFormat) }
        guard let toRing,
              let out = AVAudioPCMBuffer(pcmFormat: ringFormat, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ringFormat.sampleRate / pcm.format.sampleRate) + 64)
        else { return }
        var given = false
        var error: NSError?
        toRing.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return }
        channel.writeAudio(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }

    /// ReplayKit audio is usually 16-bit stereo, sometimes big-endian; the analyser wants float mono.
    private func convert(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0 else { return nil }
        var a = asbd.pointee
        if inFormat?.sampleRate != a.mSampleRate || inFormat?.channelCount != a.mChannelsPerFrame
            || inFormat?.streamDescription.pointee.mFormatFlags != a.mFormatFlags {
            guard let inF = AVAudioFormat(streamDescription: &a),
                  let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: a.mSampleRate, channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: inF, to: outF) else { return nil }
            conv.downmix = true
            inFormat = inF; outFormat = outF; converter = conv
            startAnalyzer(sampleRate: a.mSampleRate)
        }
        guard let inF = inFormat, let outF = outFormat, let converter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: frames),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return nil }
        do { try converter.convert(to: outBuf, from: inBuf) } catch { return nil }
        return outBuf
    }

    private func startAnalyzer(sampleRate: Double) {
        let an = Analyzer(sampleRate: sampleRate)
        let channel = channel
        an.onFrame = { f in
            channel.write(spectrum: f.spectrum) { s in
                s.time = f.time
                s.bands = (f.bands[0], f.bands[1], f.bands[2], f.bands[3])
                s.energy = f.energy
                s.tension = f.tension
                s.brightness = f.brightness
                if f.beat { s.beats &+= 1 }
                if f.drop { s.drops &+= 1 }
                if f.snare { s.snares &+= 1 }
                if f.hat { s.hats &+= 1 }
                s.voice = f.voice
                s.regions = float7(f.regions)
                s.sizzle = f.sizzle
                s.sweep = f.sweep
                s.bassPitch = f.bassPitch
            }
        }
        an.onTempo = { t in
            channel.write { s in
                s.bpm = t.bpm; s.anchor = t.anchor; s.confidence = t.confidence
                s.tempoSeq &+= 1
            }
        }
        analyzer = an
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first, let id = item.shazamID, let url = SharedChannel.matchURL else { return }
        let m = SharedMatch(id: id, title: item.title ?? "Unknown song", artist: item.artist ?? "",
                            start: Date().timeIntervalSince1970 - item.predictedCurrentMatchOffset)
        guard let data = try? JSONEncoder().encode(m), (try? data.write(to: url, options: .atomic)) != nil else { return }
        channel.write { $0.matchSeq &+= 1 }
    }
}
