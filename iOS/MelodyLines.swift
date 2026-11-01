import Accelerate
import Foundation

/// One moment of a line of the tune, every 8 ms.
struct TuneFrame {
    var t: Double           // on the reader's clock: the middle of the 48 ms it was heard in
    var pitch: Float        // MIDI, fractional, as heard: bends, slides and vibrato all in it (not tuned)
    var conf: Float         // how sure the line is there, 0...1
    var level: Float        // how loud, 0...1
    var stream: Int32       // which unbroken stretch of sound it is: a new one when the line moves to another sound
    var flags: UInt8        // TuneFrame.voiced, .onset, .rapped
    static let voiced: UInt8 = 1, onset: UInt8 = 2, rapped: UInt8 = 4
}

/// A line of the tune over the last second: the tune itself, or a second line against it.
struct TuneLine {
    var role: UInt8 = 0                 // 0 the tune, 1 a counter-line
    var family: Player = .voice         // who is playing it now
    var familyAt: [(t: Double, family: Player)] = []    // and from when (on the frames' clock), the last two seconds
    var frames: [TuneFrame] = []        // the last second, oldest first, its quiet moments included
    var vibDepth: Float = 0             // its vibrato: semitones either side (0 for none) ...
    var vibRate: Float = 0              // ... and how fast, Hz

    /// Who was playing it at the moment `t` (the picture draws a little behind the newest sound).
    func family(at t: Double) -> Player { familyAt.last(where: { $0.t <= t })?.family ?? family }
}

/// The tune, followed closely: every 8 ms, from the last 48 ms of sound, so a vocal's slides, scoops, vibrato and
/// runs, a synth lead's bends and an arpeggio's notes are all caught as they happen (NoteReader's notes listen over a
/// quarter second, and so smooth the line into steps). Melodia-style (Salamon and Gómez, "Melody extraction from
/// polyphonic music signals using pitch contour characteristics", 2012): the spectrum's peaks vote for the pitches
/// they could be harmonics of, on a 10-cent grid; the strongest pitches are followed from moment to moment as streams;
/// the tune is the stream that is strong, carries on from where the tune was, and moves like a voice (vibrato,
/// scoops), weighed against being an overtone of a real note an octave under it. It goes quiet when the tune rests.
/// A second line (a counter-melody, a call and response) is kept when one moves clearly apart from the tune.
final class MelodyLines {
    static let rate: Float = 16000
    static let hop = 128, win = 768, nfft = 2048
    private static let log2n: vDSP_Length = 11
    private static let lo: Float = 38, res: Float = 0.1, nb = 600
    private let hopSec = Double(MelodyLines.hop) / Double(MelodyLines.rate)
    /// From the end of the window to its middle, where a frame's moment is.
    private let centre = Double(MelodyLines.win / 2) / Double(MelodyLines.rate)

    private let setup: FFTSetup
    private var window: [Float], wbuf: [Float], re: [Float], im: [Float], mag: [Float], wgt: [Float], db: [Float]
    private var ring: [Float], ringAt = 0, sinceHop = 0
    private var S: [Float], prevS: [Float], cos2: [Float]
    private var pf: [Float] = [], pa: [Float] = []
    private var cands: [Cand] = [], peakList: [(Float, Float)] = [], scores: [Float] = []
    private var scale: Float = 1e-6
    private let scaleDecay: Float
    /// The reader's clock, at the end of the newest window.
    private(set) var t = 0.0

    /// Set by NoteReader as it hears them: how surely a voice is singing (Apple's classifier, eased), and rapping or
    /// speaking.
    var voicePresence: Float = 0
    var rap: Float = 0
    /// The record's tuning (NoteReader's), semitones off concert pitch.
    var tuning: Float = 0

    private struct Cand { var p: Float; var s: Float; var used = false }
    private struct Stream {
        var id: Int, pitch: Float, slope: Float = 0, born: Double, seen: Double
        var sal: Float, salLong: Float
        var hist: [Float]                   // the last 48 pitches (384 ms)
        var bornRise: Float                 // how much it rose out of the frame before as it was born: a note, not a tail
        var rose = false                    // it has grown since it was born (a reverb tail only fades)
        var salAgo: (Float, Float, Float) = (0, 0, 0)   // its salience 8, 16 and 24 ms ago
        var lastOnset = -9.0
        var v: Float { 0.5 * sal + 0.5 * salLong }
    }
    private var streams: [Stream] = []
    private var nextID = 1
    private var leadID: Int?, leadPitch: Float = 62, lastLeadT = -9.0
    private var voiced = false, belowSince = 0.0, aboveCount = 0
    private var challenger: Int?, challengeN = 0
    private var lastVoicedT = -9.0, lastOnsetT = -9.0
    private var counterID: Int?, counterHist: [(t: Double, p: Float)] = [], counterOnsets: [Double] = []

    /// The last second of each line, oldest first (role 0 the tune, 1 the counter-line).
    private(set) var lead: [TuneFrame] = [], counter: [TuneFrame] = []
    private(set) var leadVib: (depth: Float, rate: Float) = (0, 0), counterVib: (depth: Float, rate: Float) = (0, 0)
    /// The tune's frames since NoteReader last took them.
    var fresh: [TuneFrame] = []
    /// When the tune and the counter-line traded places (frame times, until NoteReader takes them), so each keeps its
    /// own family from that moment.
    var swapAt: [Double] = []
    /// How the tune's stream wanders, cents (detrended, over the last quarter second): a voice's is wide, a synth's narrow.
    private(set) var leadWander: Float = 0
    private(set) var counterWander: Float = 0

    init() {
        scaleDecay = pow(0.5, Float(Double(Self.hop) / Double(Self.rate)) / 4)      // forgets the loudest over 4 s
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: Self.win)
        vDSP_hann_window(&window, vDSP_Length(Self.win), Int32(vDSP_HANN_NORM))
        wbuf = [Float](repeating: 0, count: Self.nfft)
        re = [Float](repeating: 0, count: Self.nfft / 2); im = re; mag = re; db = re; wgt = re
        // a voice's band: rolling off under 150 Hz (the bass and the kick) and over 5 kHz (the hats)
        let df = Self.rate / Float(Self.nfft)
        for k in 0..<(Self.nfft / 2) {
            let f = max(1, Float(k) * df)
            wgt[k] = (f / 150) * (f / 150) / sqrt(1 + pow(f / 150, 4)) / sqrt(1 + pow(f / 5000, 4))
        }
        ring = [Float](repeating: 0, count: Self.win)
        S = [Float](repeating: 0, count: Self.nb); prevS = S
        cos2 = (0...200).map { i in let d = Float(i - 100) / 100; let c = cos(d * .pi / 2); return c * c }
        pf.reserveCapacity(1024); pa.reserveCapacity(1024); peakList.reserveCapacity(1024); cands.reserveCapacity(64)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// 16 kHz mono audio, in any amounts.
    func push(_ x: UnsafeBufferPointer<Float>) {
        for v in x {
            ring[ringAt] = v
            ringAt = ringAt == Self.win - 1 ? 0 : ringAt + 1
            sinceHop += 1
            if sinceHop == Self.hop {
                sinceHop = 0
                t += hopSec
                step()
            }
        }
    }

    func reset() {
        streams = []; leadID = nil; voiced = false; aboveCount = 0; challenger = nil; challengeN = 0
        counterID = nil; counterHist = []; counterOnsets = []
        lead = []; counter = []; fresh = []; leadVib = (0, 0); counterVib = (0, 0)
    }

    // MARK: Each 8 ms

    private func step() {
        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(Self.win))
        cands.removeAll(keepingCapacity: true)
        if 20 * log10(rms + 1e-9) > -56 {
            spectrum()
            peaks()
            salience()
            let smax = S.max() ?? 0
            scale = max(scale * scaleDecay, smax)
            candidates(smax)
        } else {
            for j in 0..<Self.nb { S[j] = 0 }
        }
        track()
        choose()
        swap(&S, &prevS)
    }

    private func spectrum() {
        let n = Self.nfft, w = Self.win
        for i in 0..<w {
            let j = ringAt + i
            wbuf[i] = ring[j < w ? j : j - w] * window[i]
        }
        for i in w..<n { wbuf[i] = 0 }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                wbuf.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
        for k in 0..<(n / 2) { let m = mag[k] * wgt[k]; mag[k] = m; db[k] = 20 * log10(m + 1e-9) }
    }

    /// The spectrum's peaks below 7.6 kHz and within 40 dB of the loudest, at most 80, each placed between bins.
    private func peaks() {
        pf.removeAll(keepingCapacity: true); pa.removeAll(keepingCapacity: true); peakList.removeAll(keepingCapacity: true)
        let df = Self.rate / Float(Self.nfft)
        let kmax = Int(7600 / df)
        var mx: Float = -200
        for k in 2..<kmax where db[k] > mx { mx = db[k] }
        for k in 2..<kmax where mag[k] > mag[k - 1] && mag[k] >= mag[k + 1] && db[k] > mx - 40 {
            let a = db[k - 1], b = db[k], c = db[k + 1]
            let den = a - 2 * b + c
            let d = den != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / den)) : 0
            peakList.append(((Float(k) + d) * df, pow(10, (b - 0.25 * (a - c) * d) / 20)))
        }
        if peakList.count > 80 { peakList.sort { $0.1 > $1.1 }; peakList.removeLast(peakList.count - 80) }
        for (f, a) in peakList { pf.append(f); pa.append(a) }
    }

    /// Each peak votes for every pitch it could be the 1st…20th harmonic of, less for higher harmonics, spread over a
    /// semitone either side.
    private func salience() {
        let nbins = Self.nb, lo = Self.lo, res = Self.res
        S.withUnsafeMutableBufferPointer { Sp in
            for j in 0..<nbins { Sp[j] = 0 }
            cos2.withUnsafeBufferPointer { C in
                for i in 0..<pf.count {
                    let f = pf[i]
                    var w: Float = pa[i]
                    for h in 1...20 {
                        let m0 = 69 + 12 * log2(f / Float(h) / 440)
                        if m0 < lo - 1 { break }
                        let b = (m0 - lo) / res
                        if b > Float(nbins) + 10 { w *= 0.8; continue }
                        let j0 = max(0, Int((b - 10).rounded(.up))), j1 = min(nbins - 1, Int((b + 10).rounded(.down)))
                        if j0 <= j1 { for j in j0...j1 { Sp[j] += w * C[Int(((Float(j) - b) * 10).rounded()) + 100] } }
                        w *= 0.8
                    }
                }
            }
        }
    }

    /// The pitches standing out: up to ten, each marked down if its fundamental is missing or it has only even
    /// harmonics (both the mark of a ghost an octave under a real note).
    private func candidates(_ smax: Float) {
        guard smax > 0 else { return }
        for j in 1..<(Self.nb - 1) where S[j] > S[j - 1] && S[j] >= S[j + 1] && S[j] >= 0.08 * smax {
            let a = S[j - 1], b = S[j], d0 = S[j + 1]
            let den = a - 2 * b + d0
            let d = den != 0 ? max(-0.5, min(0.5, 0.5 * (a - d0) / den)) : 0
            let p = Self.lo + (Float(j) + d) * Self.res
            var s = b
            let f0 = 440 * pow(2, (p - 69) / 12)
            if f0 > 110 {       // (under 110 Hz a phone's speaker may not have the fundamental at all)
                var has = false
                for f in pf where abs(12 * log2(f / f0)) < 0.5 { has = true; break }
                if !has { s *= 0.6 }
            }
            var odd: Float = 0, even: Float = 0
            for (i, f) in pf.enumerated() {
                let h = f / f0, hr = h.rounded()
                guard hr >= 1 && hr <= 6 && abs(12 * log2(h / hr)) < 0.4 else { continue }
                if Int(hr) % 2 == 1 { odd = max(odd, pa[i] * (hr == 1 ? 1 : 0.7)) } else { even = max(even, pa[i]) }
            }
            if odd / max(1e-9, odd + even) < 0.2 { s *= 0.5 }
            cands.append(Cand(p: p, s: s / scale))
        }
        cands.sort { $0.s > $1.s }
        if cands.count > 10 { cands.removeLast(cands.count - 10) }
    }

    /// Carries each stream on to the candidate nearest where it was heading; what's left over starts new streams.
    private func track() {
        streams.sort { $0.sal > $1.sal }
        for i in streams.indices {
            var s = streams[i]
            let gapF = Float((t - s.seen) / hopSec)
            let pred = s.pitch + s.slope * min(gapF, 3)
            var best = -1, bd = 0.6 + min(1.0, 2.5 * abs(s.slope))
            for (k, c) in cands.enumerated() where !c.used {
                let d = abs(c.p - pred)
                if d < bd { bd = d; best = k }
            }
            s.salAgo = (s.sal, s.salAgo.0, s.salAgo.1)
            if best >= 0 {
                let c = cands[best]
                cands[best].used = true
                s.slope = 0.6 * s.slope + 0.4 * (c.p - s.pitch) / max(1, gapF)
                s.pitch = c.p
                let was = s.sal
                s.sal += (c.s - s.sal) * 0.3
                s.salLong += (c.s - s.salLong) * 0.03
                if s.sal > was * 1.05 && t - s.born > 0.03 { s.rose = true }
                s.seen = t
                s.hist.append(c.p)
                if s.hist.count > 48 { s.hist.removeFirst() }
            } else {
                s.sal *= 0.7
                s.slope *= 0.8
            }
            streams[i] = s
        }
        streams.removeAll { t - $0.seen > 0.1 }
        let fm = cands.first?.s ?? 0
        for c in cands where !c.used && c.s >= 0.3 * fm {
            let j = Int(((c.p - Self.lo) / Self.res).rounded())
            let before = j >= 0 && j < Self.nb ? prevS[j] / scale : 0
            let rise = max(0, min(1, (c.s - before) / max(1e-6, c.s)))
            var h: [Float] = []
            h.reserveCapacity(49)
            h.append(c.p)
            streams.append(Stream(id: nextID, pitch: c.p, born: t, seen: t, sal: c.s, salLong: c.s * 0.5, hist: h, bornRise: rise))
            nextID += 1
        }
        if streams.count > 12 { streams.sort { $0.sal > $1.sal }; streams.removeLast(streams.count - 12) }
    }

    /// How a stream's pitch wanders about its course over the last quarter second, in cents: a voice's wavers, a
    /// synth's or an autotuned voice's holds.
    private func wander(_ h: [Float]) -> Float {
        let n = min(32, h.count)
        guard n >= 8 else { return 0 }
        let o = h.count - n
        var sx: Float = 0, sy: Float = 0, sxx: Float = 0, sxy: Float = 0
        for i in 0..<n { let x = Float(i), y = h[o + i]; sx += x; sy += y; sxx += x * x; sxy += x * y }
        let fn = Float(n)
        let b = (fn * sxy - sx * sy) / max(1e-6, fn * sxx - sx * sx), a = (sy - b * sx) / fn
        var e: Float = 0
        for i in 0..<n { let r = h[o + i] - (a + b * Float(i)); e += r * r }
        return 100 * sqrt(e / fn)
    }

    /// How much of the last quarter second a stream spent on a note (within a fifth of a semitone of one, the
    /// record's tuning allowed for).
    private func onNotes(_ h: [Float]) -> Float {
        let n = min(32, h.count)
        guard n > 0 else { return 1 }
        var on = 0
        for i in (h.count - n)..<h.count { let x = h[i] - tuning; if abs(x - x.rounded()) < 0.2 { on += 1 } }
        return Float(on) / Float(n)
    }

    /// A stream's vibrato over the last 384 ms: its depth (semitones either side) and rate, or zeros if it has none a
    /// singer would make (3.5–8 Hz, slowed records included; 0.08–1.5 st).
    private func vibrato(_ h: [Float]) -> (depth: Float, rate: Float) {
        let n = h.count
        guard n >= 40 else { return (0, 0) }
        var sx: Float = 0, sy: Float = 0, sxx: Float = 0, sxy: Float = 0
        for i in 0..<n { let x = Float(i), y = h[i]; sx += x; sy += y; sxx += x * x; sxy += x * y }
        let fn = Float(n)
        let b = (fn * sxy - sx * sy) / max(1e-6, fn * sxx - sx * sx), a = (sy - b * sx) / fn
        var e: Float = 0, crossings = 0, prev: Float = 0
        for i in 0..<n {
            let r = h[i] - (a + b * Float(i))
            e += r * r
            if i > 0 && (r > 0) != (prev > 0) { crossings += 1 }
            prev = r
        }
        let depth = 1.414 * sqrt(e / fn), rate = Float(crossings) / (2 * Float(Double(n - 1) * hopSec))
        return rate >= 3.5 && rate <= 8 && depth >= 0.08 && depth <= 1.5 ? (depth, rate) : (0, 0)
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let u = max(0, min(1, (x - a) / (b - a)))
        return u * u * (3 - 2 * u)
    }

    /// How sure a stream is the line: strong enough, and not shadowed by a near-equal octave. (How long it lasts is
    /// judged by the picture, which sees a little ahead: TuneDisplay.)
    private func confidence(_ s: Stream) -> Float {
        var c = Self.smooth(0.24, 0.40, s.v)
        for q in streams where q.id != s.id && t - q.seen <= 0.025 && abs(abs(q.pitch - s.pitch) - 12) < 0.5 && q.v >= 0.7 * s.v {
            c *= 0.7; break
        }
        return c
    }

    // MARK: Which stream is the tune

    private func choose() {
        var best = -1, bestScore: Float = 0
        let curAlive = streams.contains { $0.id == leadID }
        let vp = max(0, min(1, voicePresence))
        scores.removeAll(keepingCapacity: true)
        for s in streams {
            guard t - s.seen <= 0.025 else { scores.append(0); continue }
            let age = Float(t - s.born)
            let lenF = min(1, (age + 0.008) / 0.03)
            // carrying on: the tune's own stream, or one born just as it ended, near where it was
            var cont: Float = 1
            if s.id == leadID { cont = 1.6 }
            else if !curAlive || t - lastLeadT > 0.03 {
                if abs(s.hist[0] - leadPitch) <= 9 && s.born >= lastLeadT - 0.06 { cont = 1.4 }
            }
            // a voice's pitch wavers (vibrato, scoops); more weight on that while a voice is heard
            let fl = 1 + (0.4 + 1.6 * vp) * max(0, min(1, (wander(s.hist) - 3) / 15))
            var rng: Float = 1
            if s.pitch < 43 { rng = 0.5 } else if s.pitch > 90 { rng = 0.6 }
            // an octave or two over a live stream nearly as strong (and high enough to be sung): its overtone
            var octF: Float = 1
            let mine = s.v
            for q in streams where q.id != s.id && t - q.seen <= 0.025 && q.pitch >= 40 {
                let dd = s.pitch - q.pitch
                if (abs(dd - 12) < 0.5 || abs(dd - 24) < 0.5) && q.v >= 0.9 * mine { octF = 0.7; break }
            }
            // with no voice heard, the lead line leans high (a synth hook over its chords)
            let lean = 1 + 0.4 * (1 - vp) * (max(0, min(1, (s.pitch - 48) / 36)) - 0.5)
            var sc = mine * lenF * cont * fl * rng * octF * lean
            // a reverb tail (born fading, never growing) can carry the tune on but never take it over
            if s.bornRise < 0.35 && !s.rose && s.id != leadID && cont < 1.4 && age > 0.03 { sc *= Self.tailRule }
            scores.append(sc)
            if sc > bestScore { bestScore = sc; best = scores.count - 1 }
        }
        // leaving a live tune takes a challenger clearly stronger for 8 frames (64 ms) running
        if best >= 0, let cur = leadID, streams[best].id != cur,
           let ci = streams.firstIndex(where: { $0.id == cur }), t - streams[ci].seen <= 0.025, streams[ci].v >= 0.28 {
            if streams[best].id == challenger && scores[best] > 1.3 * scores[ci] { challengeN += 1 }
            else if scores[best] > 1.3 * scores[ci] { challenger = streams[best].id; challengeN = 1 }
            else { challenger = nil; challengeN = 0 }
            if challengeN < 8 { best = ci } else { challenger = nil; challengeN = 0 }
        }

        let at = t - centre
        var f = TuneFrame(t: at, pitch: 0, conf: 0, level: 0, stream: 0, flags: 0)
        var c2 = TuneFrame(t: at, pitch: 0, conf: 0, level: 0, stream: 0, flags: 0)
        if best >= 0 {
            var s = streams[best]
            let v = s.v
            if v >= 0.36 { aboveCount += 1 } else { aboveCount = 0 }
            if v >= 0.28 { belowSince = t }
            let wasVoiced = voiced
            if !voiced && aboveCount >= 2 { voiced = true }
            if voiced && t - belowSince > 0.10 { voiced = false }
            let newStream = s.id != leadID
            if newStream && s.id == counterID { swapAt.append(t - centre); counterID = leadID }
            f.pitch = s.pitch; f.level = min(1, v / 0.5); f.stream = Int32(s.id)
            f.conf = confidence(s)
            leadWander = wander(s.hist)
            if voiced {
                f.flags |= TuneFrame.voiced
                // a new note or syllable: the tune moves to a new sound after a step or a rest; the same sound comes
                // again (salience jumping back up); or the pitch steps and holds inside one stream (autotune, legato)
                var onset = false
                if newStream && (abs(s.pitch - leadPitch) > 0.6 || t - lastVoicedT >= 0.06) { onset = true }
                if !wasVoiced { onset = true }
                if s.salAgo.2 > 0.05 && s.sal >= 1.4 * s.salAgo.2 && t - s.lastOnset > 0.1 { onset = true }
                let h = s.hist, n = h.count
                if n >= 10 {
                    var a0: Float = 0, a1: Float = 0, lo0 = Float.infinity, hi0 = -Float.infinity, lo1 = Float.infinity, hi1 = -Float.infinity
                    for i in (n - 10)..<(n - 5) { a0 += h[i]; lo0 = min(lo0, h[i]); hi0 = max(hi0, h[i]) }
                    for i in (n - 5)..<n { a1 += h[i]; lo1 = min(lo1, h[i]); hi1 = max(hi1, h[i]) }
                    if abs(a1 - a0) / 5 >= 0.6 && hi0 - lo0 < 0.3 && hi1 - lo1 < 0.3 && t - s.lastOnset > 0.1 { onset = true }
                }
                if onset && t - lastOnsetT > 0.06 {
                    f.flags |= TuneFrame.onset; lastOnsetT = t
                    s.lastOnset = t; streams[best] = s
                }
                // rapped or spoken: its pitch wanders and keeps off the notes (a sung line, autotuned above all, sits
                // on them). Only when surely so: a melody hidden as speech is worse than speech shown as a melody
                if rap >= 0.5 && leadWander > 60 && onNotes(s.hist) < 0.45 { f.flags |= TuneFrame.rapped }
                leadPitch = s.pitch; lastLeadT = t; lastVoicedT = t
            }
            leadID = s.id
            leadVib = vibrato(s.hist)

            // the counter-line: the strongest other stream at least 3 st away and not an octave, twelfth or two
            // octaves of the tune, shown once it has been there a while and moves like a line (not a held pad note)
            var b2 = -1, s2: Float = 0
            for (i, q) in streams.enumerated() where i != best && scores[i] > 0 {
                let dd = abs(q.pitch - s.pitch)
                if dd < 3 || abs(dd - 12) < 0.6 || abs(dd - 19) < 0.6 || abs(dd - 24) < 0.6 { continue }
                let sc = scores[i] * (q.id == counterID ? 1.5 : 1)
                if sc > s2 { s2 = sc; b2 = i }
            }
            if b2 >= 0 && s2 >= 0.5 * bestScore {
                let q = streams[b2]
                if q.id != counterID { counterOnsets.append(t) }
                counterID = q.id
                counterHist.append((t, q.pitch))
                counterHist.removeAll { t - $0.t > 2 }
                counterOnsets.removeAll { t - $0 > 2 }
                var lo = Float.infinity, hi = -Float.infinity
                for e in counterHist { lo = min(lo, e.p); hi = max(hi, e.p) }
                let melodic = hi - lo >= 1.5 || counterOnsets.count >= 2
                c2.pitch = q.pitch; c2.level = min(1, q.v / 0.5); c2.stream = Int32(q.id)
                c2.conf = confidence(q)
                if voiced && melodic && c2.conf >= 0.5 && t - q.born >= 0.15 {
                    c2.flags |= TuneFrame.voiced
                    if Int32(q.id) != counter.last?.stream { c2.flags |= TuneFrame.onset }
                }
                counterVib = vibrato(q.hist)
                counterWander = wander(q.hist)
            } else {
                counterID = nil
                counterVib = (0, 0)
            }
        } else {
            aboveCount = 0
            if voiced && t - belowSince > 0.10 { voiced = false }
            leadID = nil
            leadVib = (0, 0)
        }
        lead.append(f); counter.append(c2); fresh.append(f)
        if lead.count > 160 { lead.removeFirst(lead.count - 125); counter.removeFirst(counter.count - 125) }
        if fresh.count > 400 { fresh.removeFirst(fresh.count - 400) }
    }

    /// How much a reverb tail is marked down when it would take the tune over (1: not at all).
    #if DEBUG
    static let tailRule = Float(ProcessInfo.processInfo.environment["ML_TAIL"] ?? "") ?? 0
    #else
    static let tailRule: Float = 0
    #endif
}
