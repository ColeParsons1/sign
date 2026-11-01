import Foundation

/// Sessions needed, alongside at least one marked moment, for a song to count as strongly imprinted.
let imprintGoal = 10

struct Moment: Codable, Identifiable {
    var id = UUID()
    var t: Double           // seconds into the song
    var text: String
}

struct SongRecord: Codable, Identifiable {
    var id: String          // Shazam ID
    var title: String
    var artist: String
    var sessions = 0
    var moments: [Moment] = []
}

/// Every song's moments and session count, saved to felt-songs.json in the app's Documents
/// folder. That folder shows up in the Files app under Felt, so it can be backed up.
@MainActor
final class Library: ObservableObject {
    @Published var songs: [String: SongRecord] = [:]
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("felt-songs.json")

    init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([String: SongRecord].self, from: d) {
            songs = s
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(songs) { try? d.write(to: url, options: .atomic) }
    }
}
