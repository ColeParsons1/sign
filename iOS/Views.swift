import ReplayKit
import SwiftUI

@main
struct FeltApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        // FELT_MODE=Medicina opens on that picture; with FELT_DEMO_FILE it starts listening by itself (for checking the show)
        let env = ProcessInfo.processInfo.environment
        if let mode = env["FELT_MODE"] { UserDefaults.standard.set(mode, forKey: "visualMode") }
        if env["FELT_DEMO_FILE"] != nil { DispatchQueue.main.async { Engine.shared.start() } }
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView(engine: .shared) }
    }
}

struct ContentView: View {
    @ObservedObject var engine: Engine
    @State private var showTracker = false
    @State private var draft = ""
    @State private var picker = BroadcastPicker.make()
    @State private var projector = false
    @AppStorage("visualMode") private var visualMode = journeyMode
    @AppStorage("showBrightness") private var brightness = 1.0

    var body: some View {
        if projector {
            ProjectorView(engine: engine) { projector = false }
                .preferredColorScheme(.dark)
        } else {
            main
        }
    }

    private var main: some View {
        ZStack {
            if engine.bigScreen == nil {
                Visualizer(engine: engine, mode: visualMode).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            BroadcastPicker(view: picker).frame(width: 1, height: 1).opacity(0.01)
            if let line = engine.line, engine.bigScreen == nil {
                Text(line)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 18)
                    .padding(24)
                    .transition(.opacity)
            }
            #if DEBUG
            let clean = ProcessInfo.processInfo.environment["FELT_CLEAN"] != nil    // FELT_CLEAN=1: the picture alone, for checking it
            #else
            let clean = false
            #endif
            if clean && engine.bigScreen == nil { SongCard(engine: engine).frame(maxHeight: .infinity, alignment: .bottom) }
            if !clean { VStack(spacing: 14) {
                header
                if let size = engine.bigScreen { bigScreenPanel(size) }
                Spacer()
                if engine.listening {
                    phoneButton
                    markButton
                }
                controls
            }
            .padding() }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTracker) { TrackerView(library: engine.library) }
        .alert("Moment saved", isPresented: Binding(get: { engine.asking != nil }, set: { if !$0 { engine.asking = nil } })) {
            TextField("A lyric, or what it means to you", text: $draft)
            Button("Save") {
                if let id = engine.asking { engine.setText(draft, for: id) }
                draft = ""
            }
            Button("Skip", role: .cancel) { draft = "" }
        } message: {
            Text("What is this moment? It will appear on screen every time the song reaches it.")
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(engine.song?.title ?? (engine.listening ? "Listening…" : "Felt"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let s = engine.song {
                if !s.artist.isEmpty { Text(s.artist).foregroundStyle(.secondary) }
                Text("Imprinted \(s.sessions)× · \(s.moments.count) moment\(s.moments.count == 1 ? "" : "s")")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(engine.status)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if engine.listening {
                // the light each instrument has in the picture, lit as it plays
                HStack(spacing: 10) {
                    ForEach(Instrument.allCases, id: \.self) { i in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hue: i.hue, saturation: 0.85, brightness: 1))
                                .frame(width: 8, height: 8)
                                .scaleEffect(1 + engine.lights.level(i) * 0.6)
                                .opacity(0.25 + min(1, engine.lights.level(i)) * 0.75)
                            Text(i.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
            Label(engine.watchReachable ? "Watch connected" : "Watch not connected", systemImage: "applewatch")
                .font(.caption)
                .foregroundStyle(engine.watchReachable ? .green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    /// With a TV or projector connected the phone is the controller: what the room sees, live, and every
    /// picture one tap away.
    private func bigScreenPanel(_ size: CGSize) -> some View {
        VStack(spacing: 10) {
            Label("On the big screen", systemImage: "tv").font(.subheadline.weight(.semibold))
            Visualizer(engine: engine, mode: visualMode, show: .shared, primary: false)
                .aspectRatio(size.width / max(1, size.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visualModes, id: \.self) { m in
                        Button(m) { visualMode = m }
                            .buttonStyle(.bordered)
                            .tint(m == visualMode ? .electricOrange : .white)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Opens iOS's broadcast sheet. While it runs, Felt hears everything this phone plays, headphones included.
    private var phoneButton: some View {
        Button { BroadcastPicker.open(picker) } label: {
            Label(engine.hearingPhone ? (engine.phoneOnly ? "Hearing this phone only" : "Hearing this phone · headphones too")
                                      : "Hear this phone (headphones, Spotify, YouTube…)",
                  systemImage: engine.hearingPhone ? "checkmark.circle.fill" : "headphones")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(engine.hearingPhone ? .green : .white)
    }

    private var markButton: some View {
        Button { engine.mark() } label: {
            Text("This hits me")
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(.electricOrange)
        .foregroundStyle(.black)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Button(engine.listening ? "Stop" : "Listen") {
                    if engine.listening { engine.stop(); return }
                    engine.start()
                    // phone only: nothing is heard until the broadcast runs, so offer it straight away
                    if engine.phoneOnly && !engine.hearingPhone { BroadcastPicker.open(picker) }
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.listening ? .gray : .white)
                .foregroundStyle(.black)
                if engine.lightAvailable {
                    Button { engine.lightOn.toggle() } label: {
                        Image(systemName: engine.lightOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .frame(width: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(engine.lightOn ? .electricOrange : .white)
                    .accessibilityLabel(engine.lightOn ? "Turn light show off" : "Turn light show on")
                }
                Button {
                    if !engine.listening { engine.start() }
                    projector = true
                } label: {
                    Image(systemName: "videoprojector").frame(width: 28)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityLabel("Projector mode")
                Spacer()
                Menu {
                    Picker("Picture", selection: $visualMode) {
                        ForEach(visualModes, id: \.self) { Text($0) }
                    }
                } label: {
                    Image(systemName: "sparkles").frame(width: 28)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityLabel("Picture: \(visualMode)")
                Button("Imprint tracker") { showTracker = true }
                    .buttonStyle(.bordered)
            }
            // what Felt listens to: this phone's own audio alone (headphones; the room never picked up), or the phone
            // and the room together
            Picker("Listen to", selection: $engine.phoneOnly) {
                Label("Phone only", systemImage: "headphones").tag(true)
                Label("Phone + room", systemImage: "mic").tag(false)
            }
            .pickerStyle(.segmented)
            HStack {
                // the whole picture's brightness, every scene (and the big screen): dim at the left, as drawn in the
                // middle, brighter at the right
                Image(systemName: "sun.max")
                Slider(value: $brightness, in: 0.2...2.0)
                Text("Brightness \(Int((brightness * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .onTapGesture(count: 2) { brightness = 1 }      // double-tap: back to as drawn
            }
            HStack {
                Image(systemName: "hand.tap")
                Slider(value: $engine.intensity, in: 0...1.5)
                Text(engine.intensity < 0.02 ? "Vibration off" : "Vibration").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Projector

/// Just the picture, full brightness, for a smartphone projector box or a lens. A lens flips the image,
/// so it can be rotated in quarter turns and mirrored; both are remembered. Tap to bring the controls back.
struct ProjectorView: View {
    @ObservedObject var engine: Engine
    let exit: () -> Void
    @AppStorage("projectorTurns") private var turns = 0
    @AppStorage("projectorMirror") private var mirror = false
    @AppStorage("visualMode") private var visualMode = journeyMode
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var savedBrightness: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let sideways = turns % 2 == 1
            ZStack {
                Visualizer(engine: engine, mode: visualMode)
                SongCard(engine: engine, scale: 1.5).frame(maxHeight: .infinity, alignment: .bottom)
                if let line = engine.line {
                    Text(line)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 20)
                        .padding(32)
                        .transition(.opacity)
                }
            }
            .frame(width: sideways ? geo.size.height : geo.size.width, height: sideways ? geo.size.width : geo.size.height)
            .scaleEffect(x: mirror ? -1 : 1, y: 1)
            .rotationEffect(.degrees(Double(turns) * 90))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture { showControls() }
        .overlay(alignment: .bottom) {
            if controls {
                VStack(spacing: 10) {
                    Text("Rotate and mirror until it looks right on the wall. Tap anywhere to bring these back.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button { turns = (turns + 1) % 4; showControls() } label: { Label("Rotate", systemImage: "rotate.right") }
                        Button { mirror.toggle(); showControls() } label: { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                        Spacer()
                        Button("Exit", action: exit).tint(.electricOrange)
                    }
                    .buttonStyle(.bordered)
                    .lineLimit(1)
                    Button {
                        visualMode = visualModes[((visualModes.firstIndex(of: visualMode) ?? 0) + 1) % visualModes.count]
                        showControls()
                    } label: {
                        Label("Picture: \(visualMode)", systemImage: "sparkles").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
                .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if let screen = Self.screen {
                savedBrightness = screen.brightness
                screen.brightness = 1
            }
            showControls()
        }
        .onDisappear {
            if let b = savedBrightness { Self.screen?.brightness = b }
            hideTask?.cancel()
        }
    }

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private func showControls() {
        withAnimation { controls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { controls = false }
        }
    }
}

// MARK: - Broadcast

/// iOS only starts a broadcast from its own picker button, so Felt keeps one (nearly invisible)
/// in the view and presses it from its own button.
struct BroadcastPicker: UIViewRepresentable {
    let view: RPSystemBroadcastPickerView

    static func make() -> RPSystemBroadcastPickerView {
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        p.preferredExtension = "com.supremelabssoftware.felt.broadcast"
        p.showsMicrophoneButton = false
        return p
    }

    static func open(_ picker: RPSystemBroadcastPickerView) {
        for case let button as UIButton in picker.subviews { button.sendActions(for: .allTouchEvents) }
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { view }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

// MARK: - Tracker

struct TrackerView: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss

    private var sorted: [SongRecord] { library.songs.values.sorted { $0.sessions > $1.sessions } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let strong = sorted.filter { $0.sessions >= imprintGoal && !$0.moments.isEmpty }.count
                    Text("\(strong) of \(sorted.count) songs strongly imprinted (\(imprintGoal)+ sessions and a marked moment)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(sorted) { s in
                    NavigationLink { MomentsView(library: library, id: s.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).font(.headline)
                            if !s.artist.isEmpty { Text(s.artist).font(.subheadline).foregroundStyle(.secondary) }
                            HStack(spacing: 3) {
                                ForEach(0..<imprintGoal, id: \.self) { i in
                                    Circle().fill(i < s.sessions ? Color.electricOrange : Color.white.opacity(0.15)).frame(width: 7, height: 7)
                                }
                                Text("\(s.sessions)× · \(s.moments.count) moment\(s.moments.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
                            }
                        }
                    }
                }
            }
            .overlay { if sorted.isEmpty { ContentUnavailableView("No songs yet", systemImage: "music.note", description: Text("Tap Listen and play a song you love.")) } }
            .navigationTitle("Imprint tracker")
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}

struct MomentsView: View {
    @ObservedObject var library: Library
    let id: String

    var body: some View {
        List {
            ForEach(library.songs[id]?.moments ?? []) { m in
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%d:%02d", Int(m.t) / 60, Int(m.t) % 60)).monospacedDigit().foregroundStyle(Color.electricOrange)
                    Text(m.text.isEmpty ? "No words" : m.text).foregroundStyle(m.text.isEmpty ? .secondary : .primary)
                }
            }
            .onDelete { idx in
                library.songs[id]?.moments.remove(atOffsets: idx)
                library.save()
            }
        }
        .navigationTitle(library.songs[id]?.title ?? "")
    }
}

extension Color {
    /// Felt's accent (Cole, 2026-10-29: every yellow and gold is electric orange instead).
    static let electricOrange = Color(red: 1.0, green: 0.40, blue: 0.0)
}

/// The song's name on the picture itself (Cole, 2026-10-29: the show is for people who can't hear it, so when the song
/// is recognised its title and artist fade in, quietly, at the foot of the picture, stay a while, and fade away).
struct SongCard: View {
    @ObservedObject var engine: Engine
    var scale: CGFloat = 1
    @State private var shown: SongRecord?
    @State private var visible = false

    var body: some View {
        VStack(spacing: 4 * scale) {
            if let song = shown {
                Text(song.title)
                    .font(.system(size: 26 * scale, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))
                if !song.artist.isEmpty {
                    Text(song.artist.uppercased())
                        .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                        .tracking(3 * scale)
                        .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.25).opacity(0.85))
                }
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.9), radius: 16 * scale)
        .padding(.bottom, 40 * scale)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 2.2), value: visible)
        .allowsHitTesting(false)
        .task(id: engine.songID) {
            guard let song = engine.song else { visible = false; return }
            shown = song
            visible = true
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { visible = false }
        }
    }
}
