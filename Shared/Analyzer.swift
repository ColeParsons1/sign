import Accelerate
import AVFoundation

let spectrumBins = 32
/// The seven registers the pictures tell apart (their edges in Hz): sub, bass, low-mids, mids, high-mids, presence, air.
let regionEdges: [Double] = [20, 60, 250, 500, 2000, 4000, 6000, 16000]
let regionCount = 7

struct Features {
    var bands: [Float] = [0, 0, 0, 0]   // sub, bass, mids, air, each 0...1
    var energy: Float = 0
    var tension: Float = 0              // rises through a build-up
    var brightness: Float = 0           // dull 0 ... bright 1
    var beat = false
    var drop = false
    var time: Double = 0                // unix seconds this frame was heard
    var spectrum = [Float](repeating: 0, count: spectrumBins)   // 40 Hz – 12 kHz, log-spaced, 0...1
    var snare = false                   // a crack in the 1.5–6 kHz range (snare, clap)
    var hat = false                     // a tick above 7 kHz (hi-hat, shaker, cymbal)
    var voice: Float = 0                // how much tonal sound (voice, melody) fills 250 Hz – 4 kHz
    var regions = [Float](repeating: 0, count: regionCount)   // the seven registers (regionEdges), each 0...1 against its own recent peak
    var sizzle: Float = 0               // how much of the air holds between ticks: open hats, a ride, a crash, a noise riser, 0...1
    var sweep: Float = 0                // the sound climbing (a filter opening, a riser) + or falling away −, -1...1
    var bassPitch: Float = 0.3          // where the bassline sits: 35 Hz 0 ... 250 Hz 1 (log), held while the bass rests
}

struct Tempo {
    var bpm: Double
    var anchor: Double                  // unix time of a recent beat
    var confidence: Double
}

/// Picks one band's onsets out of its flux: a frame is an onset when it stands clear of the band's steady churn (the
/// median of the last second, which a run of even hits doesn't raise the way a mean does) and of a share of the band's
/// recent strong hits, and is still rising. Each hit then holds off the next for `gap` seconds.
private struct OnsetPicker {
    let ratio: Float, share: Float, gap: Double
    var hist: [Float] = [], strong: Float = 1e-6, prev: Float = 0, last = -9.0
    init(ratio: Float, share: Float, gap: Double) { self.ratio = ratio; self.share = share; self.gap = gap }
    mutating func step(_ v: Float, time: Double, fps: Double, open: Bool) -> Bool {
        hist.append(v)
        if hist.count > Int(fps) { hist.removeFirst() }
        let median = hist.sorted()[hist.count / 2]
        strong = max(strong * Float(pow(0.5, 1 / (fps * 4))), v)
        let hit = open && v > median * ratio + share * strong && v >= prev && time - last > gap
        prev = v
        if hit { last = time }
        return hit
    }
}

/// An AGC peak follower. Settled, it climbs at most 1.6 dB a frame: a real rise catches up in a third of a
/// second, but a knock on the phone (a frame or two) can only nudge it. Unsettled (the first second of music
/// after a silence) it jumps to the level, so a song starts out measured on itself.
private func follow(_ peak: inout Float, _ raw: Float, decay: Float, settled: Bool) {
    peak = raw > peak ? (settled ? min(raw, peak * 1.2) : raw) : max(raw, peak * decay)
}

/// Turns microphone audio into what Felt reacts to. Same ideas as the web version
/// (bands, beats from low-end spectral flux, builds and drops), plus a tempo estimate
/// so the Watch can tap on the beat without waiting for each message.
/// Runs on the audio thread.
final class Analyzer {
    private let n = 2048, hop = 1024, log2n: vDSP_Length = 11
    private let sr: Double, fps: Double
    private let setup: FFTSetup
    private var window: [Float]
    private var real: [Float], imag: [Float], mags: [Float]
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var prevMag: [Float] = []
    private var peak: [Float] = [1e-6, 1e-6, 1e-6, 1e-6]
    private var smooth: [Float] = [0, 0, 0, 0]
    private var fluxHist: [Float] = []
    private var onsetEnv: [Float] = []
    private var tempoAcc: [Float] = [], tempoLag = 0.0     // the autocorrelation remembered across estimates; the period held
    private var eShort: Float = 0
    private var eHist: [Float] = []
    private var tension: Float = 0, brightness: Float = 0
    private var lastBeat = 0.0, lastDrop = 0.0, lastTempo = 0.0
    private var specEdges: [Int] = []
    private var specPeak: Float = 1e-6
    private var spec = [Float](repeating: 0, count: spectrumBins)
    private var lastSnare = 0.0, lastHat = 0.0
    // the drums' onsets: the kick from the lowest band's log flux, the snare from a broadband crack, the hats from the top
    private var kickPick = OnsetPicker(ratio: 2.2, share: 0.32, gap: 0.16)
    private var snarePick = OnsetPicker(ratio: 2.0, share: 0.35, gap: 0.12)
    private var hatPick = OnsetPicker(ratio: 1.8, share: 0.18, gap: 0.06)
    private var logPrev: [Float] = []
    private var voice: Float = 0
    // the AGC (see follow): settled once a second of music has played, unsettled by five seconds of silence;
    // every forgetting is a half-life in seconds, so 44.1 and 48 kHz behave the same
    private var musicFrames = 0, silentFrames = 0, settled = false
    private var peakDecay: Float = 1, quickDecay: Float = 1, specDecay: Float = 1, barDecay: Float = 1, regionDecay: Float = 1
    // each spectrum bar's tilt (+3 dB an octave) and its own recent peak
    private var specTilt: [Float] = []
    private var barPeak = [Float](repeating: 1e-6, count: spectrumBins)
    // the low end's own, longer FFT: 8192 points (5.9 Hz apart at 48 kHz), so a bassline's notes land on different bars
    private let nLow = 8192, log2nLow: vDSP_Length = 13, lowBars = 11
    private let setupLow: FFTSetup
    private var windowLow: [Float] = [], lowW: [Float] = [], lowRe: [Float] = [], lowIm: [Float] = [], lowMags: [Float] = []
    private var recent: [Float] = []
    private var lowEdges: [Int] = []
    private var pitchBins = 0..<0, pitchLogs: [Float] = []
    private var bassPitch: Float = 0.3
    // the seven registers (sub and bass from the long FFT), each with its own peak
    private var regionBins: [Range<Int>] = [], regionTilt: [Float] = [], regionRelease: [Float] = []
    private var regionPeak = [Float](repeating: 1e-6, count: regionCount)
    private var regions = [Float](repeating: 0, count: regionCount)
    private var sizzle: Float = 0
    // the spectrum's centre above the bass, followed quickly and slowly
    private var barAvg = [Float](repeating: 0, count: spectrumBins)
    private var centreFast: Float = 0.5, centreSlow: Float = 0.5, sweep: Float = 0, centreHist: [Float] = []

    var onFrame: ((Features) -> Void)?
    var onTempo: ((Tempo) -> Void)?

    init(sampleRate: Double) {
        sr = sampleRate
        fps = sampleRate / Double(hop)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        setupLow = vDSP_create_fftsetup(log2nLow, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        real = [Float](repeating: 0, count: n / 2)
        imag = real
        mags = real
        let hzPer = sampleRate / Double(n)
        for k in 0...spectrumBins {
            let hz = 40 * pow(300, Double(k) / Double(spectrumBins))
            specEdges.append(max((specEdges.last ?? 0) + 1, Int(hz / hzPer)))
        }
        // +3 dB an octave from each bar's centre, so pink-ish music reads level instead of the bass towering over all
        specTilt = (0..<spectrumBins).map { k in Float(pow(300, (Double(k) + 0.5) / 64)) }
        peakDecay = Float(pow(0.5, 1 / (fps * 30)))     // a band forgets its peak with a 30 s half-life
        quickDecay = Float(pow(0.5, 1 / (fps * 0.5)))   // until the music has settled in: half a second
        specDecay = Float(pow(0.5, 1 / (fps * 20)))     // the whole spectrum's loudest bar: 20 s
        barDecay = Float(pow(0.5, 1 / (fps * 6)))       // each bar's own: 6 s, so a filter opening moves its bars
        regionDecay = Float(pow(0.5, 1 / (fps * 15)))   // each register's own: 15 s

        windowLow = [Float](repeating: 0, count: nLow)
        vDSP_hann_window(&windowLow, vDSP_Length(nLow), Int32(vDSP_HANN_NORM))
        lowW = windowLow
        lowRe = [Float](repeating: 0, count: nLow / 2); lowIm = lowRe; lowMags = lowRe
        recent = [Float](repeating: 0, count: nLow)
        let hzLow = sampleRate / Double(nLow)
        for k in 0...lowBars {
            let hz = 40 * pow(300, Double(k) / Double(spectrumBins))
            lowEdges.append(max((lowEdges.last ?? 0) + 1, Int(hz / hzLow)))
        }
        pitchBins = Int((35 / hzLow).rounded())..<Int((250 / hzLow).rounded())
        pitchLogs = pitchBins.map { Float(log2(Double($0) * hzLow / 35) / log2(250.0 / 35)) }

        for k in 0..<regionCount {
            let per = k < 2 ? hzLow : hzPer, top = k < 2 ? nLow / 2 : n / 2
            let a = max(1, Int((regionEdges[k] / per).rounded())), b = Int((regionEdges[k + 1] / per).rounded())
            regionBins.append(a..<min(top, max(a + 1, b)))
        }
        // +3 dB an octave so the registers compare; the long FFT's sub and bass scaled to the short one's level
        let lowScale = Double(n) / Double(nLow)
        regionTilt = (0..<regionCount).map { k -> Float in
            let centre: Double = sqrt(max(30, regionEdges[k]) * regionEdges[k + 1])
            return Float(sqrt(centre / 40) * (k < 2 ? sqrt(lowScale) : 1))
        }
        // how fast each register lets go, in seconds: the sub lingers, the air lets go (no faster than bands[3] today)
        regionRelease = [0.3, 0.25, 0.2, 0.18, 0.15, 0.13, 0.12].map { Float(1 - exp(-1 / (fps * $0))) }
    }

    deinit { vDSP_destroy_fftsetup(setup); vDSP_destroy_fftsetup(setupLow) }

    func process(_ buffer: AVAudioPCMBuffer, startTime: Double) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        if pending.isEmpty { pendingStart = startTime }
        pending.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        while pending.count >= n {
            analyse(Array(pending[0..<n]), time: pendingStart + Double(n) / sr)
            pending.removeFirst(hop)
            pendingStart += Double(hop) / sr
        }
    }

    private func spectrum(_ x: [Float]) {
        var w = [Float](repeating: 0, count: n)
        vDSP_vmul(x, 1, window, 1, &w, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
    }

    /// The low end's longer FFT, over the last `nLow` samples.
    private func lowSpectrum() {
        vDSP_vmul(recent, 1, windowLow, 1, &lowW, 1, vDSP_Length(nLow))
        lowRe.withUnsafeMutableBufferPointer { rp in
            lowIm.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                lowW.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nLow / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(nLow / 2))
                    }
                }
                vDSP_fft_zrip(setupLow, &split, 1, log2nLow, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &lowMags, 1, vDSP_Length(nLow / 2))
            }
        }
    }

    private func analyse(_ x: [Float], time: Double) {
        spectrum(x)
        // the long window slides along by the hop: drop the oldest hop, add the newest
        recent.removeFirst(hop)
        recent.append(contentsOf: x[(n - hop)...])
        lowSpectrum()
        let hzPer = Float(sr) / Float(n)

        // below about -55 dBFS is room noise, not music. Judged on the louder of the whole signal and everything
        // above 250 Hz lifted 6 dB, so a build with the bass filtered out isn't dimmed, or stripped of its snare
        // rolls by the gate > 0.3 checks below (the bass carries most of a mix's RMS)
        var rms: Float = 0
        vDSP_rmsqv(x, 1, &rms, vDSP_Length(n))
        var high: Float = 0
        for i in Int(250 / hzPer)..<mags.count { high += mags[i] * mags[i] }
        let rmsHigh = sqrt(high) / (Float(n) * 1.4142)   // Parseval: zrip's 2x scale, unit-RMS Hann (vDSP_HANN_NORM)
        let heard = max(rms, 2 * rmsHigh)
        let gate = min(1, max(0, (20 * log10(heard + 1e-9) + 55) / 12))
        // a second of music settles the AGC; five seconds of silence unsettles it for the next song
        musicFrames = gate > 0.3 ? musicFrames + 1 : 0
        silentFrames = gate < 0.05 ? silentFrames + 1 : 0
        if Double(musicFrames) > fps { settled = true } else if Double(silentFrames) > 5 * fps { settled = false }

        let edges: [(Float, Float)] = [(20, 90), (90, 300), (300, 2500), (2500, 12000)]
        for k in 0..<4 {
            let i0 = max(1, Int(edges[k].0 / hzPer)), i1 = min(mags.count, Int(edges[k].1 / hzPer) + 1)
            var s: Float = 0
            for i in i0..<i1 { s += mags[i] * mags[i] }
            let raw = sqrt(s / Float(i1 - i0))
            // follow each band's recent peak, so near or far, loud or quiet, the full range gets used
            follow(&peak[k], raw, decay: settled ? peakDecay : quickDecay, settled: settled)
            let v = pow(min(1, raw / peak[k]), 0.7) * gate
            smooth[k] += (v - smooth[k]) * (v > smooth[k] ? 0.6 : 0.15)
        }

        // the spectrum, tilted +3 dB an octave. Half of each bar is its level against the loudest bar (the shape),
        // half against its own recent peak, so a quiet register or a filter opening still moves; never lifted more
        // than 20 dB under the loudest, so an empty register doesn't show its hiss. Bars 0–10 (40–284 Hz) read the
        // long FFT, which has the bassline's notes; the short one, at half weight, keeps the kick's timing
        var raw = [Float](repeating: 0, count: spectrumBins)
        var loudest: Float = 0
        let lowScale = Float(n) / Float(nLow)
        for k in 0..<spectrumBins {
            var m: Float = 0
            for i in specEdges[k]..<min(mags.count, specEdges[k + 1]) { m = max(m, mags[i]) }
            if k < lowBars {
                var l: Float = 0
                for i in lowEdges[k]..<lowEdges[k + 1] { l = max(l, lowMags[i]) }
                m = max(l * lowScale, m * 0.5)
            }
            raw[k] = m * specTilt[k]
            loudest = max(loudest, raw[k])
            follow(&barPeak[k], raw[k], decay: settled ? barDecay : quickDecay, settled: settled)
        }
        follow(&specPeak, loudest, decay: settled ? specDecay : quickDecay, settled: settled)
        for k in 0..<spectrumBins {
            let shape = pow(min(1, raw[k] / specPeak), 0.6)
            let own = pow(min(1, raw[k] / max(barPeak[k], specPeak * 0.1)), 0.6)
            let v = (0.5 * shape + 0.5 * own) * gate
            spec[k] += (v - spec[k]) * (v > spec[k] ? 0.7 : 0.18)
        }

        var num: Float = 0, den: Float = 0
        for i in 1..<mags.count { num += Float(i) * mags[i]; den += mags[i] }
        let centroid = den > 0 ? num / den * hzPer : 0
        let b = min(1, max(0, log2(max(centroid, 1) / 300) / 4))   // 300 Hz → 0, ~5 kHz → 1
        // held through silence, so room hiss or a muted app doesn't swing the colour between songs
        if gate > 0.3 { brightness += (b - brightness) * 0.05 }

        // sweep: where the tilted spectrum's weight sits above the bass (so the kick and a bassline never swing it),
        // over the last second (so a bar's snare and hats don't rock it), against the last five: + while it climbs
        // (a filter opening, a riser), − while it falls. A groove's own wobble is ignored; music arriving starts it
        // level, and silence lets it go
        var cNum: Float = 0, cDen: Float = 0
        for k in lowBars..<spectrumBins {
            barAvg[k] += (raw[k] - barAvg[k]) * 0.04
            cNum += barAvg[k] * Float(k - lowBars); cDen += barAvg[k]
        }
        if gate > 0.3 && cDen > 0 {
            let c = cNum / cDen / Float(spectrumBins - 1 - lowBars)
            // following at once through the first second of music, which isn't a climb
            let settling = Double(musicFrames) < fps
            centreFast += (c - centreFast) * (settling ? 1 : 0.02)      // ~1 s
            centreSlow += (c - centreSlow) * (settling ? 1 : 0.004)     // ~5 s
        }
        let lean = (centreFast - centreSlow) * 8
        let leanOut = lean > 0 ? max(0, lean - 0.1) : min(0, lean + 0.1)
        sweep += ((gate > 0.3 ? min(1, max(-1, leanOut)) : 0) - sweep) * 0.08
        // a climb: the centre rising through each third of the last 4.5 s, none by less than half the one before
        // (a riser, a filter opening up), which a step that settles (hats coming in) never does
        centreHist.append(centreFast)
        if centreHist.count > Int(4.5 * fps) { centreHist.removeFirst() }
        let h = centreHist, third = h.count / 3
        let r1 = h[third] - h[0], r2 = h[2 * third] - h[third], r3 = h[h.count - 1] - h[2 * third]
        let climbing = h.count >= Int(4.5 * fps) && r1 > 0.015 && r2 > max(0.015, 0.5 * r1) && r3 > max(0.015, 0.5 * r2)

        // beats: a jump in the low end above an adaptive threshold (kept for the tempo's onset envelope)
        let fb = Int(300 / hzPer)
        var flux: Float = 0
        if prevMag.count == mags.count {
            for i in 1..<fb { let d = mags[i] - prevMag[i]; if d > 0 { flux += d } }
        }
        // the drums, on log-compressed flux (each bin's rise in loudness, not in power, so a quiet hit counts as
        // much as a loud one and a loud sustained note's wobble doesn't): the low hits (a kick, or a bass note's
        // attack) in 30–130 Hz; the snare as a rise across 1–8 kHz that is broad (many bins at once, as noise is)
        // rather than a few (a strummed or struck note's harmonics); the hats above 7 kHz
        if logPrev.count != mags.count { logPrev = [Float](repeating: 0, count: mags.count) }
        let ref = (peak[0] + peak[1] + peak[2] + peak[3]) * 0.25 + 1e-9
        var logNow = [Float](repeating: 0, count: mags.count)
        for i in 1..<mags.count { logNow[i] = log(1 + 100 * mags[i] / ref) }
        func logFlux(_ lo: Float, _ hi: Float) -> (sum: Float, broad: Float) {
            let a = max(1, Int(lo / hzPer)), b = min(mags.count, Int(hi / hzPer))
            var s: Float = 0, rising = 0
            for i in a..<b { let d = logNow[i] - logPrev[i]; if d > 0 { s += d; if d > 0.4 { rising += 1 } } }
            return (s / Float(max(1, b - a)), Float(rising) / Float(max(1, b - a)))
        }
        let lowF = logFlux(30, 130).sum
        let kickF = lowF * gate
        // a snare or clap cracks hard in 1–4 kHz for how much it thumps below; a kick's beater click, and a bass
        // note's attack, crack far less for their thump
        let crack = logFlux(1000, 8000), crackMid = logFlux(1000, 4000).sum
        let snareness = min(1, max(0, (crackMid / (0.5 * lowF + 0.3) - 0.6) / 0.5))
        // and its rise is noise, even across the bins (flat), where a note's rise is peaked at its harmonics
        let fa = max(1, Int(1000 / hzPer)), fz = min(mags.count, Int(6000 / hzPer))
        var lsum: Float = 0, asum: Float = 0
        for i in fa..<fz { let d = max(0, logNow[i] - logPrev[i]) + 0.02; lsum += log(d); asum += d }
        let flat = exp(lsum / Float(fz - fa)) / (asum / Float(fz - fa))
        let noisy = min(1, max(0, (flat - 0.5) / 0.15))
        let snareF = crack.sum * min(1, crack.broad * 3) * snareness * noisy * gate
        let hatF = logFlux(7000, 15000).sum * gate
        logPrev = logNow
        prevMag = mags
        flux = flux / ((peak[0] + peak[1]) * Float(fb) + 1e-9) * gate
        fluxHist.append(flux)
        if fluxHist.count > Int(fps) { fluxHist.removeFirst() }
        let mean = fluxHist.reduce(0, +) / Float(fluxHist.count)
        let open = gate > 0.3
        let beat = kickPick.step(kickF, time: time, fps: fps, open: open)
        if beat { lastBeat = time }
        // a snare spills into the hats' band, so a frame that is a snare isn't also a hat
        let snare = snarePick.step(snareF, time: time, fps: fps, open: open)
        if snare { lastSnare = time }
        let hat = hatPick.step(hatF, time: time, fps: fps, open: open && !snare) && time - lastSnare > 1.5 * Double(hop) / sr
        if hat { lastHat = time }

        // voice and melody: how tonal (peaky rather than noisy) 250 Hz – 4 kHz is
        let va = Int(250 / hzPer), vb = min(mags.count, Int(4000 / hzPer))
        var logSum: Float = 0, sum: Float = 0
        for i in va..<vb { let m = mags[i] + 1e-9; logSum += log(m); sum += m }
        let count = Float(vb - va)
        let flatness = exp(logSum / count) / (sum / count)
        let tonal = min(1, max(0, (0.55 - flatness) / 0.4))
        voice += (smooth[2] * tonal - voice) * 0.08

        // seven registers, each against its own recent peak but never lifted more than 20 dB under the strongest
        // (tilted +3 dB an octave so they compare), so a quiet register still uses its range and an empty one stays dark
        var tilted = [Float](repeating: 0, count: regionCount)
        for k in 0..<regionCount {
            var s: Float = 0
            if k < 2 { for i in regionBins[k] { s += lowMags[i] * lowMags[i] } } else { for i in regionBins[k] { s += mags[i] * mags[i] } }
            tilted[k] = sqrt(s / Float(regionBins[k].count)) * regionTilt[k]
            follow(&regionPeak[k], tilted[k], decay: settled ? regionDecay : quickDecay, settled: settled)
        }
        let strongest = regionPeak.max() ?? 1
        for k in 0..<regionCount {
            let v = pow(min(1, tilted[k] / max(regionPeak[k], strongest * 0.1)), 0.7) * gate
            regions[k] += (v - regions[k]) * (v > regions[k] ? 0.6 : regionRelease[k])
            // the air held between ticks: slow to rise and quick to fall, so a closed hat's tick barely moves it
            // while open hats, a ride, a crash ringing out or a noise riser lift it
            if k == regionCount - 1 { sizzle += (v - sizzle) * (v > sizzle ? 0.04 : 0.25) }
        }

        // the bassline's pitch: where the low end's power sits, log 35–250 Hz → 0...1; power squared so the
        // loudest note wins over its harmonics; held while the bass rests, and just after a kick, whose thump
        // would drag it down every beat
        var pn: Float = 0, pd: Float = 0
        for i in pitchBins { let q = lowMags[i] * lowMags[i]; pn += q * q * pitchLogs[i - pitchBins.lowerBound]; pd += q * q }
        if pd > 0 && smooth[0] + smooth[1] > 0.3 && time - lastBeat > 0.2 { bassPitch += (pn / pd - bassPitch) * 0.25 }

        onsetEnv.append(max(0, flux - mean))
        if onsetEnv.count > Int(8 * fps) { onsetEnv.removeFirst() }

        // builds and drops: short-term loudness against the last few seconds
        let e = smooth.reduce(0, +) / 4
        eShort += (e - eShort) * 0.25
        eHist.append(eShort)
        if eHist.count > Int(6 * fps) { eHist.removeFirst() }
        let back = Int(2 * fps)
        let old = eHist.count > back ? eHist[eHist.count - back] : eShort
        // a build: louder with the top end up, or the sound climbing (a riser, a filter opening), which keeps it
        // building after the loudness has levelled off
        let building: Float = (eShort > old * 1.05 && smooth[3] > smooth[0] * 0.8) || climbing ? 1 : 0
        tension += (building - tension) * 0.012
        var drop = false
        if eHist.count > Int(2.2 * fps) {
            let recentMin = eHist[(eHist.count - Int(1.5 * fps))..<(eHist.count - Int(0.3 * fps))].min() ?? eShort
            if smooth[0] > 0.45 && eShort > recentMin * 1.6 && eShort > 0.22 && time - lastDrop > 8 {
                drop = true; lastDrop = time; tension = 0; centreSlow = centreFast
            }
        }

        onFrame?(Features(bands: smooth, energy: eShort, tension: tension, brightness: brightness, beat: beat, drop: drop, time: time, spectrum: spec,
                         snare: snare, hat: hat, voice: voice, regions: regions, sizzle: sizzle, sweep: sweep, bassPitch: bassPitch))
        if time - lastTempo > 1 { lastTempo = time; estimateTempo() }
    }

    /// The tempo, 70–180 BPM, from the autocorrelation of the onset envelope over the last 8 s. The autocorrelation is
    /// remembered across estimates, each period is scored with its multiples too (a real pulse repeats at two, three
    /// and four beats; a triplet or dotted alias of it does not), and the held tempo only gives way to one that clearly
    /// beats it, so it doesn't flip between levels from one second to the next.
    private func estimateTempo() {
        let env = onsetEnv
        guard env.count > Int(4 * fps), lastBeat > 0 else { return }
        let lo = Int(fps * 60 / 180), hi = Int(fps * 60 / 70)
        let top = min(4 * hi + 2, env.count - Int(2 * fps))
        guard top > 2 * hi else { return }
        var zero: Float = 0, mean: Float = 0
        for v in env { zero += v * v; mean += v }
        guard zero > 0 else { return }
        mean /= Float(env.count)
        var raw = [Float](repeating: 0, count: hi + 2)              // as before, for the confidence
        var ac = [Float](repeating: 0, count: top + 1)
        for lag in 1...top {
            var s: Float = 0, r: Float = 0
            for i in lag..<env.count { s += (env[i] - mean) * (env[i - lag] - mean); if lag <= hi + 1 { r += env[i] * env[i - lag] } }
            ac[lag] = s / Float(env.count - lag)
            if lag <= hi + 1 { raw[lag] = r }
        }
        if tempoAcc.count != ac.count { tempoAcc = ac } else { for i in ac.indices { tempoAcc[i] += (ac[i] - tempoAcc[i]) * 0.25 } }
        let A = tempoAcc
        func at(_ x: Double) -> Float {
            let i = Int(x), f = Float(x - Double(i))
            guard i >= 1, i + 1 < A.count else { return 0 }
            return A[i] * (1 - f) + A[i + 1] * f
        }
        func score(_ lag: Double) -> Float {
            let bpm = 60 * fps / lag, oct = log2(bpm / 120)
            let prior = Float(exp(-0.5 * oct * oct))                 // a gentle lean toward 120, for ties between octaves
            return (at(lag) + 0.6 * at(2 * lag) + 0.4 * at(3 * lag) + 0.3 * at(4 * lag)) * prior
        }
        var best = lo
        for lag in lo...hi where score(Double(lag)) > score(Double(best)) { best = lag }
        // hold the current tempo (followed as it drifts) unless the new one is clearly stronger
        if tempoLag > 0 {
            var near = Int(tempoLag.rounded())
            for lag in max(lo, Int(tempoLag * 0.96))...min(hi, Int(tempoLag * 1.04) + 1) where score(Double(lag)) > score(Double(near)) { near = lag }
            if near >= lo, near <= hi, score(Double(best)) < score(Double(near)) * 1.15 { best = near }
        }
        // parabolic interpolation for a period finer than one analysis frame
        let a = score(Double(best - 1)), b = score(Double(best)), c = score(Double(best + 1))
        let denom = a - 2 * b + c
        let shift = denom != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denom)) : 0
        tempoLag = Double(best) + Double(shift)
        onTempo?(Tempo(bpm: 60 * fps / tempoLag, anchor: lastBeat, confidence: Double(raw[best] / zero)))
    }
}
