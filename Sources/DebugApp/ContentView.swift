import SwiftUI

struct ContentView: View {
    @State private var state = PipelineState()

    var body: some View {
        TabView {
            DictationView(state: state)
                .tabItem { Label("Dictation", systemImage: "mic.fill") }
            ModelsView(state: state)
                .tabItem { Label("Models", systemImage: "cube.box.fill") }
            DictionaryView(store: state.dictionary)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .padding(12)
        .sheet(isPresented: $state.showOllamaSetup) {
            OllamaSetupView(state: state) {
                state.showOllamaSetup = false
            }
        }
        .onAppear {
            state.checkOllamaStatus()
        }
    }
}
