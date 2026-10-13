import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loggedOut:
            LoginView()
        case .checking:
            ProgressView("Logging in…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let client):
            MainView(client: client)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't reach RVRB", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.validate() } }
                    .buttonStyle(.borderedProminent)
                Button("Log Out", role: .destructive) { Task { await model.logOut() } }
            }
        }
    }
}
