import AppKit
import WebKit

/// A page an agent opened beside its terminal (`pane browse`), driven by `pane eval`. Lives only as long as the app:
/// the agent that opened it opens it again.
@MainActor final class WebPaneView: NSView, WKNavigationDelegate {
    let paneID: PaneID
    private let webView: FocusWebView
    private var loaded = false
    /// Evals sent before the first load finished run against the page, not the blank document before it.
    private var queued: [(String, (String) -> Void)] = []
    private var titleWatch: NSKeyValueObservation?
    var onFocus: ((PaneID) -> Void)?
    var onTitle: ((PaneID, String) -> Void)?
    var onOpenLink: ((URL) -> Void)?

    init(id: PaneID, url: URL, theme: Theme) {
        paneID = id
        webView = FocusWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init(frame: .zero)
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.isInspectable = true
        webView.onFocus = { [unowned self] in onFocus?(paneID) }
        addSubview(webView)
        apply(theme: theme)
        titleWatch = webView.observe(\.title) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, let t = web.title, !t.isEmpty else { return }
                self.onTitle?(self.paneID, t)
            }
        }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(webView) ?? false }

    func apply(theme: Theme) {
        webView.underPageBackgroundColor = theme.color("background")   // no white flash before the page paints
    }

    func close() {
        titleWatch = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        for (_, done) in queued { done(#"{"error":"pane closed"}"#) }
        queued = []
    }

    /// Runs `code` in the page; `done` gets `{"result": <value>}` (null for undefined or a value with no JSON form)
    /// or `{"error": "<message>"}`.
    func evaluate(_ code: String, done: @escaping (String) -> Void) {
        guard loaded else { queued.append((code, done)); return }
        webView.evaluateJavaScript(code) { value, error in
            MainActor.assumeIsolated {
                if let error = error as? NSError, !(error.domain == WKError.errorDomain && error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue) {
                    done(Self.json(["error": error.localizedDescription]))
                } else {
                    done(Self.json(["result": value ?? NSNull()]))
                }
            }
        }
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj), let d = try? JSONSerialization.data(withJSONObject: obj) else {
            return #"{"result":null}"#
        }
        return String(decoding: d, as: UTF8.self)
    }

    private func drain() {
        loaded = true
        let pending = queued
        queued = []
        for (code, done) in pending { evaluate(code, done: done) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { drain() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { drain() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { drain() }

    /// Links the person clicks leave for the browser (or the ⌘-click policy); the page itself stays put.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            onOpenLink?(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }
}

private final class FocusWebView: WKWebView {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}
