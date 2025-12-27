import SwiftUI
import WebKit

struct ContentView: View {
    var body: some View {
        BundledWebView()
            .edgesIgnoringSafeArea(.all)
    }
}

struct BundledWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            let indexURL = bundleURL.appendingPathComponent("index.html")
            let videosURL = bundleURL.appendingPathComponent("videos")
            webView.loadFileURL(indexURL, allowingReadAccessTo: videosURL.deletingLastPathComponent())
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
