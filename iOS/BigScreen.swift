import SwiftUI
import UIKit

// The big screen. With a TV or projector connected, by a USB-C to HDMI cable or by AirPlay Screen
// Mirroring from Control Center, iOS offers the app the second screen as a scene of its own instead of
// a copy of the phone. Felt puts the show there, full screen and the right way round, and the phone
// becomes the controller.

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            config.delegateClass = BigScreenSceneDelegate.self
        }
        return config
    }
}

final class BigScreenSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Self.sharpen(windowScene.screen)
        let host = UIHostingController(rootView: BigScreenView(engine: .shared))
        host.view.backgroundColor = .black
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        Engine.shared.bigScreen = windowScene.screen.bounds.size
    }

    /// As sharp as the screen allows (Cole, 2026-10-29: the picture went soft on the projector). iOS shrinks the
    /// picture by default to keep it inside an old TV's overscan, which resamples every pixel: no overscan shrink, the
    /// picture drawn to the screen's own pixels, edge to edge. And the screen's largest mode up to 1080p, not past it:
    /// at 4K the phone draws Medicina with music at a third of its frame rate (Cole, later: "still really poor on the
    /// projector… when the music is not playing the quality is good"), and a 4K projector shows 1080p cleanly, each
    /// pixel exactly four of its own.
    static func sharpen(_ screen: UIScreen) {
        screen.overscanCompensation = .none
        let area = { (m: UIScreenMode) in m.size.width * m.size.height }
        let fits = screen.availableModes.filter { area($0) <= 1920 * 1080 + 1 }
        if let best = fits.max(by: { area($0) < area($1) }), let now = screen.currentMode, area(best) != area(now) {
            screen.currentMode = best
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        Engine.shared.bigScreen = nil
    }
}

/// What the big screen shows: the picture, edge to edge, and the words of a marked moment, large.
struct BigScreenView: View {
    @ObservedObject var engine: Engine
    @AppStorage("visualMode") private var visualMode = journeyMode

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Visualizer(engine: engine, mode: visualMode, show: .shared)
                SongCard(engine: engine, scale: min(geo.size.width, geo.size.height) / 400)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                if let line = engine.line {
                    Text(line)
                        .font(.system(size: min(geo.size.width, geo.size.height) * 0.07, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 30)
                        .padding(geo.size.width * 0.06)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .background(.black)
    }
}
