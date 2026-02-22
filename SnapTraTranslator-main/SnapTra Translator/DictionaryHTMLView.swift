import SwiftUI
@preconcurrency import WebKit

/// A SwiftUI view that renders dictionary HTML using WKWebView.
/// Displays the rich HTML content from the DCS record API with
/// proper styling that matches the overlay's dark/light appearance.
struct DictionaryHTMLView: NSViewRepresentable {
    let html: String

    /// Estimated content height reported by the web view after layout.
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let wrapped = wrapHTML(html)
        // Only reload when the HTML changes
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(wrapped, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(heightBinding: $contentHeight)
    }

    /// Wrap raw dictionary HTML with styles to match the overlay aesthetic.
    private func wrapHTML(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root {
                color-scheme: light dark;
            }
            * {
                -webkit-text-size-adjust: none;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
                font-size: 13px;
                line-height: 1.5;
                margin: 0;
                padding: 4px 0;
                background: transparent;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            /*
             * Dark mode: Set explicit default text color for dark backgrounds.
             * Override hardcoded inline colors (font[color], style="color:...")
             * so dictionary HTML renders like native Dictionary.app.
             */
            @media (prefers-color-scheme: dark) {
                body {
                    color: #e5e5e7;
                }
                /* Override hardcoded font color attributes that would be invisible on dark bg */
                font[color] {
                    color: inherit !important;
                }
                /* Ensure all span/div elements inherit the light text color
                   unless they have a more specific override below */
                span, div, p, li, td, th, dt, dd, blockquote, h1, h2, h3, h4, h5, h6 {
                    color: inherit;
                }
                /* Example sentences — slightly muted */
                span.x_xo0e, span.eg, .example, .x_xo0x {
                    color: #98989d !important;
                    font-style: italic;
                }
                /* Links */
                a, a * {
                    color: #64a8ff !important;
                }
                /* Sense numbers */
                .sensenum, .x_x0Sense .x_x0Num {
                    color: #64a8ff !important;
                }
            }
            @media (prefers-color-scheme: light) {
                /* Same approach for light mode — let the native colors through */
                font[color] {
                    color: inherit !important;
                }
                span.x_xo0e, span.eg, .example, .x_xo0x {
                    color: #6e6e73 !important;
                    font-style: italic;
                }
                a, a * {
                    color: #0066cc !important;
                }
                .sensenum, .x_x0Sense .x_x0Num {
                    color: #0066cc !important;
                }
            }
            /* Hide the headword from dictionary HTML — we already show it in the overlay header */
            h1, .hwg, .x_xh0, h2.x_xoHead {
                display: none !important;
            }
            /* Also hide any large pronunciation block at the top (we show our own) */
            .x_xo0Phonetics, .prHeader, .pronSection {
                display: none !important;
            }
            a {
                text-decoration: none;
            }
            .x_xo0d, .def {
                margin-bottom: 4px;
            }
            hr.snt-separator {
                border: none;
                border-top: 1px solid #98989d;
                opacity: 0.3;
                margin: 8px 0;
            }
            /* Tighten entry spacing */
            .entry, .x_xoEntry {
                margin-bottom: 6px;
            }
            /* Make POS labels styled */
            .x_xo0ps, .posg, .pos {
                font-weight: 600;
                font-size: 12px;
            }
            img { display: none; }
        </style>
        </head>
        <body>
        \(body)
        <script>
            // Remove hardcoded inline color styles so CSS color-scheme takes effect
            document.querySelectorAll('[style]').forEach(function(el) {
                var s = el.style;
                if (s.color) { s.removeProperty('color'); }
            });
            // Remove hardcoded color attributes on <font> tags
            document.querySelectorAll('font[color]').forEach(function(el) {
                el.removeAttribute('color');
            });
            // Report content height for auto-sizing
            function reportHeight() {
                let h = document.body.scrollHeight;
                document.title = String(h);
            }
            window.addEventListener('load', reportHeight);
            new ResizeObserver(reportHeight).observe(document.body);
        </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        private var heightBinding: Binding<CGFloat>

        init(heightBinding: Binding<CGFloat>) {
            self.heightBinding = heightBinding
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Read the content height from JS
            webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self?.heightBinding.wrappedValue = height
                    }
                }
            }
        }

        // Prevent navigating away on link clicks — open in default browser
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Convenience wrapper used by OverlayView

/// Self-contained WebView that auto-sizes to content height (capped at maxHeight).
/// WKWebView handles its own scrolling natively when content exceeds the frame.
struct DictionaryHTMLWebView: View {
    let html: String
    let maxHeight: CGFloat
    var onHeightChange: (() -> Void)?
    @State private var contentHeight: CGFloat = 10

    init(html: String, maxHeight: CGFloat = 400, onHeightChange: (() -> Void)? = nil) {
        self.html = html
        self.maxHeight = maxHeight
        self.onHeightChange = onHeightChange
    }

    var body: some View {
        DictionaryHTMLView(html: html, contentHeight: $contentHeight)
            .frame(height: min(contentHeight, maxHeight))
            .padding(.horizontal, 14)
            .onChange(of: contentHeight) { _ in
                onHeightChange?()
            }
    }
}
