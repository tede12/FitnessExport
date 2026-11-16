import FitnessUI
import SwiftUI
import WebKit

struct GarminLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let onTicket: (_ ticket: String, _ serviceURL: String) async -> Void

    @State private var status = AppLanguage.text("Accedi con il tuo account Garmin.")
    @State private var currentHost = ""
    @State private var isFinishing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GarminWebView(
                    onNavigate: { currentHost = $0 },
                    onTicket: { ticket, serviceURL in
                        guard !isFinishing else { return }
                        isFinishing = true
                        status = AppLanguage.text("Accesso riuscito, recupero la sessione…")
                        Task {
                            await onTicket(ticket, serviceURL)
                            dismiss()
                        }
                    }
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if isFinishing { ProgressView() }
                        Text(status).font(.footnote)
                    }
                    Text(currentHost)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
            }
            .navigationTitle("Garmin Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.text("Annulla")) { dismiss() }
                }
            }
        }
    }
}

private struct GarminWebView: UIViewRepresentable {
    let onNavigate: (String) -> Void
    let onTicket: (String, String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: GarminAuthenticator.loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate, onTicket: onTicket)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigate: (String) -> Void
        let onTicket: (String, String) -> Void
        private var didNotify = false

        init(onNavigate: @escaping (String) -> Void, onTicket: @escaping (String, String) -> Void) {
            self.onNavigate = onNavigate
            self.onTicket = onTicket
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            let url = navigationAction.request.url
            onNavigate(url?.host ?? "")
            GarminAuthenticator.logger.info("Navigation policy evaluated")

            if !didNotify, let found = GarminAuthenticator.serviceTicket(in: url) {
                didNotify = true
                GarminAuthenticator.logger.info("Service ticket intercepted")
                onTicket(found.ticket, found.serviceURL)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigate(webView.url?.host ?? "")
            guard !didNotify else { return }

            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let self, !self.didNotify, let html = result as? String,
                    let found = GarminAuthenticator.serviceTicket(inPageText: html)
                else { return }
                self.didNotify = true
                GarminAuthenticator.logger.info("Service ticket found in page")
                self.onTicket(found.ticket, found.serviceURL)
            }
        }
    }
}
