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
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            let indexURL = bundleURL.appendingPathComponent("index.html")
            webView.loadFileURL(indexURL, allowingReadAccessTo: bundleURL)
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
