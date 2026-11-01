import SwiftUI

/// Sign: a canvas of hexagons that fit perfectly, on which a hand fingerspells, in the ASL manual alphabet, each word
/// being sung, coloured by the music (see iOS/Sign). The one picture in this app: it was lifted out of Felt, whose
/// other pictures live on in its own repository.
enum SceneKind: String, CaseIterable {
    case sign = "Sign"
}

/// (Felt shows a "Journey" through all its pictures; here there is only Sign)
let journeyMode = SceneKind.sign.rawValue
let visualModes = SceneKind.allCases.map(\.rawValue)

/// Each instrument has its own light, the same in every picture, so the eye learns them.
enum Instrument: CaseIterable {
    case kick, snare, hats, bass, voice
    var name: String { ["Kick", "Snare", "Hats", "Bass", "Voice"][Instrument.allCases.firstIndex(of: self)!] }
    var hue: Double { [0.02, 0.88, 0.52, 0.74, 0.065][Instrument.allCases.firstIndex(of: self)!] }
}

/// How lit each instrument's light is right now, 0...1.
struct InstrumentLights {
    var kick = 0.0, snare = 0.0, hat = 0.0, bass = 0.0, voice = 0.0
    func level(_ i: Instrument) -> Double {
        switch i { case .kick: kick; case .snare: snare; case .hats: hat; case .bass: bass; case .voice: voice }
    }
}

/// The picture: the Sign shader, fed each frame by the show.
struct Visualizer: View {
    let engine: Engine
    var mode = journeyMode
    /// A show shared with another view (the big screen and its preview on the phone); nil gives this view its own.
    var show: Show?
    /// Whether this view's frame rate decides the timing (the big screen does; a small preview doesn't).
    var primary = true
    @State private var ownShow = Show()
    /// The Brightness slider: the whole picture scaled, 1 as drawn (Exposure.metal).
    @AppStorage("showBrightness") private var brightness = 1.0

    var body: some View {
        let show = self.show ?? ownShow
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                let _ = show.frame(at: tl.date, size: geo.size, engine: engine, primary: primary)
                Rectangle().fill(.black)
                    .colorEffect(Shader(function: ShaderLibrary.sign, arguments: show.signScene.arguments(size: geo.size)))
                    .colorEffect(ShaderLibrary.exposure(.float(Float(brightness))), isEnabled: abs(brightness - 1) > 0.01)
            }
        }
        .background(.black)
        .allowsHitTesting(false)
    }
}

/// The show's state between frames: the beats and drops seen, and the hand.
@MainActor
final class Show {
    /// The show on the big screen, which the phone previews.
    static let shared = Show()

    let signScene = SignScene()
    private(set) var energy = 0.0
    /// (Felt drops its costliest glow when the phone can't keep up; Sign never needs to)
    let lite = false
    private var last = Date(), lastDate = Date.distantPast, lastSize = CGSize.zero
    private var seenBeats = 0, seenPeak = Date.distantPast

    /// Moves the show on to `now` (once a frame, however many views draw it).
    @discardableResult
    func frame(at now: Date, size: CGSize, engine: Engine, primary: Bool = true) -> Bool {
        if now == lastDate && size == lastSize { return false }
        lastDate = now
        lastSize = size
        let dt = min(0.05, max(0, now.timeIntervalSince(last)))
        last = now
        let f = engine.f
        energy += (Double(f.energy) - energy) * min(1, dt * 4)
        let beat = engine.beats != seenBeats
        if beat { seenBeats = engine.beats }
        let peak = engine.peakAt != seenPeak
        if peak { seenPeak = engine.peakAt }
        SignWords.shared.setActive(true)
        signScene.update(wall: dt, features: f, lights: engine.lights, beat: beat, peak: peak, score: engine.reading.score)
        return true
    }
}
