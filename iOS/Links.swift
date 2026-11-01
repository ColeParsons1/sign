import AVFoundation
import ShazamKit
import WatchConnectivity

/// Works out which song is playing and where in it we are, from the same microphone audio.
/// That is what lets marked moments work for Spotify, YouTube, radio, anything.
final class Recognizer: NSObject, SHSessionDelegate {
    private let session = SHSession()
    var onMatch: ((SHMatchedMediaItem) -> Void)?
    var onError: ((Error) -> Void)?

    override init() {
        super.init()
        session.delegate = self
    }

    func feed(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        session.matchStreamingBuffer(buffer, at: time)
    }

    func session(_ session: SHSession, didFind match: SHMatch) {
        if let item = match.mediaItems.first { onMatch?(item) }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        if let error { onError?(error) }
    }
}

/// Messages to and from the Watch app. Callbacks arrive on the main queue.
final class WatchLink: NSObject, WCSessionDelegate {
    var onMark: (() -> Void)?
    var onReachability: ((Bool) -> Void)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ message: [String: Any]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) { reach(session) }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionReachabilityDidChange(_ session: WCSession) { reach(session) }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["k"] as? String == "mark" { DispatchQueue.main.async { self.onMark?() } }
    }

    private func reach(_ session: WCSession) {
        let r = session.isReachable
        DispatchQueue.main.async { self.onReachability?(r) }
    }
}
