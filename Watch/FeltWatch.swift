import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct FeltWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchView(model: model) }
    }
}

struct WatchView: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if model.title.isEmpty {
                    Text(model.reachable ? "Listening through your iPhone" : "Open Felt on your iPhone and tap Listen")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                } else {
                    Text(model.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                    if !model.artist.isEmpty { Text(model.artist).font(.caption).foregroundStyle(.secondary) }
                }
                Button(action: model.mark) {
                    Text("This hits me").font(.headline).frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                Toggle("Beat taps", isOn: $model.beatsOn)
            }
        }
        .onAppear { model.keepRunning() }
        .onChange(of: phase) { _, p in if p == .active { model.keepRunning() } }
    }
}

/// Plays the music on the wrist. The iPhone does the listening and sends a schedule:
/// tempo and the time of a recent beat, and the exact time of each upcoming marked moment.
/// The Watch taps from that on its own clock, so the taps land on time even though
/// messages arrive a variable fraction of a second late.
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate, WKExtendedRuntimeSessionDelegate {
    @Published var title = ""
    @Published var artist = ""
    @Published var reachable = false
    @Published var beatsOn = true

    private var bpm = 0.0, anchor = 0.0, conf = 0.0, level = 0.0, tempoAt = 0.0
    private var nextBeat = 0.0, lastTap = 0.0
    private var scheduled: [(at: Double, type: WKHapticType)] = []
    private var timer: Timer?
    private var runtime: WKExtendedRuntimeSession?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Keeps Felt running with the wrist down, up to an hour at a time.
    func keepRunning() {
        guard runtime == nil else { return }
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        s.start()
        runtime = s
    }

    func mark() {
        guard WCSession.default.isReachable else { play(.failure); return }
        WCSession.default.sendMessage(["k": "mark"], replyHandler: nil) { _ in
            DispatchQueue.main.async { self.play(.failure) }
        }
    }

    private func handle(_ m: [String: Any]) {
        let now = Date().timeIntervalSince1970
        switch m["k"] as? String {
        case "beat":
            bpm = m["bpm"] as? Double ?? 0
            anchor = m["anchor"] as? Double ?? 0
            conf = m["conf"] as? Double ?? 0
            level = m["level"] as? Double ?? 0
            tempoAt = now
            nextBeat = 0
        case "moment":
            guard let at = m["at"] as? Double, at > now else { return }
            // taps that speed up toward the moment, then the hit
            var t = max(now, at - 8), gap = 1.0
            while t < at - 0.2 {
                scheduled.append((t, .click))
                t += gap
                gap = max(0.15, gap * 0.8)
            }
            scheduled += [(at, .notification), (at + 0.3, .directionUp), (at + 0.7, .success)]
            scheduled.sort { $0.at < $1.at }
        case "drop":
            play(.notification, force: true)
        case "marked":
            play((m["ok"] as? Bool ?? false) ? .success : .failure, force: true)
        case "song":
            title = m["title"] as? String ?? ""
            artist = m["artist"] as? String ?? ""
        case "stop":
            title = ""; artist = ""; bpm = 0; scheduled = []
        default:
            break
        }
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        while let e = scheduled.first, e.at <= now {
            scheduled.removeFirst()
            if now - e.at < 0.25 { play(e.type, force: true) }
        }
        guard beatsOn, bpm > 0, conf > 0.2, level > 0.1, now - tempoAt < 4 else { return }
        // the run-up to a moment owns the wrist
        if let next = scheduled.first, next.at - now < 8 { return }
        let period = 60 / bpm
        let step = period < 0.38 ? period * 2 : period   // the Watch can't tap every beat of a fast song
        if nextBeat == 0 || nextBeat < now - 0.1 { nextBeat = anchor + ceil((now - anchor) / step) * step }
        if now >= nextBeat {
            play(.click)
            nextBeat += step
        }
    }

    private func play(_ type: WKHapticType, force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastTap > 0.15 else { return }
        lastTap = now
        WKInterfaceDevice.current().play(type)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let r = session.isReachable
        DispatchQueue.main.async { self.reachable = r }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        DispatchQueue.main.async { self.reachable = r }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { self.handle(message) }
    }

    // MARK: WKExtendedRuntimeSessionDelegate

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}
    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}
    func extendedRuntimeSession(_ session: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        DispatchQueue.main.async { self.runtime = nil }
    }
}
