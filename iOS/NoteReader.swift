import Accelerate
import Foundation

// Reads the music itself out of the sound: every note that's playing (the voice's included, bends and vibrato and
// all), which family of instruments is playing it, the chord they make, the key the song is in, the progression it
// keeps coming back to, and the moment a phrase lands home. Medicina draws it.

// MARK: - The alphabet

/// Pitch classes count from C = 0. Around Medicina's wheel they run in fifths (C G D A E B F♯ C♯ A♭ E♭ B♭ F), so notes
/// that sound well together sit together and every key is one unbroken arc of seven.
func fifths(_ pc: Int) -> Int { pc * 7 % 12 }

/// The families of instruments the picture tells apart, each drawn in a form of its own.
enum Player: Int, CaseIterable {
    case voice, piano, guitar, strings, brass, winds, synth, bass, bells

    /// Apple's sound classifier's labels, by family.
    static let labels: [String: Player] = {
        let groups: [Player: [String]] = [
            .voice: ["singing", "choir_singing", "yodeling", "rapping", "humming", "whistling"],
            .piano: ["keyboard_musical", "piano", "electric_piano", "harpsichord"],
            .guitar: ["plucked_string_instrument", "guitar", "electric_guitar", "acoustic_guitar", "steel_guitar_slide_guitar",
                      "guitar_tapping", "guitar_strum", "banjo", "sitar", "mandolin", "zither", "ukulele", "harp"],
            .strings: ["orchestra", "bowed_string_instrument", "violin_fiddle", "cello"],
            .brass: ["brass_instrument", "french_horn", "trumpet", "trombone", "shofar"],
            .winds: ["wind_instrument", "flute", "saxophone", "clarinet", "oboe", "bassoon", "harmonica", "accordion",
                     "bagpipes", "didgeridoo"],
            .synth: ["organ", "electronic_organ", "hammond_organ", "synthesizer", "theremin"],
            .bass: ["bass_guitar", "double_bass"],
            .bells: ["mallet_percussion", "marimba_xylophone", "glockenspiel", "vibraphone", "steelpan", "bell", "church_bell",
                     "chime", "wind_chime", "singing_bowl", "tuning_fork"],
        ]
        var map: [String: Player] = [:]
        for (p, names) in groups { for n in names { map[n] = p } }
        return map
    }()

    /// Struck or plucked, so its notes start sharp and die away, rather than being held by a bow, a breath or a key.
    var struck: Bool { self == .piano || self == .guitar || self == .bells || self == .bass }

    /// Where its notes usually lie, as MIDI numbers.
    var range: ClosedRange<Float> {
        switch self {
        case .voice: 40...86
        case .piano: 21...108
        case .guitar: 40...88
        case .strings: 36...103
        case .brass: 34...86
        case .winds: 46...98
        case .synth: 24...108
        case .bass: 28...57
        case .bells: 60...108
        }
    }
}

struct ChordKind {
    let suffix: String, intervals: [Int], prior: Float
}

/// The chords Felt recognises. A seventh scores a little under the triad it contains unless its seventh is really there.
let chordKinds: [ChordKind] = [
    ChordKind(suffix: "", intervals: [0, 4, 7], prior: 1),
    ChordKind(suffix: "m", intervals: [0, 3, 7], prior: 1),
    ChordKind(suffix: "7", intervals: [0, 4, 7, 10], prior: 0.97),
    ChordKind(suffix: "maj7", intervals: [0, 4, 7, 11], prior: 0.96),
    ChordKind(suffix: "m7", intervals: [0, 3, 7, 10], prior: 0.96),
    ChordKind(suffix: "sus4", intervals: [0, 5, 7], prior: 0.92),
    ChordKind(suffix: "sus2", intervals: [0, 2, 7], prior: 0.9),
    ChordKind(suffix: "dim", intervals: [0, 3, 6], prior: 0.9),
    ChordKind(suffix: "m7♭5", intervals: [0, 3, 6, 10], prior: 0.9),
    ChordKind(suffix: "dim7", intervals: [0, 3, 6, 9], prior: 0.88),
    ChordKind(suffix: "aug", intervals: [0, 4, 8], prior: 0.86),
    ChordKind(suffix: "5", intervals: [0, 7], prior: 0.8),
]

struct Chord: Equatable {
    var root: Int, kind: Int, bass: Int
    var tones: [Int] { chordKinds[kind].intervals.map { (root + $0) % 12 } }
    var minor: Bool { [1, 4, 7, 8, 9].contains(kind) }
    var dominant: Bool { kind == 2 }
    var unstable: Bool { [5, 6, 7, 8, 9, 10].contains(kind) }     // suspended, diminished, augmented: wanting to move
    func same(_ o: Chord) -> Bool { root == o.root && kind == o.kind }
}

struct Key: Equatable {
    var tonic: Int, minor: Bool
    /// The seven notes of the key.
    var scale: [Int] { (minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { (tonic + $0) % 12 } }
    /// The major key on the same seven notes (A minor's is C major), which sets the arc on the wheel.
    var relativeMajor: Int { minor ? (tonic + 3) % 12 : tonic }
}

struct HeardNote {
    let id: Int
    var midi: Int
    var pitch: Float            // in MIDI numbers, fractional: a bend, a slide, vibrato
    var level: Float            // 0...1
    var onset: Double           // on the reader's clock
    var end: Double?            // when it stopped
    var player: Player
    var melody = false          // the line carrying the tune
    var bass = false            // the bassline
}

/// Everything the reader knows at one moment, handed to the picture.
struct Score {
    var time = 0.0              // the reader's clock
    var wall = 0.0              // the unix time it was at `time`
    var notes: [HeardNote] = []
    var melody: [SIMD3<Float>] = []     // the tune's last few seconds: (seconds before `time`, pitch, level)
    var chroma = [Float](repeating: 0, count: 12)   // how much of each pitch class is sounding, 0...1, by C = 0
    var chord: Chord?
    var chordAt = -9.0
    var history: [(chord: Chord, at: Double)] = []
    var key: Key?
    var loop: [Chord] = []      // the progression the song keeps returning to, once it has gone round twice
    var presence = [Float](repeating: 0, count: Player.allCases.count)
    var resolvedAt = -9.0       // a phrase landing home (V–I, IV–I, vii°–I)
    var resolveStrength: Float = 0
    var tonal: Float = 0        // how much pitched sound there is, 0...1
    /// The tune followed closely (MelodyLines), and a counter-line when there is one: the last second of each.
    var tune: [TuneLine] = []
    var tuneTime = 0.0          // the reader's clock at the end of the newest sound the lines have heard
    /// How far the record is tuned off concert pitch, semitones (a slowed record is often a third of a semitone or
    /// more flat): taken off every pitch before it is called a note.
    var tuning: Float = 0
    var rap: Float = 0          // how surely someone is rapping or speaking, not singing, 0...1
    /// Many voices singing together (a chorus, a choir, stacked harmonies) against one voice singing alone, as the
    /// classifier hears them, eased: Medicina draws a chorus as a spreading ripple of rings round the tune, a soloist as
    /// one ring. 0...1 each.
    var choir: Float = 0, solo: Float = 0

    /// How far from home the harmony is, 0 (the home chord) ... 1 (a dominant seventh, a diminished chord, a chord from outside the key).
    var tension: Float {
        guard let chord else { return 0 }
        guard let key else { return chord.unstable ? 0.6 : chord.dominant ? 0.55 : 0.25 }
        let d = (chord.root - key.tonic + 12) % 12
        var t: Float = key.minor ? [0, 0.7, 0.4, 0.2, 0.5, 0.35, 0.8, 0.6, 0.2, 0.5, 0.35, 0.8][d]
                                 : [0, 0.7, 0.4, 0.35, 0.5, 0.3, 0.8, 0.6, 0.6, 0.2, 0.5, 0.8][d]
        if chord.dominant { t += 0.2 }
        if chord.unstable { t += 0.25 }
        if !chord.tones.allSatisfy(key.scale.contains) { t += 0.25 }
        return min(1, t)
    }
}

// MARK: - The reader

/// A Hann-windowed magnitude spectrum.
private final class Spectrum {
    let n: Int, log2n: vDSP_Length, setup: FFTSetup
    var window: [Float], re: [Float], im: [Float], w: [Float], mags: [Float]

    init(log2n: Int) {
        n = 1 << log2n
        self.log2n = vDSP_Length(log2n)
        setup = vDSP_create_fftsetup(self.log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        re = [Float](repeating: 0, count: n / 2)
        im = re
        mags = re
        w = window
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The spectrum of the last `n` samples of `x`.
    func run(_ x: [Float]) {
        let size = n, fft = setup, bits = log2n
        x.withUnsafeBufferPointer { xp in
            vDSP_vmul(xp.baseAddress! + (x.count - size), 1, window, 1, &w, 1, vDSP_Length(size))
        }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, bits, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(size / 2))
            }
        }
    }
}

/// Candidate pitches and where each one's harmonics fall in a spectrum, worked out once.
private struct Candidates {
    var midi: [Float] = [], start: [Int] = [], count: [Int] = [], gSum: [Float] = []
    var lo: [Int] = [], hi: [Int] = [], g: [Float] = []

    /// From `low` to `high` (MIDI) in quarter semitones, up to `harmonics` partials each, below `ceiling` Hz.
    /// A partial's weight falls with its number (Klapuri's), so a note's own harmonics never outvote the note.
    init(low: Float, high: Float, harmonics: Int, ceiling: Double, df: Double, bins: Int) {
        var m = low
        while m <= high + 0.001 {
            let f0 = 440 * pow(2, (Double(m) - 69) / 12)
            start.append(lo.count)
            var c = 0, s: Float = 0
            for h in 1...harmonics {
                let f = f0 * Double(h)
                guard f < ceiling else { break }
                let tol = max(df * 1.0, f * 0.0145)     // a quarter tone either side
                lo.append(max(1, Int(((f - tol) / df).rounded(.down))))
                hi.append(min(bins - 2, Int(((f + tol) / df).rounded(.up))))
                let gh = Float((f0 + 27) / (f + 320))
                g.append(gh)
                s += gh
                c += 1
            }
            midi.append(m)
            count.append(c)
            gSum.append(s)
            m += 0.25
        }
    }
}

final class NoteReader {
    static let rate = 16000.0
    let hop = 512                                       // 32 ms
    private let spec = Spectrum(log2n: 12)              // 256 ms, 3.9 Hz apart: the notes
    private let specLow = Spectrum(log2n: 13)           // 512 ms, 2 Hz apart: the bassline
    private let notesIn: Candidates, bassIn: Candidates
    private var recent = [Float](repeating: 0, count: 8192)
    private var pending: [Float] = []
    private(set) var clock = 0.0
    private let hopSec: Double

    private var white = [Float](), resid = [Float](), sal = [Float](), cumul = [Double]()
    private var levelScale: Float = 6, bassScale: Float = 8, ampScale: Float = 1e-3

    private struct Track {
        var note: HeardNote
        var lastSeen: Double
        var hits = 1
        var peak: Float
        var low: Float                  // the lowest it has fallen since its peak, to catch a key struck again
        var pitches: [Float] = []
        var confirmed = false, settled = false
        var amp: Float = 0, ampPeak: Float = 0     // its actual loudness (unwhitened), to see a strike or pluck die away
    }
    private var tracks: [Track] = []
    private var nextID = 1
    private var lastPlayed: [Player: (pitch: Float, at: Double)] = [:]
    private var melodyID: Int?, melodyPitch: Float = 64, melodySeen = -9.0
    /// The tune and a counter-line, followed every 8 ms.
    let lines = MelodyLines()
    private var lineFamily: [Player] = [.voice, .synth], lineStream: [Int32] = [0, 0], lineDisagree = [0.0, 0.0]
    private var lineWander: [Float] = [8, 8], lineVib: [Float] = [0, 0], familyJudged = 0.0
    private var familyLog: [[(t: Double, family: Player)]] = [[(-1e9, .voice)], [(-1e9, .synth)]]
    private var voiceHeard: Float = 0          // a voice singing or speaking, eased quicker than `presence`
    // the record's tuning: where notes fall between the semitones, as an angle (a full turn a semitone), summed
    private var tuneC = 0.0, tuneS = 0.0, tuneW = 0.0, tunedFor = 0.0, tuneTarget: Float = 0
    private(set) var tuning: Float = 0
    private var melody: [(t: Double, pitch: Float, level: Float)] = []
    private var bassNote: (midi: Int, since: Double, seen: Double)?

    private var chromaFast = [Float](repeating: 0, count: 12), chromaChord = [Float](repeating: 0, count: 12)
    private var chromaKey = [Float](repeating: 0, count: 12)
    private var chord: Chord?, chordAt = -9.0, candidate: Chord?, candidateSince = 0.0, chordLost = 0.0
    private var history: [(chord: Chord, at: Double)] = []
    private var loop: [Chord] = []
    private var key: Key?, keyCandidate: Key?, keyCandidateSince = 0.0, keyJudged = 0.0
    private var resolvedAt = -9.0, resolveStrength: Float = 0
    private var tonal: Float = 0, quietSince = 0.0

    /// What Apple's classifier hears playing, by family (Player.rawValue), 0...1: `heard` as it reports, `presence` eased.
    var heard = [Float](repeating: 0, count: Player.allCases.count)
    /// Rapping, and speaking, shouting or whispering, as the classifier hears them, 0...1.
    var heardRap: Float = 0, heardSpeech: Float = 0
    var heardChoir: Float = 0, heardSolo: Float = 0
    private var choirNow: Float = 0, soloNow: Float = 0
    private var presence = [Float](repeating: 0, count: Player.allCases.count)

    init() {
        hopSec = Double(hop) / Self.rate
        notesIn = Candidates(low: 36, high: 96, harmonics: 16, ceiling: 7200, df: Self.rate / 4096, bins: 2048)
        bassIn = Candidates(low: 28, high: 50, harmonics: 8, ceiling: 1200, df: Self.rate / 8192, bins: 4096)
        white = [Float](repeating: 0, count: 2048)
        resid = white
        sal = [Float](repeating: 0, count: notesIn.midi.count)
        cumul = [Double](repeating: 0, count: 2049)
    }

    /// 16 kHz mono audio, in any amounts.
    func push(_ samples: UnsafeBufferPointer<Float>) {
        lines.push(samples)
        pending.append(contentsOf: samples)
        var used = 0
        while pending.count - used >= hop {
            recent.removeFirst(hop)
            recent.append(contentsOf: pending[used..<(used + hop)])
            used += hop
            clock += hopSec
            step()
        }
        pending.removeFirst(used)
    }

    func reset() {
        tracks = []; melody = []; melodyID = nil; bassNote = nil
        lines.reset()
        chromaFast = chromaFast.map { _ in 0 }; chromaChord = chromaFast; chromaKey = chromaFast
        forgetSong()
    }

    private func forgetSong() {
        chord = nil; candidate = nil; history = []; loop = []; key = nil; keyCandidate = nil
        chromaKey = chromaKey.map { _ in 0 }
        tuneC = 0; tuneS = 0; tuneW = 0; tunedFor = 0; tuneTarget = 0; tuning = 0
    }

    // MARK: Each 32 ms

    private func step() {
        var rms: Float = 0
        recent.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + (recent.count - 4096), 1, &rms, 4096) }
        let loud = 20 * log10(rms + 1e-9) > -56

        var found: [(pitch: Float, sal: Float, bass: Bool)] = []
        if loud {
            spec.run(recent)
            found = listenForNotes()
            hearTuning(found)
            specLow.run(recent)
            if let b = listenForBass() { found.append(b) }
        }
        follow(merged(found))
        pickMelody()
        hearChroma(found)
        for p in 0..<presence.count {
            let r = heard[p]
            presence[p] += (r - presence[p]) * Float(min(1, hopSec / (r > presence[p] ? 0.4 : 2.5)))
        }
        let v = max(heard[Player.voice.rawValue], 0.7 * heardSpeech)
        voiceHeard += (v - voiceHeard) * Float(min(1, hopSec / (v > voiceHeard ? 0.3 : 1.2)))
        choirNow += (heardChoir - choirNow) * Float(min(1, hopSec / (heardChoir > choirNow ? 0.5 : 2.0)))
        soloNow += (heardSolo - soloNow) * Float(min(1, hopSec / (heardSolo > soloNow ? 0.5 : 2.0)))
        lines.voicePresence = presence[Player.voice.rawValue]
        lines.rap = max(heardRap, heardSpeech)
        lines.tuning = tuning
        judgeLineFamilies()
        judgeChord()
        if clock - keyJudged > 0.5 { keyJudged = clock; judgeKey() }
        // a long quiet: the song is over, so the next one starts with no key and no history
        if tonal > 0.06 { quietSince = clock } else if clock - quietSince > 6 && (key != nil || !history.isEmpty) { forgetSong() }
    }

    /// Several notes at once, found one at a time: the pitch whose harmonics stand out most is taken, its harmonics
    /// are taken out of the spectrum, and the search goes again on what's left, until nothing stands out (Klapuri,
    /// "Multiple fundamental frequency estimation by summing harmonic amplitudes", 2006). The spectrum is whitened
    /// first, so a note is found by its pattern of harmonics, not by how loud its instrument is.
    private func listenForNotes() -> [(pitch: Float, sal: Float, bass: Bool)] {
        let X = spec.mags, bins = X.count, df = Float(Self.rate / 4096)
        for k in 0..<bins { cumul[k + 1] = cumul[k] + Double(X[k] * X[k]) }
        var sum: Float = 0
        let a0 = Int(100 / df), a1 = Int(5000 / df)
        for k in 0..<bins {
            let w = max(3, Int(Float(k) * 0.12))
            let a = max(0, k - w), b = min(bins, k + w + 1)
            let env = Float(sqrt((cumul[b] - cumul[a]) / Double(b - a))) + 1e-9
            white[k] = X[k] * pow(env, -0.67)
            if k >= a0 && k < a1 { sum += white[k] }
        }
        let mean = sum / Float(a1 - a0) + 1e-12
        for k in 0..<bins { resid[k] = white[k] / mean }

        var out: [(pitch: Float, sal: Float, bass: Bool)] = []
        var first: Float = 0
        let c = notesIn
        for _ in 0..<6 {
            var best = -1, bestS: Float = 0
            resid.withUnsafeBufferPointer { R in
                for ci in 0..<c.midi.count {
                    var s: Float = 0, h1: Float = 0, h23: Float = 0
                    let st = c.start[ci]
                    for j in 0..<c.count[ci] {
                        var m: Float = 0
                        for k in c.lo[st + j]...c.hi[st + j] where R[k] > m { m = R[k] }
                        s += c.g[st + j] * m
                        if j == 0 { h1 = m } else if j <= 2 { h23 = max(h23, m) }
                    }
                    // a note has its fundamental: this keeps a chord's harmonics from inventing a note an octave under it
                    var v = h1 >= 1.6 && h1 >= 0.3 * h23 ? s / c.gSum[ci] : 0
                    // and a note sitting exactly on a harmonic of one already found is more likely that harmonic's
                    // leftover than a note of its own: it has to stand out further
                    if v > 0, let parent = ghostOf(c.midi[ci], out) { v = v * 0.5 > 0.45 * parent ? v * 0.5 : 0 }
                    sal[ci] = v
                    if v > bestS { bestS = v; best = ci }
                }
            }
            if out.isEmpty { first = bestS }
            // above C6 few notes are real (a flute, a violin, a piano's top): most are a harmonic left over, so they need more
            guard best >= 0, bestS > 2.6 + max(0, c.midi[best] - 79) * 0.15, bestS > 0.5 * first else { break }
            out.append((refine(best, c, df), bestS, false))
            cancel(best, c)
        }
        return out
    }

    private static let harmonicSteps: [Float] = (2...8).map { 12 * log2(Float($0)) }

    /// The strength of the note already found whose harmonic `m` sits on, if it sits on one.
    private func ghostOf(_ m: Float, _ found: [(pitch: Float, sal: Float, bass: Bool)]) -> Float? {
        for f in found { for h in Self.harmonicSteps where abs(m - f.pitch - h) < 0.35 { return f.sal } }
        return nil
    }

    /// The pitch to a few cents, from where its first few harmonics actually peak.
    private func refine(_ ci: Int, _ c: Candidates, _ df: Float) -> Float {
        var num: Float = 0, den: Float = 0
        let st = c.start[ci]
        for j in 0..<min(4, c.count[ci]) {
            var kp = c.lo[st + j]
            for k in c.lo[st + j]...c.hi[st + j] where white[k] > white[kp] { kp = k }
            guard kp > 0 && kp < white.count - 1 else { continue }
            let a = white[kp - 1], b = white[kp], d = white[kp + 1]
            let den2 = a - 2 * b + d
            let shift = den2 != 0 ? 0.5 * (a - d) / den2 : 0
            let f = (Float(kp) + max(-0.5, min(0.5, shift))) * df / Float(j + 1)
            num += b * (69 + 12 * log2(f / 440))
            den += b
        }
        let p = den > 0 ? num / den : c.midi[ci]
        return abs(p - c.midi[ci]) < 0.5 ? p : c.midi[ci]
    }

    /// Takes a found note's harmonics out of what's left to search. The fundamental goes entirely; each higher
    /// harmonic only in part, by its weight, so a note an octave or a fifth above, which shares some of them, survives.
    private func cancel(_ ci: Int, _ c: Candidates) {
        let lobe: [Float] = [0.3, 0.8, 1, 0.8, 0.3]
        let st = c.start[ci]
        for j in 0..<c.count[ci] {
            var kp = c.lo[st + j]
            for k in c.lo[st + j]...c.hi[st + j] where resid[k] > resid[kp] { kp = k }
            let share = j == 0 ? 1 : min(1, 1.25 * c.g[st + j] / c.g[st])
            let a = resid[kp] * share * 0.92
            for d in -2...2 {
                let k = kp + d
                guard k >= 0 && k < resid.count else { continue }
                resid[k] = max(0, resid[k] - a * lobe[d + 2])
            }
        }
    }

    /// The bassline: one note at a time, from the long spectrum, where the low notes are far enough apart to tell.
    private func listenForBass() -> (pitch: Float, sal: Float, bass: Bool)? {
        let X = specLow.mags, df = Float(Self.rate / 8192)
        var sum: Float = 0
        let a0 = Int(30 / df), a1 = Int(1000 / df)
        for k in a0..<a1 { sum += X[k] }
        let mean = sum / Float(a1 - a0) + 1e-12
        let c = bassIn
        var best = -1, bestS: Float = 0
        X.withUnsafeBufferPointer { R in
            for ci in 0..<c.midi.count {
                var s: Float = 0, h1: Float = 0, h23: Float = 0
                let st = c.start[ci]
                for j in 0..<c.count[ci] {
                    var m: Float = 0
                    for k in c.lo[st + j]...c.hi[st + j] where R[k] > m { m = R[k] }
                    s += c.g[st + j] * m
                    if j == 0 { h1 = m } else if j <= 2 { h23 = max(h23, m) }
                }
                let v = h1 >= 0.25 * h23 ? s / c.gSum[ci] / mean : 0
                if v > bestS { bestS = v; best = ci }
            }
        }
        guard best >= 0, bestS > 5 else { bassNote = nil; return nil }
        // a kick thumps once; a bass note holds: it has to win twice running
        let m = Int((c.midi[best] - tuning).rounded())
        if let b = bassNote, abs(b.midi - m) <= 0 {
            bassNote?.seen = clock
        } else {
            bassNote = (m, clock, clock)
            return nil
        }
        bassScale = max(bassScale * 0.999, bestS)
        return (c.midi[best], bestS / bassScale * levelScale, true)
    }

    // MARK: Notes held over time

    /// The two listeners overlap (A2–A3): the same note found by both counts once.
    private func merged(_ found: [(pitch: Float, sal: Float, bass: Bool)]) -> [(pitch: Float, sal: Float, bass: Bool)] {
        var out: [(pitch: Float, sal: Float, bass: Bool)] = []
        for d in found.sorted(by: { $0.sal > $1.sal }) {
            if let i = out.firstIndex(where: { abs($0.pitch - d.pitch) < 0.5 }) { out[i].bass = out[i].bass || d.bass } else { out.append(d) }
        }
        return out
    }

    private func follow(_ found: [(pitch: Float, sal: Float, bass: Bool)]) {
        if let top = found.filter({ !$0.bass }).map(\.sal).max() { levelScale = max(levelScale * 0.9985, top) }
        var seen = Set<Int>()
        for d in found {
            // how loud: half how clearly it stands out, half its real loudness against the loudest note lately
            let amp = rawAmp(d.pitch, bass: d.bass)
            ampScale = max(ampScale * 0.9985, amp)
            let level = min(1, 0.45 * pow(d.sal / levelScale, 0.7) + 0.55 * sqrt(amp / ampScale))
            var bestI: Int?, bestD: Float = 0.6
            for (i, t) in tracks.enumerated() where t.note.end == nil && !seen.contains(i) {
                let dd = abs(t.note.pitch - d.pitch)
                if dd < bestD { bestD = dd; bestI = i }
            }
            if let i = bestI {
                seen.insert(i)
                var t = tracks[i]
                // struck again: a piano key repeated, a string plucked again
                if t.settled && t.note.player.struck && level > 1.5 * t.low && level - t.low > 0.2 && clock - t.note.onset > 0.15 {
                    t.note.end = clock
                    tracks[i] = t
                    tracks.append(newTrack(d, level))
                    seen.insert(tracks.count - 1)
                    continue
                }
                t.lastSeen = clock
                t.hits += 1
                t.note.pitch += (d.pitch - t.note.pitch) * 0.6
                t.note.midi = Int((t.note.pitch - tuning).rounded())
                t.note.level += (level - t.note.level) * (level > t.note.level ? 0.7 : 0.35)
                t.note.bass = t.note.bass || d.bass
                if t.note.level > t.peak { t.peak = t.note.level; t.low = t.note.level } else { t.low = min(t.low, t.note.level) }
                t.amp = amp
                t.ampPeak = max(t.ampPeak, t.amp)
                t.pitches.append(d.pitch)
                if t.pitches.count > 16 { t.pitches.removeFirst() }
                tracks[i] = t
            } else {
                tracks.append(newTrack(d, level))
                seen.insert(tracks.count - 1)
            }
        }
        for i in tracks.indices where tracks[i].note.end == nil && !seen.contains(i) {
            tracks[i].note.level *= 0.8
            if clock - tracks[i].lastSeen > 0.11 { tracks[i].note.end = tracks[i].lastSeen + hopSec }
        }
        // a note is heard once it has been found twice running; until then it may be a passing ghost
        tracks.removeAll { !$0.confirmed && $0.note.end != nil }
        for i in tracks.indices {
            if !tracks[i].confirmed && tracks[i].hits >= 3 {
                tracks[i].confirmed = true
                tracks[i].note.player = choose(tracks[i], struck: nil)
            }
            // a quarter second in, how it has held tells a strike or pluck (dying away) from a bow, breath or key (held)
            if tracks[i].confirmed && !tracks[i].settled && clock - tracks[i].note.onset >= 0.22 {
                tracks[i].settled = true
                // a strike or pluck has lost a fifth of its loudness by now; a bow, breath or synth key holds it
                let struck = tracks[i].amp < 0.8 * tracks[i].ampPeak
                tracks[i].note.player = choose(tracks[i], struck: struck)
                lastPlayed[tracks[i].note.player] = (tracks[i].note.pitch, clock)
            }
        }
        tracks.removeAll { $0.note.end.map { clock - $0 > 1.5 } ?? false }
        if tracks.count > 48 { tracks.removeFirst(tracks.count - 48) }
    }

    private func newTrack(_ d: (pitch: Float, sal: Float, bass: Bool), _ level: Float) -> Track {
        defer { nextID += 1 }
        let a = rawAmp(d.pitch, bass: d.bass)
        return Track(note: HeardNote(id: nextID, midi: Int((d.pitch - tuning).rounded()), pitch: d.pitch, level: level, onset: clock - hopSec,
                                     player: .synth, bass: d.bass),
                     lastSeen: clock, peak: level, low: level, pitches: [d.pitch], amp: a, ampPeak: a)
    }

    /// How loud a note at `pitch` is in this frame's plain (unwhitened) spectrum: its first three harmonics.
    private func rawAmp(_ pitch: Float, bass: Bool) -> Float {
        let X = bass ? specLow.mags : spec.mags
        let df = Float(Self.rate) / Float(bass ? 8192 : 4096)
        let f0 = 440 * pow(2, (pitch - 69) / 12)
        var s: Float = 0
        for h in 1...3 {
            let k = Int((f0 * Float(h) / df).rounded())
            guard k > 1 && k < X.count - 2 else { continue }
            s += max(X[k - 1], X[k], X[k + 1])
        }
        return s
    }

    /// Which family a note most likely belongs to: who the classifier hears playing, whether the note sits in
    /// that family's range, whether it was struck or held, whether it carries the tune or the bassline, and
    /// whether that family was just playing near it. A best guess: the sound of one note can't be pulled out of a mix.
    private func choose(_ t: Track, struck: Bool?) -> Player {
        let m = t.note.pitch
        var vibrato: Float = 0
        if t.pitches.count >= 6 {
            let mean = t.pitches.reduce(0, +) / Float(t.pitches.count)
            vibrato = sqrt(t.pitches.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(t.pitches.count))
        }
        var best = Player.synth, bestScore: Float = -1
        let bassline = t.note.bass || m < 50
        for p in Player.allCases {
            // a bassline is most likely a bass, even when the classifier can't pick one out of the mix
            // the classifier's surest family counts for clearly more than the runners-up
            var s = (p == .bass && bassline ? 0.3 : 0.04) + pow(presence[p.rawValue], 1.5)
            if m < p.range.lowerBound - 3 || m > p.range.upperBound + 3 { s *= 0.05 } else if !p.range.contains(m) { s *= 0.4 }
            if let struck, p != .bass { s *= struck == p.struck ? 1 : 0.6 }
            if t.note.melody || t.note.id == melodyID { if p == .voice { s *= 2.2 } } else if p == .voice { s *= 0.6 }
            // low notes are a bassline's when a bass is heard; with none (a piano's left hand), much less so
            if bassline { if p == .bass { s *= 2 + min(1, presence[p.rawValue] * 3) } } else if p == .bass { s *= 0.25 }
            if vibrato > 0.1 && (p == .voice || p == .strings) { s *= 1.5 }
            if let last = lastPlayed[p], abs(last.pitch - m) <= 7, clock - last.at < 1.5 { s *= 1.3 }
            if s > bestScore { bestScore = s; best = p }
        }
        return best
    }

    /// The tune (MelodyLines follows it): its last few seconds kept for the picture, and the note it is on marked, so
    /// the keyboard knows which of its notes is the tune.
    private func pickMelody() {
        #if DEBUG       // (the melody bench reads it; the picture reads the lines themselves)
        for f in lines.fresh where f.flags & TuneFrame.voiced != 0 { melody.append((f.t, f.pitch, f.level)) }
        melody.removeAll { clock - $0.t > 3 }
        #endif
        lines.fresh.removeAll(keepingCapacity: true)
        for i in tracks.indices { tracks[i].note.melody = false }
        guard let f = lines.lead.last, f.flags & TuneFrame.voiced != 0, f.conf >= 0.5 else {
            if clock - melodySeen > 6 { melodyPitch = 64; melodyID = nil }
            return
        }
        var best: Int?, bd: Float = 0.6
        for (i, t) in tracks.enumerated() where t.note.end == nil && !t.note.bass {
            let d = abs(t.note.pitch - f.pitch)
            if d < bd { bd = d; best = i }
        }
        guard let i = best else { return }
        // a singer's note heard before the classifier has had its say about it
        if lineFamily[0] == .voice && tracks[i].note.player != .voice && !tracks[i].settled { tracks[i].note.player = .voice }
        tracks[i].note.melody = true
        melodyID = tracks[i].note.id
        melodyPitch = tracks[i].note.pitch
        melodySeen = clock
    }

    /// Who is playing the tune and the counter-line: a voice (the classifier hears one, and the line wavers or has
    /// vibrato, as a voice does), or the instrument whose notes the reader hears right on the line, or a synth (steady
    /// as a synth is). Changed only where the line moves to a new sound, or after a second of steady disagreement, and
    /// only for a clearly better answer, so a line keeps its petals.
    private func judgeLineFamilies() {
        // the tune and the counter-line traded places: each keeps its own family, from the moment they traded
        for t in lines.swapAt {
            let (a, b) = (lineFamily[0], lineFamily[1])
            setFamily(0, b, from: t); setFamily(1, a, from: t)
            lineStream.swapAt(0, 1); lineWander.swapAt(0, 1); lineVib.swapAt(0, 1); lineDisagree.swapAt(0, 1)
        }
        lines.swapAt.removeAll()
        let roles = [lines.lead, lines.counter]
        let wander = [lines.leadWander, lines.counterWander]
        let vib = [lines.leadVib.depth, lines.counterVib.depth]
        let k = Float(min(1, hopSec / 0.5))
        for r in 0..<2 where roles[r].last.map({ $0.flags & TuneFrame.voiced != 0 }) ?? false {
            lineWander[r] += (wander[r] - lineWander[r]) * k
            lineVib[r] += ((vib[r] > 0 ? 1 : 0) - lineVib[r]) * k
        }
        guard clock - familyJudged >= 0.25 else { return }
        let dt = clock - familyJudged
        familyJudged = clock
        func sat(_ x: Float) -> Float { min(1, max(0, x)) }
        for r in 0..<2 {
            let voicedFrames = roles[r].filter { $0.flags & TuneFrame.voiced != 0 }
            guard let last = voicedFrames.last else { continue }
            // where the line is now: the middle of its last 64 ms (a moving line's average falls between its notes)
            let recent = voicedFrames.suffix(8).map(\.pitch).sorted()
            let centre = recent[recent.count / 2]
            var score = [Float](repeating: 0, count: Player.allCases.count)
            if centre >= 40 && centre <= 86 {
                score[Player.voice.rawValue] = (0.05 + voiceHeard) * (0.6 + 0.4 * sat((lineWander[r] - 4) / 12) + 0.4 * lineVib[r])
            }
            for t in tracks where t.confirmed && t.note.end == nil && !t.note.bass && t.note.player != .voice {
                let d = abs(t.note.pitch - centre)
                guard d < 0.6 || abs(d - 12) < 0.6 else { continue }
                let p = t.note.player.rawValue
                score[p] = max(score[p], 1.2 * (0.05 + presence[p]))
            }
            let sy = Player.synth.rawValue
            score[sy] = max(score[sy], (0.05 + presence[sy]) * (0.6 + 0.4 * sat((8 - lineWander[r]) / 6)))
            score[Player.bass.rawValue] = 0
            var best = 0
            for p in score.indices where score[p] > score[best] { best = p }
            let cur = lineFamily[r].rawValue
            // nothing heard clearly enough to say: it stays who it was
            if score[best] < 0.15 { lineStream[r] = last.stream; continue }
            if best == cur || score[best] < 1.3 * score[cur] { lineDisagree[r] = 0; lineStream[r] = last.stream; continue }
            lineDisagree[r] += dt
            if last.stream != lineStream[r] || lineDisagree[r] >= 1 {
                // from where its new sound began (the picture is drawing a little behind), or from now
                var from = last.t
                if last.stream != lineStream[r], let i = roles[r].lastIndex(where: { $0.stream != last.stream }) { from = roles[r][min(roles[r].count - 1, i + 1)].t }
                setFamily(r, Player(rawValue: best)!, from: from)
                lineDisagree[r] = 0
            }
            lineStream[r] = last.stream
        }
    }

    private func setFamily(_ r: Int, _ f: Player, from t: Double) {
        lineFamily[r] = f
        familyLog[r].append((t, f))
        // the last two seconds (the frames the picture can still be drawing), and the entry in force before them
        if let i = familyLog[r].lastIndex(where: { $0.t < clock - 2 }), i > 0 { familyLog[r].removeFirst(i) }
    }

    /// The record's own tuning: where the notes it hears fall between the semitones, averaged as angles over the last
    /// twenty seconds or so. Taken as the tuning once the notes agree (a record slowed down sits between the keys),
    /// left at concert pitch for a record within a tenth of a semitone of it, and eased in, so the keys never jump.
    private func hearTuning(_ found: [(pitch: Float, sal: Float, bass: Bool)]) {
        let forget = exp(-hopSec / 20)
        tuneC *= forget; tuneS *= forget; tuneW *= forget
        let top = found.lazy.filter { !$0.bass }.map(\.sal).max() ?? 0
        for d in found where !d.bass && d.sal >= 0.5 * top {
            let a = 2 * Double.pi * Double(d.pitch - d.pitch.rounded())
            tuneC += cos(a) * Double(d.sal); tuneS += sin(a) * Double(d.sal); tuneW += Double(d.sal)
        }
        if tonal > 0.06 { tunedFor += hopSec }
        if tuneW > 0 && tunedFor > 8 && (tuneC * tuneC + tuneS * tuneS).squareRoot() / tuneW > 0.35 {
            let est = Float(atan2(tuneS, tuneC) / (2 * Double.pi))
            tuneTarget = abs(est) < 0.10 ? 0 : est
        }
        // the short way round (−0.5 and +0.5 are the same tuning), so it never flips
        var d = tuneTarget - tuning
        d -= d.rounded()
        tuning += d * Float(min(1, hopSec / 3))
    }

    // MARK: Harmony

    private func hearChroma(_ found: [(pitch: Float, sal: Float, bass: Bool)]) {
        var c = [Float](repeating: 0, count: 12)
        var total: Float = 0
        for d in found {
            let level = min(1, pow(d.sal / levelScale, 0.7)) * (d.bass ? 1.3 : d.pitch > 84 ? 0.5 : 1)
            c[((Int((d.pitch - tuning).rounded()) % 12) + 12) % 12] += level
            total += level
        }
        tonal += (min(1, total / 2) - tonal) * 0.15
        let top = max(1, c.max() ?? 1)
        for k in 0..<12 {
            let v = c[k] / top
            chromaFast[k] += (v - chromaFast[k]) * Float(min(1, hopSec / (v > chromaFast[k] ? 0.05 : 0.25)))
            chromaChord[k] += (c[k] - chromaChord[k]) * Float(min(1, hopSec / 0.3))
            // the key: what has sounded over the last half minute or so, the bass counting a little more
            chromaKey[k] = chromaKey[k] * Float(exp(-hopSec / 10)) + (total > 0 ? c[k] / total : 0) * min(1, total) * Float(hopSec)
        }
    }

    private func judgeChord() {
        let c = chromaChord
        let norm = sqrt(c.reduce(0) { $0 + $1 * $1 })
        guard norm > 0.25 else {
            // silence or drums only: the chord is let go after a moment
            if chord != nil && clock - chordLost > 1.2 { chord = nil }
            return
        }
        chordLost = clock
        let bassPC = bassNote.map { $0.midi % 12 }
        var best: Chord?, bestS: Float = 0
        for root in 0..<12 {
            for (k, kind) in chordKinds.enumerated() {
                var dot: Float = 0, w2: Float = 0
                for iv in kind.intervals {
                    let w: Float = iv == 7 ? 0.8 : 1
                    dot += w * c[(root + iv) % 12]
                    w2 += w * w
                }
                var s = dot / (sqrt(w2) * norm) * kind.prior
                if let b = bassPC {
                    let iv = (b - root + 12) % 12
                    s += iv == 0 ? 0.06 : (kind.intervals.contains(iv) ? 0.015 : -0.03)
                }
                if let key, kind.intervals.allSatisfy({ key.scale.contains((root + $0) % 12) }) { s += 0.03 }
                if let chord, chord.root == root && chord.kind == k { s += 0.05 }
                if s > bestS {
                    bestS = s
                    let b = bassPC.flatMap { b in kind.intervals.contains((b - root + 12) % 12) ? b : nil } ?? root
                    best = Chord(root: root, kind: k, bass: b)
                }
            }
        }
        guard let best, bestS > 0.72 else { return }
        if let chord, chord.same(best) { self.chord?.bass = best.bass; candidate = nil; return }
        // a new chord has to hold a moment, so a passing note doesn't count as a change
        if let cand = candidate, cand.same(best) {
            if clock - candidateSince >= 0.25 { commit(best) }
        } else {
            candidate = best
            candidateSince = clock
        }
    }

    private func commit(_ new: Chord) {
        chord = new
        chordAt = candidateSince
        candidate = nil
        history.append((new, chordAt))
        if history.count > 32 { history.removeFirst() }
        // the progression as it would be written: the chords that held at least half a second (not the blur of
        // one changing into the next), a chord's colour (a seventh, a sus) not counting as a change of chord
        var seq: [Chord] = []
        for (i, h) in history.enumerated() {
            let held = i + 1 < history.count ? history[i + 1].at - h.at : 9
            guard held >= 0.7 else { continue }
            if let last = seq.last, last.root == h.chord.root && last.minor == h.chord.minor { continue }
            seq.append(h.chord)
        }
        // coming home: V or V7 to I, vii° to I, IV to I
        if let key, seq.count >= 2, let last = seq.last, last.same(new), new.root == key.tonic, new.minor == key.minor {
            let old = seq[seq.count - 2], d = (old.root - key.tonic + 12) % 12
            if d == 7 { resolveStrength = old.dominant ? 1 : 0.8; resolvedAt = chordAt }
            else if d == 11 && old.unstable { resolveStrength = 0.9; resolvedAt = chordAt }
            else if d == 5 { resolveStrength = 0.5; resolvedAt = chordAt }
        }
        // the loop: the shortest run of chords that has just come round twice in a row
        loop = []
        let n = seq.count
        for p in [2, 3, 4, 5, 6, 8] where n >= 2 * p {
            if (0..<p).allSatisfy({ seq[n - 1 - $0].root == seq[n - 1 - $0 - p].root && seq[n - 1 - $0].minor == seq[n - 1 - $0 - p].minor }) {
                loop = Array(seq[(n - p)...])
                break
            }
        }
    }

    /// The key, by how well what has sounded fits each of the 24 (Krumhansl and Kessler's profiles), and how many
    /// of the last chords belong to it, the home chord most of all. A new key has to fit clearly better for a
    /// couple of seconds before it takes over (a modulation, a new song).
    private func judgeKey() {
        let total = chromaKey.reduce(0, +)
        guard total > 2.5 else { return }
        let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        // the last twelve seconds of chords, each by how long it held
        var recent: [(chord: Chord, held: Float)] = []
        for (i, h) in history.enumerated() where clock - h.at < 12 {
            recent.append((h.chord, Float((i + 1 < history.count ? history[i + 1].at : clock) - h.at)))
        }
        let heldTotal = recent.reduce(0) { $0 + $1.held }
        func corr(_ k: Key) -> Float {
            let prof = k.minor ? minor : major
            let x = (0..<12).map { chromaKey[(k.tonic + $0) % 12] }
            let mx = x.reduce(0, +) / 12, mp = prof.reduce(0, +) / 12
            var num: Float = 0, dx: Float = 0, dp: Float = 0
            for i in 0..<12 { num += (x[i] - mx) * (prof[i] - mp); dx += (x[i] - mx) * (x[i] - mx); dp += (prof[i] - mp) * (prof[i] - mp) }
            var r = num / (sqrt(dx * dp) + 1e-9)
            if heldTotal > 2 {
                let scale = k.scale
                var fit: Float = 0, home: Float = 0
                for c in recent {
                    if c.chord.tones.allSatisfy(scale.contains) { fit += c.held }
                    if c.chord.root == k.tonic && c.chord.minor == k.minor { home += c.held }
                }
                r += 0.35 * fit / heldTotal + 0.25 * min(1, 3 * home / heldTotal)
            }
            return r
        }
        var best = Key(tonic: 0, minor: false), bestR: Float = -2
        for t in 0..<12 { for m in [false, true] { let k = Key(tonic: t, minor: m), r = corr(k); if r > bestR { bestR = r; best = k } } }
        guard let key else {
            if bestR > 0.75 { self.key = best }
            return
        }
        guard best != key, bestR > corr(key) + 0.06 else { keyCandidate = nil; return }
        if keyCandidate == best {
            if clock - keyCandidateSince >= 2.5 { self.key = best; keyCandidate = nil }
        } else {
            keyCandidate = best
            keyCandidateSince = clock
        }
    }

    // MARK: Handing it over

    func score(wall: Double) -> Score {
        var s = Score()
        s.time = clock
        s.wall = wall
        s.notes = tracks.filter(\.confirmed).map(\.note)
        s.melody = melody.map { SIMD3(Float(clock - $0.t), $0.pitch, $0.level) }
        s.chroma = chromaFast
        s.chord = chord
        s.chordAt = chordAt
        s.history = history
        s.key = key
        s.loop = loop
        s.presence = presence
        s.resolvedAt = resolvedAt
        s.resolveStrength = resolveStrength
        s.tonal = tonal
        s.tune = [TuneLine(role: 0, family: lineFamily[0], familyAt: familyLog[0], frames: lines.lead, vibDepth: lines.leadVib.depth, vibRate: lines.leadVib.rate),
                  TuneLine(role: 1, family: lineFamily[1], familyAt: familyLog[1], frames: lines.counter, vibDepth: lines.counterVib.depth, vibRate: lines.counterVib.rate)]
        s.tuneTime = lines.t
        s.tuning = tuning
        s.rap = max(heardRap, heardSpeech)
        s.choir = choirNow; s.solo = soloNow
        return s
    }
}
