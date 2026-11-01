import AVFoundation
import ShazamKit
import SwiftUI
import UIKit

/// Listens through the microphone to whatever is playing (any app, a speaker, a car, a concert),
/// and drives the phone's haptics, the picture, and the Watch.
@MainActor
final class Engine: ObservableObject {
    /// One listener for the whole app: the phone's screen and the big screen show the same music.
    static let shared = Engine()

    @Published private(set) var f = Features()
    @Published private(set) var beats = 0
    @Published private(set) var hats = 0
    @Published private(set) var snares = 0
    @Published private(set) var beatClock: Tempo?       // the detected tempo, so the show can sweep in time
    @Published var bigScreen: CGSize?                   // a connected TV or projector's size, while there is one
    @Published private(set) var lights = InstrumentLights()
    @Published private(set) var peakAt = Date.distantPast
    @Published private(set) var ant: Float = 0          // 0...1 as a marked moment approaches
    @Published private(set) var listening = false
    @Published private(set) var songID: String?
    @Published private(set) var line: String?
    @Published var status = "Tap Listen, then play music: in your headphones, from any app, a speaker, a car or a concert."
    @Published var asking: UUID?
    @Published private(set) var watchReachable = false
    @Published private(set) var hearingPhone = false    // the broadcast extension is sending this phone's own audio
    @Published var intensity: Float = 1 { didSet { haptics.intensity = intensity } }
    @Published var lightOn = false { didSet { if !lightOn { torch.set(0) } } }
    /// Listen to this phone's own audio only (headphones, Spotify, YouTube…, through “Hear this phone”), never the
    /// microphone: nothing in the room is picked up (Cole, 2026-10-29). Off: the phone and the room both, as before.
    /// Switching while listening opens or closes the microphone there and then.
    @Published var phoneOnly = UserDefaults.standard.bool(forKey: "phoneOnly") {
        didSet {
            UserDefaults.standard.set(phoneOnly, forKey: "phoneOnly")
            guard listening, phoneOnly != oldValue else { return }
            if phoneOnly { closeMic(); micFrame = Features(); status = phoneOnlyStatus }
            else { openMic() }
        }
    }
    private var micOpen = false
    private var phoneOnlyStatus: String {
        hearingPhone ? "Listening to this phone only. The room isn't heard."
                     : "Listening to this phone only. Tap “Hear this phone” and start the broadcast; the room isn't heard."
    }
    var lightAvailable: Bool { torch.available }

    let library = Library()
    /// The notes, chords, key and instruments, read from the same audio (Medicina draws them).
    let reading = Reading()
    var song: SongRecord? { songID.flatMap { library.songs[$0] } }

    private let haptics = Haptics()
    private let torch = Torch()
    private var flashAt = 0.0, flashLevel: Float = 0, blazeUntil = 0.0
    private let recognizer = Recognizer()
    private let watch = WatchLink()
    private let audio = AVAudioEngine()
    private var songStart = 0.0, matchedAt = 0.0, prevPos = -1.0, quietSince = 0.0, lastTempoSent = 0.0
    private var counted = false, recognitionWarned = false
    private var sentMoments = Set<UUID>()
    private var lineTask: Task<Void, Never>?
    private let channel = SharedChannel()
    private var seen = SharedState()
    private var audioCursor: UInt64 = 0
    private var phoneAt = 0.0, lastBeatAt = 0.0, lastDropAt = 0.0
    private var lastSnareAt = 0.0, lastHatAt = 0.0, lastHatTap = 0.0, lightsAt = 0.0
    private var micFrame = Features(), phoneFrame = Features()
    private var kickFlashAt = 0.0, snareBusy = 0.0, hatBusy = 0.0

    init() {
        seen = channel.state ?? SharedState()
        let poll = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollPhone() } }
        RunLoop.main.add(poll, forMode: .common)
        recognizer.onMatch = { [weak self] item in
            guard let id = item.shazamID else { return }
            let start = Date().timeIntervalSince1970 - item.predictedCurrentMatchOffset
            DispatchQueue.main.async { self?.matched(id: id, title: item.title ?? "Unknown song", artist: item.artist ?? "", start: start) }
        }
        recognizer.onError = { [weak self] err in DispatchQueue.main.async { self?.recognitionFailed(err) } }
        watch.onMark = { [weak self] in self?.mark() }
        watch.onReachability = { [weak self] r in self?.watchReachable = r }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.haptics.restart() }
        }
    }

    func start() {
        audioCursor = channel.audioNow
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["FELT_DEMO_FILE"] { startDemoFile(path); return }
        if ProcessInfo.processInfo.environment["FELT_DEMO"] != nil { startDemo(); return }
        #endif
        if phoneOnly {
            // no microphone at all: the picture, the vibration and the song's name all come from the broadcast
            listening = true
            UIApplication.shared.isIdleTimerDisabled = true
            status = phoneOnlyStatus
            return
        }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                if ok { self.begin() } else { self.status = "Felt needs the microphone to hear the music. Turn it on in Settings → Privacy & Security → Microphone." }
            }
        }
    }

    private func begin() {
        guard openMic() else { return }
        listening = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Listening to the room. For headphones and apps on this phone, tap “Hear this phone” too."
    }

    /// The microphone, feeding the beat, the reading and song recognition. False (with the reason in `status`) if it
    /// can't be opened.
    @discardableResult private func openMic() -> Bool {
        guard !micOpen else { return true }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    if ok { if self.listening && !self.phoneOnly { self.openMic() } }
                    else { self.status = "Felt needs the microphone to hear the room. Turn it on in Settings → Privacy & Security → Microphone." }
                }
            }
            return false
        }
        let s = AVAudioSession.sharedInstance()
        do {
            // mixWithOthers keeps Spotify, YouTube etc. playing; measurement mode turns off voice processing
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try s.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try s.setActive(true)
        } catch {
            status = "Couldn't open the microphone: \(error.localizedDescription)"
            return false
        }
        let input = audio.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { status = "No microphone available."; return false }
        let analyzer = Analyzer(sampleRate: fmt.sampleRate)
        analyzer.onFrame = { [weak self] fr in DispatchQueue.main.async { self?.frame(fr, fromPhone: false) } }
        analyzer.onTempo = { [weak self] t in DispatchQueue.main.async { self?.tempo(t, fromPhone: false) } }
        let rec = recognizer, reading = reading
        let clockOffset = Date().timeIntervalSince1970 - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { buf, when in
            let t = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) + clockOffset : Date().timeIntervalSince1970
            analyzer.process(buf, startTime: t)
            rec.feed(buf, at: when)
            reading.feedMic(buf)
        }
        do { try audio.start() } catch {
            input.removeTap(onBus: 0)
            status = "Couldn't start listening: \(error.localizedDescription)"
            return false
        }
        micOpen = true
        if listening { status = "Listening to this phone and the room." }
        return true
    }

    private func closeMic() {
        guard micOpen else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        micOpen = false
    }

    func stop() {
        closeMic()
        #if DEBUG
        demoFeed?.cancel()
        demoFeed = nil
        #endif
        reading.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        listening = false
        endSong()
        f = Features()
        lights = InstrumentLights()
        snareBusy = 0; hatBusy = 0; kickFlashAt = 0     // or the next Listen lights up from the last song's drums
        beatClock = nil
        #if DEBUG
        demoTimer?.invalidate()
        demoTimer = nil
        #endif
        ant = 0
        haptics.setBed(level: 0, sharpness: 0)
        torch.set(0)
        UIApplication.shared.isIdleTimerDisabled = false
        watch.send(["k": "stop"])
        status = "Stopped."
    }

    /// Reads what the broadcast extension heard: this phone's own audio, headphones included.
    private func pollPhone() {
        let now = Date().timeIntervalSince1970
        if hearingPhone && now - phoneAt > 1.5 { hearingPhone = false }
        if listening {
            let a = channel.readAudio(from: &audioCursor)
            if !a.isEmpty { reading.feedPhone(a) }
        }
        guard let s = channel.state, s.seq != seen.seq else { return }
        let prev = seen
        seen = s
        guard listening else { return }
        phoneAt = now
        if !hearingPhone { hearingPhone = true; if phoneOnly { status = phoneOnlyStatus } }
        frame(Features(bands: [s.bands.0, s.bands.1, s.bands.2, s.bands.3], energy: s.energy, tension: s.tension,
                       brightness: s.brightness, beat: s.beats != prev.beats, drop: s.drops != prev.drops, time: s.time,
                       spectrum: channel.spectrum, snare: s.snares != prev.snares, hat: s.hats != prev.hats, voice: s.voice,
                       regions: floats(s.regions), sizzle: s.sizzle, sweep: s.sweep, bassPitch: s.bassPitch),
              fromPhone: true)
        if s.tempoSeq != prev.tempoSeq {
            tempo(Tempo(bpm: s.bpm, anchor: s.anchor, confidence: s.confidence), fromPhone: true)
        }
        if s.matchSeq != prev.matchSeq, let url = SharedChannel.matchURL,
           let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(SharedMatch.self, from: d) {
            matched(id: m.id, title: m.title, artist: m.artist, start: m.start)
        }
    }

    /// Both ears feed one picture: this phone's own audio when it's coming through, and the
    /// microphone always (music in the room, knocks on the phone).
    private func frame(_ src: Features, fromPhone: Bool) {
        guard listening else { return }
        if !fromPhone && phoneOnly { return }      // (the room isn't listened to)
        if fromPhone { phoneFrame = src } else { micFrame = src }
        let p = src.time - phoneFrame.time < 0.5 ? phoneFrame : Features()
        var m = src.time - micFrame.time < 0.5 ? micFrame : Features()
        // with this phone's own music coming through, the mic mostly hears the room (talk, a crowd, the phone
        // being handled), each band normalised up to full scale on its own: it still adds, at half weight. Its
        // hits (knocks included) still count in full
        let mw = 1 - 0.5 * min(1, p.energy / 0.1)
        if mw < 1 {
            m.bands = m.bands.map { $0 * mw }
            m.spectrum = m.spectrum.map { $0 * mw }
            m.regions = m.regions.map { $0 * mw }
            m.energy *= mw; m.voice *= mw; m.sizzle *= mw
        }
        // brightness blended by loudness, not flipped whenever the two ears' energies cross; the signed and pitch
        // values can't be merged by max, so they come from one ear, the phone's while it's playing
        let heard = p.energy + m.energy, lead = p.energy > 0.05 ? p : m
        let bright = heard > 1e-4 ? (p.brightness * p.energy + m.brightness * m.energy) / heard : max(p.brightness, m.brightness)
        var fr = Features(bands: zip(p.bands, m.bands).map { max($0, $1) },
                          energy: max(p.energy, m.energy), tension: max(p.tension, m.tension), brightness: bright, time: src.time,
                          spectrum: zip(p.spectrum, m.spectrum).map { max($0, $1) }, voice: max(p.voice, m.voice),
                          regions: zip(p.regions, m.regions).map { max($0, $1) }, sizzle: max(p.sizzle, m.sizzle),
                          sweep: lead.sweep, bassPitch: lead.bassPitch)
        // the same hit can arrive from both, a moment apart
        if src.beat && src.time - lastBeatAt > 0.15 { fr.beat = true; lastBeatAt = src.time }
        if src.snare && src.time - lastSnareAt > 0.1 { fr.snare = true; lastSnareAt = src.time }
        if src.hat && src.time - lastHatAt > 0.06 { fr.hat = true; lastHatAt = src.time }
        if src.drop && src.time - lastDropAt > 8 { fr.drop = true; lastDropAt = src.time }
        f = fr
        if fr.beat { beats += 1 }
        if fr.hat { hats += 1 }
        if fr.snare { snares += 1 }
        updateLights(fr)
        let now = fr.time
        var a: Float = 0
        if let s = song {
            let pos = now - songStart
            if !counted && now - matchedAt > 30 { counted = true; update { $0.sessions += 1 } }
            for m in s.moments {
                let d = m.t - pos
                if d > 0 && d <= 8 { a = max(a, Float(1 - d / 8)) }
                if d > 0 && d <= 10 && !sentMoments.contains(m.id) {
                    sentMoments.insert(m.id)
                    watch.send(["k": "moment", "at": songStart + m.t])
                }
                if prevPos >= 0 && prevPos < m.t && pos >= m.t && pos - prevPos < 1 { peak(m.text) }
            }
            prevPos = pos
            // a long silence means the song is over
            if fr.energy > 0.04 { quietSince = now } else if now - quietSince > 8 { endSong() }
        }
        ant = a
        // Each instrument has its own feel: bass is a deep, smooth rumble; voice and melody add a
        // finer buzz on top; the kick is a heavy, dull thud; the snare a crisp crack; hats a faint tick.
        haptics.setBed(level: fr.bands[0] * 0.3 + fr.bands[1] * 0.3 + fr.voice * 0.3 + fr.tension * 0.2 + a * a * 0.6,
                       sharpness: -0.45 + fr.voice * 0.6 + Float(lights.hat) * 0.25 + a * 0.3)
        if fr.drop {
            peak(nil)
            watch.send(["k": "drop"])
        } else {
            if fr.beat { haptics.tap(0.5 + fr.bands[0] * 0.5, sharpness: 0.12) }
            if fr.snare { haptics.tap(0.6, sharpness: 0.85) }
            let now = Date().timeIntervalSince1970
            if fr.hat && !fr.beat && !fr.snare && now - lastHatTap > 0.1 { lastHatTap = now; haptics.tap(0.22, sharpness: 1) }
        }
        if lightOn { light(fr) }
    }

    /// Smooth envelopes for each instrument's light: hits flare and fade, bass and voice follow their level.
    /// Nothing flashes more than three times a second (photosensitivity): the kick flares at most every 0.34 s,
    /// like the torch, and the snare and hats light by how busy they are, so a backbeat still cracks, a roll
    /// swells into a held light and sixteenth hats shimmer. Open hats, a ride or a crash hold the hats' light up.
    private func updateLights(_ fr: Features) {
        let now = Date().timeIntervalSince1970
        let dt = min(0.1, max(0, now - lightsAt))
        lightsAt = now
        var l = lights
        l.kick *= exp(-dt / 0.18)
        if fr.beat && now - kickFlashAt > 0.34 { kickFlashAt = now; l.kick = 1 }
        snareBusy = snareBusy * exp(-dt / 0.5) + (fr.snare ? 1 : 0)
        hatBusy = hatBusy * exp(-dt / 0.4) + (fr.hat ? 0.35 : 0)
        l.snare += (min(1, snareBusy) - l.snare) * min(1, dt / 0.06)
        let held = Double(max(0, fr.sizzle - 0.15)) * 0.9
        l.hat += (min(1, max(hatBusy, held)) - l.hat) * min(1, dt / 0.12)
        l.bass += (Double(fr.bands[0] * 0.6 + fr.bands[1] * 0.4) - l.bass) * min(1, dt / 0.25)
        l.voice += (Double(fr.voice) * 1.4 - l.voice) * min(1, dt / 0.3)
        lights = l
    }

    /// Flashlight: a short flash per beat (heavier bass, brighter), a glow that rises toward a
    /// marked moment, full blaze at drops and moments. Never more than 3 flashes a second,
    /// which keeps it under the flicker rates most likely to trigger photosensitive seizures.
    private func light(_ fr: Features) {
        let now = Date().timeIntervalSince1970
        if fr.beat && now - flashAt > 0.34 {
            flashAt = now
            flashLevel = 0.25 + fr.bands[0] * 0.75
        }
        let flash: Float = now - flashAt < 0.09 ? flashLevel : 0
        let blaze: Float = now < blazeUntil ? 1 : 0
        torch.set(max(flash, blaze, ant * ant * 0.7))
    }

    // The Watch taps along on its own clock from this, so taps stay on the beat despite message delay.
    private func tempo(_ t: Tempo, fromPhone: Bool) {
        guard listening, fromPhone || !hearingPhone else { return }
        beatClock = t
        guard t.anchor - lastTempoSent >= 1 else { return }
        lastTempoSent = t.anchor
        watch.send(["k": "beat", "bpm": t.bpm, "anchor": t.anchor, "conf": t.confidence, "level": Double(f.energy)])
    }

    private func peak(_ text: String?) {
        haptics.peak()
        peakAt = Date()
        blazeUntil = Date().timeIntervalSince1970 + 0.6
        flashAt = blazeUntil   // let the blaze fade out before the next beat flash
        guard let text, !text.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.3)) { line = text }
        lineTask?.cancel()
        lineTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 1.5)) { line = nil }
        }
    }

    private func matched(id: String, title: String, artist: String, start: Double) {
        guard listening else { return }
        let now = Date().timeIntervalSince1970
        if songID != id {
            if library.songs[id] == nil {
                library.songs[id] = SongRecord(id: id, title: title, artist: artist)
                library.save()
            }
            songID = id
            matchedAt = now; quietSince = now; counted = false; sentMoments = []; prevPos = -1
            let s = library.songs[id]!
            status = s.moments.isEmpty
                ? "Press “This hits me” the moment a part gets you."
                : "\(s.moments.count) moment\(s.moments.count == 1 ? "" : "s") marked in this song. Felt will build to each one."
            watch.send(["k": "song", "title": s.title, "artist": s.artist])
        } else if abs(start - songStart) > 2 {
            sentMoments = []; prevPos = -1   // replayed or skipped around
        }
        songStart = start
    }

    private func recognitionFailed(_ error: Error) {
        guard !recognitionWarned, songID == nil else { return }
        recognitionWarned = true
        status = "Song recognition isn't working (\(error.localizedDescription)). Beats and vibration still work; marked moments need it."
    }

    private func endSong() {
        guard songID != nil else { return }
        songID = nil
        watch.send(["k": "song", "title": "", "artist": ""])
    }

    func mark() {
        guard listening, song != nil else {
            status = listening ? "Still working out which song this is. Try again in a few seconds." : "Tap Listen first."
            watch.send(["k": "marked", "ok": false])
            return
        }
        // people press a beat after the feeling arrives, so step back a little
        let m = Moment(t: max(0, Date().timeIntervalSince1970 - songStart - 0.6), text: "")
        update { $0.moments.append(m); $0.moments.sort { $0.t < $1.t } }
        sentMoments.insert(m.id)
        haptics.tap(1, sharpness: 0.8)
        watch.send(["k": "marked", "ok": true])
        asking = m.id
    }

    func setText(_ text: String, for id: UUID) {
        update { s in
            if let i = s.moments.firstIndex(where: { $0.id == id }) { s.moments[i].text = text.trimmingCharacters(in: .whitespaces) }
        }
    }

    private func update(_ change: (inout SongRecord) -> Void) {
        guard let id = songID, var s = library.songs[id] else { return }
        change(&s)
        library.songs[id] = s
        library.save()
    }

    #if DEBUG
    /// For checking the show without playing music aloud: launch with FELT_DEMO=1 in the environment
    /// and Listen plays a fake 124 BPM track (kick on every beat, snare on 2 and 4, hats on the
    /// off-beats, a drop every 32 beats) straight into the same path the microphone uses.
    private var demoTimer: Timer?

    /// FELT_DEMO_FILE=/path/to/song: Listen plays that file (silently) into the same path the microphone uses, so the
    /// whole show, the notes and chords included, can be checked on a real recording.
    private var demoFeed: DispatchSourceTimer?

    /// The file is read into memory and fed in 2048-frame buffers as the clock passes, looping: no audio unit at all,
    /// so it works even when the simulator can't open an audio output.
    private func startDemoFile(_ path: String) {
        // (a bare name is looked for in the app's Documents, so a file copied onto a phone can be played)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(path)
        guard let file = try? AVAudioFile(forReading: url),
              let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: whole)) != nil, whole.frameLength > 0 else { status = "Can't open \(path)"; return }
        let format = file.processingFormat, sr = format.sampleRate, total = Int(whole.frameLength), chunk = 2048
        let analyzer = Analyzer(sampleRate: sr)
        analyzer.onFrame = { [weak self] fr in DispatchQueue.main.async { self?.frame(fr, fromPhone: false) } }
        analyzer.onTempo = { [weak self] t in DispatchQueue.main.async { self?.tempo(t, fromPhone: false) } }
        let reading = reading, recognizer = recognizer
        let start = Date().timeIntervalSince1970
        var fed = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.supremelabssoftware.felt.demofeed", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let due = Int((Date().timeIntervalSince1970 - start) * sr)
            while fed + chunk <= due {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
                buf.frameLength = AVAudioFrameCount(chunk)
                for ch in 0..<Int(format.channelCount) {
                    for i in 0..<chunk { buf.floatChannelData![ch][i] = whole.floatChannelData![ch][(fed + i) % total] }
                }
                fed += chunk
                analyzer.process(buf, startTime: Date().timeIntervalSince1970)
                reading.feedMic(buf)
                recognizer.feed(buf, at: AVAudioTime(sampleTime: AVAudioFramePosition(fed), atRate: sr))  // (so a match, and the title, shows too)
            }
        }
        timer.resume()
        demoFeed = timer
        listening = true
        status = "Demo file (FELT_DEMO_FILE)"
    }

    private func startDemo() {
        listening = true
        status = "Demo track (FELT_DEMO)"
        let period = 60.0 / 124, start = Date().timeIntervalSince1970
        var lastBeat = -1, lastHalf = -1
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.listening else { return }
                let now = Date().timeIntervalSince1970
                let pos = (now - start) / period
                let b = Int(pos), half = Int(pos * 2)
                let env = Float(exp(-(pos - Double(b)) * 4))
                var fr = Features()
                fr.time = now
                fr.bands = [0.35 + 0.55 * env, 0.45 + 0.35 * env, 0.5, 0.35 + 0.3 * Float(abs(sin(pos * .pi)))]
                fr.energy = 0.5 + 0.25 * env
                fr.voice = 0.35 + 0.3 * Float(sin(now * 0.7))
                fr.spectrum = (0..<spectrumBins).map { k in Float(0.3 + 0.5 * abs(sin(Double(k) * 0.4 + now * 3))) * (k < 6 ? 0.5 + env : 1) }
                fr.regions = [0.5 + 0.3 * env, 0.6, 0.5, 0.5 + 0.2 * Float(sin(now * 0.3)), 0.45, fr.bands[3], fr.bands[3]]
                fr.bassPitch = 0.3 + 0.15 * Float(sin(pos * .pi / 4))     // a bassline walking over two bars
                if b != lastBeat {
                    lastBeat = b
                    fr.beat = true
                    fr.snare = b % 2 == 1
                    fr.drop = b % 32 == 31
                    if b % 4 == 0 { self.tempo(Tempo(bpm: 124, anchor: start + Double(b) * period, confidence: 0.9), fromPhone: false) }
                }
                if half != lastHalf { lastHalf = half; fr.hat = half % 2 == 1 }
                self.frame(fr, fromPhone: false)
            }
        }
    }
    #endif
}
