import SwiftUI
import simd

/// "Sign" (Cole, 2026-11-01): a canvas of tiles that fit perfectly (hexagons), on which a hand fingerspells, in the ASL
/// manual alphabet, each word being sung. Hands only, no text (Cole's choice). The words come from SignWords.
///
/// The hand is a small 3D skeleton (a right hand, palm to the viewer as a fingerspeller holds it): the palm, the thumb's
/// three bones, and three bones for each finger, every joint bent toward the palm by its own angle. Each letter is a pose
/// (how far each joint bends, where the thumb's tip sits, how the hand is turned), and the hand eases from one to the
/// next. J and Z are drawn in the air: the hand travels the letter's path while it is held. A doubled letter slides a
/// little to the side, as signers show it. The skeleton is projected to the screen as 20 capsules with their depth, and
/// the shader lights the tiles they cover, nearer bones brighter, a seam of shadow where one bone crosses another.
@MainActor
final class SignScene {
    static let capsules = 20
    /// 8 floats a capsule: ax, ay, bx, by (screen units: half the shorter side), radius, depth at a, depth at b, part
    static let floats = 8 * capsules

    // MARK: the hand's shape (hand units: the palm 0.9 wide, wrist at y 0, knuckles at y ≈ 1; x toward the thumb, as the
    // viewer sees a right hand held palm out; z toward the viewer)

    private struct Finger { let base: SIMD3<Float>; let lengths: SIMD3<Float>; let radius: Float }
    private static let fingers: [Finger] = [
        Finger(base: [0.30, 1.00, 0], lengths: [0.46, 0.27, 0.20], radius: 0.088),   // index
        Finger(base: [0.10, 1.04, 0], lengths: [0.50, 0.30, 0.21], radius: 0.090),   // middle
        Finger(base: [-0.10, 1.00, 0], lengths: [0.47, 0.28, 0.20], radius: 0.086),  // ring
        Finger(base: [-0.29, 0.92, 0], lengths: [0.36, 0.22, 0.18], radius: 0.076),  // pinky
    ]
    private static let thumbCMC: SIMD3<Float> = [0.30, 0.18, 0.02]
    private static let thumbLengths: (Float, Float) = (0.32, 0.27)
    private static let thumbRadius: Float = 0.098

    /// A letter: each finger's spread (degrees, + toward the thumb) and its three joints' bends toward the palm
    /// (degrees), a depth nudge per finger (for R's crossing), the thumb (its MCP knuckle and its tip, or which
    /// fingertip its tip meets), and how the whole hand is turned (roll in the screen's plane, yaw round the vertical).
    private struct Pose {
        var spread: [Float] = [4, 0, -4, -9]
        var bend: [SIMD3<Float>] = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]]
        var lift: [Float] = [0, 0, 0, 0]
        var thumbMCP: SIMD3<Float> = [0.50, 0.42, 0.12]
        var thumbTip: SIMD3<Float> = [0.48, 0.95, 0.14]
        var thumbTo: Int = -1                   // a fingertip (0 index … 3 pinky) the thumb's tip meets instead
        var roll: Float = 0, yaw: Float = 0
    }

    private static let fist: SIMD3<Float> = [88, 100, 60]
    private static let claw: SIMD3<Float> = [55, 95, 65]
    private static let straight: SIMD3<Float> = [0, 0, 0]
    // the thumb's places
    private static let thumbAcrossFolded: (SIMD3<Float>, SIMD3<Float>) = ([0.46, 0.42, 0.20], [-0.05, 0.74, 0.58])  // S: over the curled fingers
    private static let thumbAcrossPalm: (SIMD3<Float>, SIMD3<Float>) = ([0.42, 0.40, 0.10], [-0.06, 0.58, 0.16])    // B: folded across the palm
    private static let thumbHoldDown: (SIMD3<Float>, SIMD3<Float>) = ([0.46, 0.42, 0.20], [-0.16, 0.72, 0.58])      // U, V, R, H: holding ring and pinky

    private static func pose(_ ch: Character) -> Pose {
        var p = Pose()
        let F = fist
        switch ch {
        case "a":   // a fist, the thumb straight up beside the index
            p.bend = [F, F, F, F]; p.thumbMCP = [0.50, 0.46, 0.18]; p.thumbTip = [0.50, 0.98, 0.22]
        case "b":   // the four fingers straight up together, the thumb folded across the palm
            p.spread = [2, 0, -2, -4]; (p.thumbMCP, p.thumbTip) = thumbAcrossPalm
        case "c":   // a curve, as if holding a cup, seen from the side
            p.spread = [2, 0, -2, -4]; p.bend = [[30, 35, 25], [30, 35, 25], [30, 35, 25], [30, 35, 25]]
            p.thumbMCP = [0.50, 0.40, 0.30]; p.thumbTip = [0.40, 0.70, 0.75]; p.yaw = -62
        case "d":   // the index straight up, the other fingers and the thumb meeting in a circle
            p.bend = [straight, [45, 80, 45], [45, 80, 45], [45, 80, 45]]; p.thumbMCP = [0.46, 0.42, 0.20]; p.thumbTo = 1
        case "e":   // the fingers curled down onto the thumb, which lies across the palm under their tips
            p.spread = [2, 0, -2, -4]; p.bend = [claw, claw, claw, claw]
            p.thumbMCP = [0.42, 0.40, 0.12]; p.thumbTip = [-0.10, 0.62, 0.24]
        case "f":   // the index and the thumb touching in a circle, the other three straight up and apart
            p.spread = [2, 2, -6, -14]; p.bend = [[40, 70, 45], straight, straight, straight]
            p.thumbMCP = [0.48, 0.42, 0.18]; p.thumbTo = 0
        case "g":   // the index pointing sideways, the thumb parallel under it, the rest curled; the back of the hand out
            p.bend = [straight, F, F, F]; p.thumbMCP = [0.50, 0.46, 0.18]; p.thumbTip = [0.44, 1.10, 0.20]
            p.roll = -88; p.yaw = 155
        case "h":   // the index and middle together, pointing sideways
            p.spread = [1, -1, -4, -9]; p.bend = [straight, straight, F, F]
            (p.thumbMCP, p.thumbTip) = thumbHoldDown; p.roll = -88; p.yaw = 155
        case "i", "j":   // the pinky straight up, the rest a fist, the thumb over it
            p.bend = [F, F, F, straight]; (p.thumbMCP, p.thumbTip) = thumbAcrossFolded
        case "k":   // the index up, the middle angled out, the thumb's tip against the middle finger between them
            p.spread = [6, -14, -4, -9]; p.bend = [straight, [35, 0, 0], F, F]
            p.thumbMCP = [0.46, 0.44, 0.22]; p.thumbTip = [0.16, 1.30, 0.34]
        case "l":   // the index up and the thumb straight out: an L
            p.bend = [straight, F, F, F]; p.thumbMCP = [0.56, 0.40, 0.06]; p.thumbTip = [1.08, 0.55, 0.02]
        case "m":   // a fist with the thumb tucked under the first three fingers, its tip between the ring and pinky
            p.bend = [F, F, F, F]; p.thumbMCP = [0.42, 0.34, 0.10]; p.thumbTip = [-0.22, 0.63, 0.18]   // (tucked under: the index, middle and ring tips drape over it, out to the pinky)
        case "n":   // the thumb under the first two fingers, its tip between the middle and ring
            p.bend = [F, F, F, F]; p.thumbMCP = [0.42, 0.34, 0.10]; p.thumbTip = [0.03, 0.63, 0.18]    // (tucked under: only the index and middle tips drape over it)
        case "o":   // all the fingertips meeting the thumb's in an O, seen from the side
            p.spread = [2, 0, -2, -4]; p.bend = [[45, 65, 45], [45, 65, 45], [45, 65, 45], [45, 65, 45]]
            p.thumbMCP = [0.50, 0.42, 0.28]; p.thumbTo = 0; p.yaw = -62
        case "p":   // K pointing down
            p.spread = [6, -14, -4, -9]; p.bend = [straight, [35, 0, 0], F, F]
            p.thumbMCP = [0.46, 0.44, 0.22]; p.thumbTip = [0.16, 1.30, 0.34]; p.roll = -145; p.yaw = 25
        case "q":   // G pointing down
            p.bend = [straight, F, F, F]; p.thumbMCP = [0.50, 0.46, 0.18]; p.thumbTip = [0.44, 1.10, 0.20]
            p.roll = -165; p.yaw = 30
        case "r":   // the index and middle crossed, the middle over the index
            p.spread = [-4, 7, -4, -9]; p.lift = [0, 0.10, 0, 0]; p.bend = [straight, straight, F, F]
            (p.thumbMCP, p.thumbTip) = thumbHoldDown
        case "s":   // a fist, the thumb across the front of the fingers
            p.bend = [F, F, F, F]; (p.thumbMCP, p.thumbTip) = thumbAcrossFolded
        case "t":   // a fist with the thumb's tip poking up between the index and middle
            p.bend = [F, F, F, F]; p.thumbMCP = [0.46, 0.44, 0.16]; p.thumbTip = [0.21, 0.98, 0.42]
        case "u":   // the index and middle straight up together
            p.spread = [1, -1, -4, -9]; p.bend = [straight, straight, F, F]; (p.thumbMCP, p.thumbTip) = thumbHoldDown
        case "v":   // the index and middle up and apart
            p.spread = [12, -11, -4, -9]; p.bend = [straight, straight, F, F]; (p.thumbMCP, p.thumbTip) = thumbHoldDown
        case "w":   // the index, middle and ring up and apart, the thumb holding the pinky
            p.spread = [12, 0, -12, -9]; p.bend = [straight, straight, straight, F]
            p.thumbMCP = [0.46, 0.42, 0.20]; p.thumbTip = [-0.26, 0.70, 0.52]
        case "x":   // the index hooked, the rest a fist, the hand turned a little to the side
            p.bend = [[15, 95, 70], F, F, F]; (p.thumbMCP, p.thumbTip) = thumbAcrossFolded; p.yaw = -30
        case "y":   // the thumb and pinky out, the middle three curled
            p.spread = [4, 0, -4, -22]; p.bend = [F, F, F, straight]; p.thumbMCP = [0.56, 0.42, 0.08]; p.thumbTip = [1.02, 0.78, 0.04]
        case "z":   // the index out, drawing a Z
            p.bend = [straight, F, F, F]; (p.thumbMCP, p.thumbTip) = thumbAcrossFolded
        default:    // at rest: open, relaxed
            p.spread = [6, 1, -5, -11]; p.bend = [[12, 10, 5], [10, 10, 5], [12, 12, 6], [15, 14, 8]]
            p.thumbMCP = [0.52, 0.40, 0.10]; p.thumbTip = [0.80, 0.75, 0.15]
        }
        return p
    }

    // MARK: the spelling

    /// FELT_SIGN_HOLD=1: the last letter stays up until the next word (for photographing each letter)
    private static let holdLast = ProcessInfo.processInfo.environment["FELT_SIGN_HOLD"] != nil
    private var words: [String] = []                // still to spell
    private var letters: [Character] = []           // the current word's
    private var index = 0, letterAge = 0.0, letterHold = 0.5, gapLeft = 0.0
    private var pose = SignScene.pose(" "), shown: Character = " "
    private var visible = 0.0, idle = 9.0
    private var clock = 0.0, slide: Float = 0
    private var energy = 0.0, pulse = 0.0
    // the hand's colours (Cole, 2026-11-01: "visually appealing colors, that change and react to the music"): its hue
    // from the harmony (each pitch class round the circle of fifths, the chord's average, drifting slowly), jumping on
    // to a new colour at a drop; and the music's parts as light: the beat, the bass, the snare, the hats, the voice
    private var hue = 200.0, hueTo = 200.0, hueJump = 0.0
    private var bass = 0.0, snare = 0.0, hat = 0.0, voice = 0.0, dropAge = 9.0
    private(set) var array = [Float](repeating: 0, count: SignScene.floats)

    func update(wall dt: Double, features f: Features, lights: InstrumentLights, beat: Bool, peak: Bool, score: Score) {
        guard dt > 0 else { return }
        clock += dt
        energy += (Double(f.energy) - energy) * min(1, dt / 0.5)
        pulse = beat ? 1 : pulse * exp(-dt / 0.3)
        bass += (lights.bass - bass) * min(1, dt / (lights.bass > bass ? 0.05 : 0.3))
        snare += (lights.snare - snare) * min(1, dt / (lights.snare > snare ? 0.02 : 0.15))
        hat += (lights.hat - hat) * min(1, dt / (lights.hat > hat ? 0.02 : 0.10))
        voice += (lights.voice - voice) * min(1, dt / 0.3)
        dropAge = peak ? 0 : min(9, dropAge + dt)
        // the harmony's colour: the sounding pitch classes as vectors round the circle of fifths, averaged
        var vx = 0.0, vy = 0.0
        for k in 0..<min(12, score.chroma.count) {
            let a = Double((k * 7) % 12) * 30 * .pi / 180
            vx += Double(score.chroma[k]) * cos(a); vy += Double(score.chroma[k]) * sin(a)
        }
        if vx * vx + vy * vy > 0.01 { hueTo = (atan2(vy, vx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }
        if peak { hueJump += 120 }
        // eased the short way round, slowly, plus a slow drift so a long chord still lives
        var dh = (hueTo + hueJump - hue).truncatingRemainder(dividingBy: 360)
        if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        hue += dh * min(1, dt / 1.5) + dt * 4
        for w in SignWords.shared.take() {
            let clean = w.lowercased().filter { $0 >= "a" && $0 <= "z" }
            if !clean.isEmpty { words.append(clean) }
        }
        // fast singing outruns spelling: keep up by dropping the oldest words still waiting
        if words.count > 3 { words.removeFirst(words.count - 3) }

        // the next letter when this one has been held long enough; quicker when words are waiting
        letterAge += dt
        if gapLeft > 0 { gapLeft -= dt }
        let waiting = words.reduce(0) { $0 + $1.count } + max(0, letters.count - index - 1)
        letterHold = waiting > 12 ? 0.30 : waiting > 5 ? 0.40 : 0.52
        if gapLeft <= 0 && (letters.isEmpty || letterAge >= holdFor(letters[min(index, letters.count - 1)])) {
            if !letters.isEmpty && index < letters.count - 1 {
                index += 1; letterAge = 0
                slide = letters[index] == letters[index - 1] ? 1 : 0
            } else if !words.isEmpty {
                if !letters.isEmpty { gapLeft = 0.30 }          // (a beat between words)
                letters = Array(words.removeFirst()); index = 0; letterAge = 0; slide = 0
            } else if !letters.isEmpty && letterAge > 1.2 && !Self.holdLast {
                letters = []; index = 0
            }
        }
        let target: Character = letters.isEmpty ? " " : letters[min(index, letters.count - 1)]
        idle = letters.isEmpty ? idle + dt : 0
        visible += ((idle > 2.5 ? 0 : 1) - visible) * min(1, dt / 0.5)
        // ease toward the letter's pose: quick, so each letter is held clearly, never a blur between
        let to = Self.pose(target)
        let k = Float(min(1, dt / 0.07))
        pose.spread = zip(pose.spread, to.spread).map { $0 + ($1 - $0) * k }
        pose.bend = zip(pose.bend, to.bend).map { $0 + ($1 - $0) * k }
        pose.lift = zip(pose.lift, to.lift).map { $0 + ($1 - $0) * k }
        pose.thumbMCP += (to.thumbMCP - pose.thumbMCP) * k
        pose.thumbTip += (to.thumbTip - pose.thumbTip) * k
        pose.thumbTo = to.thumbTo
        pose.roll += (to.roll - pose.roll) * k
        pose.yaw += (to.yaw - pose.yaw) * k
        shown = target
        array = project(letterT: Float(min(1, letterAge / max(0.2, holdFor(target)))))
    }

    private func holdFor(_ c: Character) -> Double { c == "j" || c == "z" ? letterHold + 0.35 : letterHold }

    /// The skeleton posed, moved (J and Z travel their paths, a doubled letter slides) and projected.
    private func project(letterT: Float) -> [Float] {
        var caps: [(SIMD3<Float>, SIMD3<Float>, Float, Float)] = []    // a, b, radius, part
        // the palm: four upright capsules side by side and the wrist below
        for (i, x) in [Float(-0.25), -0.08, 0.09, 0.26].enumerated() {
            let topY: Float = i == 0 ? 0.86 : 0.90
            caps.append((SIMD3<Float>(x, 0.16, 0), SIMD3<Float>(x * 0.95, topY, 0), 0.15, 0))
        }
        caps.append(([0.02, -0.55, -0.02], [0.02, 0.06, 0], 0.27, 0))
        // the fingers
        var tips: [SIMD3<Float>] = []
        for (f, fi) in Self.fingers.enumerated() {
            let s = pose.spread[f] * .pi / 180
            let d0 = SIMD3<Float>(sin(s), cos(s), 0)
            var p = fi.base + SIMD3(0, 0, pose.lift[f])
            var cum: Float = 0
            for j in 0..<3 {
                cum += pose.bend[f][j] * .pi / 180
                let dir = SIMD3(d0.x * cos(cum), d0.y * cos(cum), sin(cum))
                let q = p + dir * fi.lengths[j]
                caps.append((p, q, fi.radius * (j == 2 ? 0.92 : 1), Float(1 + f)))
                p = q
            }
            tips.append(p)
        }
        // the thumb: its metacarpal from the wrist to its knuckle, then two bones to its tip, bent outward
        let m = pose.thumbMCP
        var tip = pose.thumbTo >= 0 ? tips[pose.thumbTo] + SIMD3(0.03, -0.05, 0.02) : pose.thumbTip
        let (l1, l2) = Self.thumbLengths
        var dv = tip - m
        var dd = simd_length(dv)
        if dd > l1 + l2 - 0.001 { dv *= (l1 + l2 - 0.001) / dd; tip = m + dv; dd = l1 + l2 - 0.001 }
        let u = dv / max(dd, 1e-4)
        let a = (l1 * l1 - l2 * l2 + dd * dd) / (2 * max(dd, 1e-4))
        let h = sqrt(max(0, l1 * l1 - a * a))
        var bendDir = SIMD3<Float>(1, 0, 0.6) - u * simd_dot(SIMD3<Float>(1, 0, 0.6), u)
        bendDir = simd_length(bendDir) > 1e-4 ? simd_normalize(bendDir) : [0, 0, 1]
        let ip = m + u * a + bendDir * h
        caps.append((Self.thumbCMC, m, Self.thumbRadius * 1.15, 5))
        caps.append((m, ip, Self.thumbRadius, 5))
        caps.append((ip, tip, Self.thumbRadius * 0.92, 5))

        // the hand turned (yaw round the vertical, then roll in the screen's plane), moved, and set in the screen:
        // centred a little low, about two thirds of the screen's shorter side tall
        let yaw = pose.yaw * .pi / 180, roll = pose.roll * .pi / 180
        var move = SIMD2<Float>(0, 0)
        if shown == "j" {       // the pinky draws a J: down, then curving round toward the thumb side and up
            let tt = min(1, letterT * 1.2)
            move = SIMD2(-0.25 * sin(tt * .pi * 0.9), -0.35 * sin(min(1, tt * 1.6) * .pi * 0.5))
        } else if shown == "z" { // the index draws a Z: across, diagonally back down, across again
            let tt = min(1, letterT * 1.15) * 3
            let pts: [SIMD2<Float>] = [[-0.3, 0.25], [0.3, 0.25], [-0.3, -0.2], [0.3, -0.2]]
            let i = min(2, Int(tt)), f = tt - Float(i)
            move = pts[i] + (pts[i + 1] - pts[i]) * f
        }
        slide *= 0.9
        move.x += 0.12 * slide
        let scale: Float = 0.62
        func place(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let c = v - SIMD3(0, 0.75, 0)                                  // (turn round the middle of the hand)
            let y1 = SIMD3(c.x * cos(yaw) + c.z * sin(yaw), c.y, -c.x * sin(yaw) + c.z * cos(yaw))
            let r1 = SIMD3(y1.x * cos(roll) - y1.y * sin(roll), y1.x * sin(roll) + y1.y * cos(roll), y1.z)
            return SIMD3(r1.x * scale + move.x * scale, r1.y * scale + move.y * scale - 0.05, r1.z * scale)
        }
        var out = [Float](repeating: 0, count: Self.floats)
        for (i, c) in caps.prefix(Self.capsules).enumerated() {
            let A = place(c.0), B = place(c.1)
            out[8 * i] = A.x; out[8 * i + 1] = A.y; out[8 * i + 2] = B.x; out[8 * i + 3] = B.y
            out[8 * i + 4] = c.2 * scale; out[8 * i + 5] = A.z; out[8 * i + 6] = B.z; out[8 * i + 7] = c.3
        }
        return out
    }

    func arguments(size: CGSize) -> [Shader.Argument] {
        [.float2(size), .float(Float(clock.truncatingRemainder(dividingBy: 10_000))),
         .float4(Float(energy), Float(pulse), Float(visible), Float(hue.truncatingRemainder(dividingBy: 360))),
         .float4(Float(bass), Float(snare), Float(hat), Float(voice)),
         .float4(Float(dropAge), 0, 0, 0),
         .floatArray(array)]
    }
}
