import Foundation

let appGroup = "group.com.supremelabssoftware.felt"

/// Seven floats kept as a tuple in the shared record (a fixed layout both processes agree on).
typealias Float7 = (Float, Float, Float, Float, Float, Float, Float)
func floats(_ t: Float7) -> [Float] { [t.0, t.1, t.2, t.3, t.4, t.5, t.6] }
func float7(_ a: [Float]) -> Float7 { a.count >= 7 ? (a[0], a[1], a[2], a[3], a[4], a[5], a[6]) : (0, 0, 0, 0, 0, 0, 0) }

/// What the broadcast extension (hearing this phone's own audio, headphones included) hands the app:
/// one fixed-size record in a memory-mapped file in the shared App Group. The counters only go up,
/// so the app never misses a beat or a drop even when it reads less often than the extension writes.
struct SharedState {
    var seq: UInt64 = 0
    var time: Double = 0
    var bands: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var energy: Float = 0
    var tension: Float = 0
    var brightness: Float = 0
    var beats: UInt32 = 0
    var drops: UInt32 = 0
    var snares: UInt32 = 0
    var hats: UInt32 = 0
    var voice: Float = 0
    var tempoSeq: UInt32 = 0
    var bpm: Double = 0
    var anchor: Double = 0
    var confidence: Double = 0
    var matchSeq: UInt32 = 0
    var regions: Float7 = (0, 0, 0, 0, 0, 0, 0)
    var sizzle: Float = 0
    var sweep: Float = 0
    var bassPitch: Float = 0.3
}

/// The song the extension recognised; written to match.json when `matchSeq` goes up.
struct SharedMatch: Codable {
    var id: String
    var title: String
    var artist: String
    var start: Double       // unix time the song's 0:00 played
}

final class SharedChannel {
    /// The audio itself, at 16 kHz, so the app can read the notes in it: four seconds, written round and round.
    static let audioRate = 16000.0, ringSize = 64000

    private var ptr: UnsafeMutablePointer<SharedState>?
    private var spec: UnsafeMutablePointer<Float>?
    private var ringCount: UnsafeMutablePointer<UInt64>?    // every sample ever written; only goes up
    private var ring: UnsafeMutablePointer<Float>?
    private let lock = NSLock()

    static var directory: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }
    static var matchURL: URL? { directory?.appendingPathComponent("match.json") }

    init() {
        guard let path = Self.directory?.appendingPathComponent("live.bin").path else { return }
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let head = MemoryLayout<SharedState>.stride + spectrumBins * MemoryLayout<Float>.stride
        let ringAt = (head + 15) / 16 * 16
        let size = ringAt + 16 + Self.ringSize * MemoryLayout<Float>.stride
        var st = stat()
        if fstat(fd, &st) == 0, st.st_size < size { ftruncate(fd, off_t(size)) }
        let m = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)
        guard let m, m != MAP_FAILED else { return }
        ptr = m.bindMemory(to: SharedState.self, capacity: 1)
        spec = (m + MemoryLayout<SharedState>.stride).bindMemory(to: Float.self, capacity: spectrumBins)
        ringCount = (m + ringAt).bindMemory(to: UInt64.self, capacity: 1)
        ring = (m + ringAt + 16).bindMemory(to: Float.self, capacity: Self.ringSize)
    }

    var state: SharedState? { ptr?.pointee }

    var spectrum: [Float] {
        guard let spec else { return [Float](repeating: 0, count: spectrumBins) }
        return Array(UnsafeBufferPointer(start: spec, count: spectrumBins))
    }

    /// The extension's side: 16 kHz mono audio, appended.
    func writeAudio(_ samples: UnsafeBufferPointer<Float>) {
        guard let ring, let ringCount else { return }
        var c = ringCount.pointee
        for x in samples {
            ring[Int(c % UInt64(Self.ringSize))] = x
            c += 1
        }
        ringCount.pointee = c
    }

    /// The app's side: everything written since `cursor`, which it moves on. The two processes share no lock, so it
    /// stops 256 samples (16 ms) short of the newest, which the writer may still be storing, and never reaches back
    /// further than the writer could already be overwriting. A cursor ahead of the count (the file was recreated)
    /// starts over from now.
    func readAudio(from cursor: inout UInt64) -> [Float] {
        guard let ring, let ringCount else { return [] }
        let c = ringCount.pointee
        guard c >= 256 else { return [] }
        let end = c - 256
        if cursor > c { cursor = end }
        let start = max(cursor, end > UInt64(Self.ringSize - 4096) ? end - UInt64(Self.ringSize - 4096) : 0)
        guard end > start else { return [] }
        var out = [Float](repeating: 0, count: Int(end - start))
        for i in 0..<out.count { out[i] = ring[Int((start + UInt64(i)) % UInt64(Self.ringSize))] }
        cursor = end
        return out
    }

    /// Where the audio has got to, for a reader starting now.
    var audioNow: UInt64 { ringCount.map { $0.pointee >= 256 ? $0.pointee - 256 : 0 } ?? 0 }

    func write(spectrum: [Float]? = nil, _ change: (inout SharedState) -> Void) {
        guard let ptr else { return }
        lock.lock()
        if let spectrum, let spec, spectrum.count == spectrumBins { spec.update(from: spectrum, count: spectrumBins) }
        change(&ptr.pointee)
        ptr.pointee.seq &+= 1
        lock.unlock()
    }
}
