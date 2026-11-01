import CoreHaptics

/// The iPhone's Taptic Engine: a continuous bed that follows the bass and the build,
/// sharp taps on beats, and a long hit for drops and marked moments.
final class Haptics {
    var intensity: Float = 1
    /// Gain on everything the music drives, so quieter music and softer hits are still felt clearly.
    private let sensitivity: Float = 2
    private var engine: CHHapticEngine?
    private var bed: CHHapticAdvancedPatternPlayer?

    init() { restart() }

    func restart() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak self] in
                try? self?.engine?.start()
                self?.startBed()
            }
            try e.start()
            engine = e
            startBed()
        } catch {
            engine = nil
        }
    }

    private func startBed() {
        guard let engine else { return }
        let ev = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            .init(parameterID: .hapticIntensity, value: 1),
            .init(parameterID: .hapticSharpness, value: 0.3),
        ], relativeTime: 0, duration: 30)
        do {
            let p = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [ev], parameters: []))
            p.loopEnabled = true
            try p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
            try p.start(atTime: CHHapticTimeImmediate)
            bed = p
        } catch {}
    }

    func setBed(level: Float, sharpness: Float) {
        try? bed?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(1, max(0, level * sensitivity * intensity)), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: min(1, max(-1, sharpness)), relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    func tap(_ strength: Float, sharpness: Float) {
        play([CHHapticEvent(eventType: .hapticTransient, parameters: [
            .init(parameterID: .hapticIntensity, value: min(1, strength * sensitivity * intensity)),
            .init(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)])
    }

    /// A rapid volley that swells into a long, fading rumble.
    func peak() {
        var events = (0..<6).map { i in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                .init(parameterID: .hapticIntensity, value: 1),
                .init(parameterID: .hapticSharpness, value: 0.6),
            ], relativeTime: Double(i) * 0.07)
        }
        events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
            .init(parameterID: .hapticIntensity, value: min(1, intensity)),
            .init(parameterID: .hapticSharpness, value: 0.2),
        ], relativeTime: 0, duration: 1.6))
        let fade = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0, value: 1), .init(relativeTime: 0.5, value: 0.8), .init(relativeTime: 1.6, value: 0),
        ], relativeTime: 0)
        play(events, curves: [fade])
    }

    private func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = []) {
        guard let engine else { return }
        do {
            try engine.makePlayer(with: CHHapticPattern(events: events, parameterCurves: curves)).start(atTime: CHHapticTimeImmediate)
        } catch {}
    }
}
