import SwiftUI
import WebKit

/// RVRB logs in through Spotify only, and its OAuth redirect is fixed to RVRB's own web app, which ends up at
/// `https://app.rvrb.one/login/?session=<JWT>`. The login runs in a web view that watches for that page and takes
/// the token from it. Pasting the URL or token is the fallback.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var showsWebLogin = false
    @State private var pasted = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)

                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Rvrb")
                        .font(.largeTitle.bold())
                    Text("Listen together in RVRB channels. Music plays on your own Spotify.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if let message = model.loginMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Button {
                    showsWebLogin = true
                } label: {
                    Label("Log In with Spotify", systemImage: "person.crop.circle")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                DisclosureGroup("Paste a session token instead") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Log in at app.rvrb.one/api/login/spotify in a browser, then paste the address you land on (…/login/?session=…) or just the token.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextField("https://app.rvrb.one/login/?session=…", text: $pasted, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Log In") {
                            if let token = Session.parsePastedToken(pasted) {
                                Task { await model.logIn(token: token) }
                            }
                        }
                        .disabled(Session.parsePastedToken(pasted) == nil)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: 420)

                Spacer(minLength: 40)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showsWebLogin) {
            WebLoginSheet { token in
                showsWebLogin = false
                Task { await model.logIn(token: token) }
            }
        }
    }
}

private struct WebLoginSheet: View {
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            LoginWebView(isLoading: $isLoading, onToken: onToken)
                .overlay {
                    if isLoading { ProgressView() }
                }
                .navigationTitle("Log In with Spotify")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 680)
        #endif
    }
}

#if os(iOS)
private typealias ViewRepresentable = UIViewRepresentable
#else
private typealias ViewRepresentable = NSViewRepresentable
#endif

private struct LoginWebView: ViewRepresentable {
    @Binding var isLoading: Bool
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    #else
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    #endif

    private func makeWebView(_ context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://app.rvrb.one/api/login/spotify")!))
        return webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LoginWebView
        private var done = false

        init(_ parent: LoginWebView) {
            self.parent = parent
        }

        /// The callback lands on `https://app.rvrb.one/login/?session=<JWT>&spotifyToken=...`: take the session.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  url.host() == "app.rvrb.one", url.path().hasPrefix("/login"),
                  let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "session" })?.value,
                  !token.isEmpty
            else { return .allow }

            if !done {
                done = true
                parent.onToken(token)
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        /// Pop-up logins (e.g. "Continue with Apple") open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
