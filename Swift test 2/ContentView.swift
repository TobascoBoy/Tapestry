import SwiftUI

struct ContentView: View {
    var body: some View {
        ProfileView()
    }
}

#Preview {
    ContentView()
        .environment(TapestryStore())
        .environment(AuthManager())
}
