import SwiftUI

/// GrembleVoice interactive debug application.
///
/// Tests the full pipeline: mic capture → ASR → (optional) refinement.
///
/// **Mic access:** On macOS the process needs microphone permission.
/// - From Xcode: add `NSMicrophoneUsageDescription` to the scheme's custom Info.plist
///   (Product → Scheme → Run → Info tab → Custom macOS Application Target Properties).
/// - From Terminal via `swift run`: grant Terminal microphone access in
///   System Settings → Privacy & Security → Microphone.
@main
struct DebugApp: App {
    var body: some Scene {
        WindowGroup("GrembleVoice Debug") {
            ContentView()
                .frame(minWidth: 800, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 960, height: 640)
    }
}
