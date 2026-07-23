import AppKit
import SwiftUI
import WebKit

/// Renders model-authored artifacts inside one persistent, isolated WebView.
/// While tokens arrive, a throttled DOM preview renders the partial HTML with
/// model scripts disabled. Once complete, the same WebView loads the final
/// document and enables its self-contained interactions.
struct AIHTMLArtifactView: View {
    let html: String
    let colorScheme: ColorScheme
    let isStreaming: Bool

    var body: some View {
        IsolatedArtifactWebView(
            html: html,
            colorScheme: colorScheme,
            phase: isStreaming ? .streaming : .complete
        )
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .accessibilityLabel(isStreaming ? "Streaming AI response" : "AI response artifact")
    }

    static func looksLikeHTML(_ value: String) -> Bool {
        let trimmed = stripCodeFence(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<html")
            || trimmed.hasPrefix("<main") || trimmed.hasPrefix("<article")
    }

    static func finalDocument(from raw: String, colorScheme: ColorScheme) -> String {
        let content = normalizeEmbeddedViewport(
            stripCodeFence(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let scheme = colorScheme == .dark ? "dark" : "light"
        let securityHead = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(scheme)">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>html,body{margin:0;min-width:0;overflow:hidden;background:transparent}*{box-sizing:border-box}img,svg,video{max-width:100%}</style>
        """

        if content.range(of: "<head", options: .caseInsensitive) != nil,
           let head = content.range(of: "<head", options: .caseInsensitive),
           let close = content.range(of: ">", range: head.lowerBound..<content.endIndex) {
            var value = content
            value.insert(contentsOf: securityHead, at: close.upperBound)
            return value
        }
        if content.range(of: "<html", options: .caseInsensitive) != nil,
           let html = content.range(of: "<html", options: .caseInsensitive),
           let close = content.range(of: ">", range: html.lowerBound..<content.endIndex) {
            var value = content
            value.insert(contentsOf: "<head>\(securityHead)</head>", at: close.upperBound)
            return value
        }
        if looksLikeHTML(content) {
            return "<!doctype html><html><head>\(securityHead)</head><body>\(content)</body></html>"
        }
        return """
        <!doctype html><html><head>\(securityHead)
        <style>body{font:14px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;color:\(colorScheme == .dark ? "#f2f2f2" : "#202020");padding:18px}pre{white-space:pre-wrap;font:inherit;margin:0}</style>
        </head><body><pre>\(escape(content))</pre></body></html>
        """
    }

    static func streamingShell(colorScheme: ColorScheme) -> String {
        let scheme = colorScheme == .dark ? "dark" : "light"
        let text = colorScheme == .dark ? "#f2f2f2" : "#202020"
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="\(scheme)">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; font-src data:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
          <style id="stream-base">
            html,body{margin:0;min-width:0;overflow:hidden;background:transparent;color:\(text)}
            *{box-sizing:border-box}img,svg,video{max-width:100%}
            #stream-root{min-height:118px;padding:1px}
            .streaming-placeholder{display:flex;align-items:center;gap:8px;padding:18px;font:12px/1.4 -apple-system,BlinkMacSystemFont,sans-serif;opacity:.58}
            .streaming-dot{width:7px;height:7px;border-radius:50%;background:currentColor;animation:pulse 1s ease-in-out infinite alternate}
            @keyframes pulse{from{opacity:.25;transform:scale(.8)}to{opacity:1;transform:scale(1)}}
          </style>
          <style id="stream-model-styles"></style>
        </head>
        <body>
          <div id="stream-root"><div class="streaming-placeholder"><span class="streaming-dot"></span><span>Building the response…</span></div></div>
        </body>
        </html>
        """
    }

    /// Runs as a WebKit user script rather than page-authored JavaScript. This
    /// keeps the streaming shell's CSP strict while still allowing Freewrite to
    /// incrementally replace its sanitized DOM as tokens arrive.
    static let streamingRendererScript = """
          (() => {
            window.__freewriteRender = encoded => {
              try {
                const binary = atob(encoded);
                const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
                let raw = new TextDecoder().decode(bytes).trim();
                raw = raw.replace(/^\\s*```(?:html)?\\s*/i, '').replace(/```\\s*$/i, '');
                // An artifact is embedded in a scrolling conversation, not a
                // browser page. A 100vh minimum creates a self-reinforcing
                // blank viewport in the expanded panel, so size that root to
                // its actual contents in both streaming and final phases.
                raw = raw.replace(/min-height\\s*:\\s*100(?:d|s|l)?vh/gi, 'min-height:auto');
                const parsed = new DOMParser().parseFromString(raw, 'text/html');
                parsed.querySelectorAll('script,iframe,object,embed,form,meta[http-equiv]').forEach(node => node.remove());
                parsed.querySelectorAll('*').forEach(node => {
                  for (const attribute of Array.from(node.attributes)) {
                    if (/^on/i.test(attribute.name)) node.removeAttribute(attribute.name);
                  }
                });
                const styles = Array.from(parsed.querySelectorAll('style'))
                  .map(node => node.textContent || '').join('\\n');
                document.getElementById('stream-model-styles').textContent = styles;
                parsed.querySelectorAll('style').forEach(node => node.remove());
                const root = document.getElementById('stream-root');
                const nodes = Array.from(parsed.body.childNodes)
                  .map(node => document.importNode(node, true));
                if (nodes.length) {
                  root.replaceChildren(...nodes);
                } else {
                  root.innerHTML = '<div class="streaming-placeholder"><span class="streaming-dot"></span><span>Building the response…</span></div>';
                }
                window.__freewriteReportHeight?.();
                requestAnimationFrame(() => window.__freewriteReportHeight?.());
                setTimeout(() => window.__freewriteReportHeight?.(), 50);
              } catch (error) {
                console.error('Freewrite streaming render failed', error);
              }
            };
          })();
        """

    static func stripCodeFence(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("```html") { trimmed.removeFirst(7) }
        else if trimmed.hasPrefix("```") { trimmed.removeFirst(3) }
        if trimmed.hasSuffix("```") { trimmed.removeLast(3) }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeEmbeddedViewport(_ value: String) -> String {
        value.replacingOccurrences(
            of: "(?i)min-height\\s*:\\s*100(?:d|s|l)?vh",
            with: "min-height:auto",
            options: .regularExpression
        )
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private enum ArtifactRenderPhase: Equatable {
    case streaming
    case complete
}

/// Owns WebKit sizing entirely in AppKit. No script callback writes a SwiftUI
/// binding, avoiding state publication during SwiftUI's view-update pass.
private final class ArtifactContainerView: NSView {
    let webView: WKWebView
    private(set) var measuredHeight: CGFloat

    init(webView: WKWebView, initialHeight: CGFloat) {
        self.webView = webView
        self.measuredHeight = initialHeight
        super.init(frame: .zero)
        addSubview(webView)
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    func updateMeasuredHeight(_ rawHeight: CGFloat) {
        let next = min(100_000, max(118, rawHeight.rounded(.up)))
        guard abs(next - measuredHeight) > 1 else { return }
        measuredHeight = next
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

private struct IsolatedArtifactWebView: NSViewRepresentable {
    let html: String
    let colorScheme: ColorScheme
    let phase: ArtifactRenderPhase

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ArtifactContainerView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "artifactHeight")
        controller.addUserScript(WKUserScript(
            source: AIHTMLArtifactView.streamingRendererScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: """
            (() => {
              let lastHeight = 0;
              const report = () => {
                const next = Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0);
                if (Math.abs(next - lastHeight) < 1) return;
                lastHeight = next;
                window.webkit.messageHandlers.artifactHeight.postMessage(next);
              };
              window.__freewriteReportHeight = report;
              new ResizeObserver(() => requestAnimationFrame(report)).observe(document.documentElement);
              window.addEventListener('load', report, { once: true });
              setTimeout(report, 50);
              setTimeout(report, 300);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        let container = ArtifactContainerView(
            webView: webView,
            initialHeight: phase == .streaming ? 118 : 360
        )
        context.coordinator.attach(container: container)
        context.coordinator.installScrollForwarding(for: webView)
        context.coordinator.update(
            html: html,
            colorScheme: colorScheme,
            phase: phase,
            in: webView,
            force: true
        )
        return container
    }

    func updateNSView(_ container: ArtifactContainerView, context: Context) {
        context.coordinator.update(
            html: html,
            colorScheme: colorScheme,
            phase: phase,
            in: container.webView,
            force: false
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ArtifactContainerView,
                      context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? max(320, nsView.fittingSize.width),
            height: nsView.measuredHeight
        )
    }

    static func dismantleNSView(_ container: ArtifactContainerView, coordinator: Coordinator) {
        coordinator.teardown()
        container.webView.stopLoading()
        container.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "artifactHeight")
        container.webView.navigationDelegate = nil
        container.webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private weak var container: ArtifactContainerView?
        private var phase: ArtifactRenderPhase?
        private var colorScheme: ColorScheme = .light
        private var pendingHTML = ""
        private var lastStreamedHTML = ""
        private var finalHTML = ""
        private var shellReady = false
        private var lastPreviewAt = Date.distantPast
        private var previewWorkItem: DispatchWorkItem?
        private var heightWorkItem: DispatchWorkItem?
        private var scrollMonitor: Any?

        func attach(container: ArtifactContainerView) {
            self.container = container
        }

        func update(html: String, colorScheme: ColorScheme, phase nextPhase: ArtifactRenderPhase,
                    in webView: WKWebView, force: Bool) {
            self.colorScheme = colorScheme
            switch nextPhase {
            case .streaming:
                pendingHTML = html
                if force || phase != .streaming {
                    phase = .streaming
                    shellReady = false
                    lastStreamedHTML = ""
                    previewWorkItem?.cancel()
                    webView.loadHTMLString(
                        AIHTMLArtifactView.streamingShell(colorScheme: colorScheme),
                        baseURL: nil
                    )
                } else {
                    schedulePreview(in: webView)
                }
            case .complete:
                guard force || phase != .complete || finalHTML != html else { return }
                phase = .complete
                finalHTML = html
                shellReady = false
                previewWorkItem?.cancel()
                webView.loadHTMLString(
                    AIHTMLArtifactView.finalDocument(from: html, colorScheme: colorScheme),
                    baseURL: nil
                )
                print("[AIChatRender] final artifact loading chars=\(html.count)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if phase == .streaming {
                webView.evaluateJavaScript("typeof window.__freewriteRender") { [weak self, weak webView] result, error in
                    guard let self, let webView, self.phase == .streaming else { return }
                    guard error == nil, result as? String == "function" else {
                        print("[AIChatRender] streaming shell unavailable result=\(String(describing: result)) error=\(String(describing: error))")
                        return
                    }
                    self.shellReady = true
                    print("[AIChatRender] streaming artifact ready")
                    self.schedulePreview(in: webView, immediately: true)
                }
            } else {
                webView.evaluateJavaScript("window.__freewriteReportHeight?.()")
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("[AIChatRender] WebContent process terminated phase=\(phase == .streaming ? "streaming" : "complete")")
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "artifactHeight", let raw = message.body as? NSNumber else { return }
            let next = CGFloat(truncating: raw)
            heightWorkItem?.cancel()
            let update = DispatchWorkItem { [weak self] in
                self?.container?.updateMeasuredHeight(next)
            }
            heightWorkItem = update
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: update)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let url = navigationAction.request.url
            decisionHandler(url == nil || url?.scheme == "about" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        func installScrollForwarding(for webView: WKWebView) {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak webView] event in
                guard let webView,
                      let window = webView.window,
                      event.window === window else { return event }
                let point = webView.convert(event.locationInWindow, from: nil)
                guard webView.bounds.contains(point),
                      let outerScrollView = Self.outerScrollView(for: webView) else { return event }
                outerScrollView.scrollWheel(with: event)
                return nil
            }
        }

        func teardown() {
            previewWorkItem?.cancel()
            heightWorkItem?.cancel()
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
        }

        private func schedulePreview(in webView: WKWebView, immediately: Bool = false) {
            guard shellReady, pendingHTML != lastStreamedHTML else { return }
            if previewWorkItem != nil && !immediately { return }
            previewWorkItem?.cancel()
            let elapsed = Date().timeIntervalSince(lastPreviewAt)
            let delay = immediately ? 0 : max(0, 0.16 - elapsed)
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.previewWorkItem = nil
                self.renderPendingPreview(in: webView)
            }
            previewWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func renderPendingPreview(in webView: WKWebView) {
            guard phase == .streaming, shellReady, pendingHTML != lastStreamedHTML else { return }
            let value = pendingHTML
            lastStreamedHTML = value
            lastPreviewAt = Date()
            let encoded = Data(value.utf8).base64EncodedString()
            webView.evaluateJavaScript("window.__freewriteRender('\(encoded)')") { [weak self, weak webView] _, error in
                if let error {
                    let value = error as NSError
                    print("[AIChatRender] streaming DOM update failed code=\(value.code) detail=\(value.userInfo)")
                }
                guard let self, let webView, self.pendingHTML != self.lastStreamedHTML else { return }
                self.schedulePreview(in: webView)
            }
        }

        private static func outerScrollView(for webView: WKWebView) -> NSScrollView? {
            var ancestor = webView.superview
            while let view = ancestor {
                if let scrollView = view as? NSScrollView { return scrollView }
                ancestor = view.superview
            }
            return nil
        }
    }
}
