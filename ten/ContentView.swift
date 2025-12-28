import SwiftUI
import WebKit
import Combine

struct ContentView: View {
    @StateObject private var cacheManager = WebCacheManager()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        CachedWebView(cacheManager: cacheManager)
            .edgesIgnoringSafeArea(.all)
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    cacheManager.checkForUpdates()
                }
            }
    }
}

// MARK: - Cache Manager

class WebCacheManager: ObservableObject {
    @Published var contentURL: URL?
    @Published var isLoading = true
    @Published var contentVersion = 0  // Increment to force reload
    
    private let remoteBaseURL = "https://app.10.zawie.io"
    private let fileManager = FileManager.default
    
    private var cacheDirectory: URL {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("WebCache")
    }
    
    private var cachedVersionFile: URL {
        cacheDirectory.appendingPathComponent("version.json")
    }
    
    private var cachedIndexFile: URL {
        cacheDirectory.appendingPathComponent("index.html")
    }
    
    init() {
        createCacheDirectoryIfNeeded()
        loadBestAvailableContent()
    }
    
    private func createCacheDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Content Loading Priority
    // 1. Check remote for updates
    // 2. Use local cache if valid
    // 3. Fall back to bundled dist
    
    func loadBestAvailableContent() {
        // Debug: what's actually in the bundle?
       if let resourcePath = Bundle.main.resourcePath {
           let contents = try? fileManager.contentsOfDirectory(atPath: resourcePath)
           print("Bundle contents: \(contents ?? [])")
       }
       
       if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
           print("Found dist at: \(bundleURL.path)")
           let distContents = try? fileManager.contentsOfDirectory(atPath: bundleURL.path)
           print("Dist contents: \(distContents ?? [])")
       } else {
           print("dist folder NOT FOUND in bundle")
       }
    
        // First, set to cached or bundled content immediately for fast startup
        if fileManager.fileExists(atPath: cachedIndexFile.path) {
            contentURL = cachedIndexFile
        } else if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            contentURL = bundleURL.appendingPathComponent("index.html")
        }
        isLoading = false
    }
    
    func checkForUpdates() {
        guard let versionURL = URL(string: "\(remoteBaseURL)/version.json") else { return }
        
        let task = URLSession.shared.dataTask(with: versionURL) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else {
                print("Failed to fetch version.json: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            do {
                let remoteVersion = try JSONDecoder().decode(VersionInfo.self, from: data)
                self.handleVersionCheck(remoteVersion: remoteVersion, remoteData: data)
            } catch {
                print("Failed to decode version.json: \(error)")
            }
        }
        task.resume()
    }
    
    private func handleVersionCheck(remoteVersion: VersionInfo, remoteData: Data) {
        let cachedVersion = loadCachedVersion()
        
        if remoteVersion.isDifferentFrom(cachedVersion) {
            print("New version available: \(remoteVersion.commitHash) (\(remoteVersion.buildTime)). Downloading...")
            downloadAndCacheContent(version: remoteVersion, versionData: remoteData)
        } else {
            print("Cache is up to date (commit: \(remoteVersion.commitHash))")
        }
    }
    
    private func loadCachedVersion() -> VersionInfo? {
        guard fileManager.fileExists(atPath: cachedVersionFile.path),
              let data = try? Data(contentsOf: cachedVersionFile) else {
            return nil
        }
        return try? JSONDecoder().decode(VersionInfo.self, from: data)
    }
    
    private func downloadAndCacheContent(version: VersionInfo, versionData: Data) {
        // First fetch asset-manifest.json to get file list
        guard let manifestURL = URL(string: "\(remoteBaseURL)/asset-manifest.json") else { return }
        
        let task = URLSession.shared.dataTask(with: manifestURL) { [weak self] data, response, error in
            guard let self = self,
                  let data = data,
                  error == nil else {
                print("Failed to fetch asset-manifest.json: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            do {
                let manifest = try JSONDecoder().decode(AssetManifest.self, from: data)
                self.downloadFiles(from: manifest, version: version, versionData: versionData, manifestData: data)
            } catch {
                print("Failed to decode asset-manifest.json: \(error)")
            }
        }
        task.resume()
    }
    
    private func downloadFiles(from manifest: AssetManifest, version: VersionInfo, versionData: Data, manifestData: Data) {
        // Get all file paths from manifest, stripping "./" prefix
        var filesToDownload = manifest.files.values.map { path -> String in
            if path.hasPrefix("./") {
                return String(path.dropFirst(2))
            }
            return path
        }
        
        // Also download version.json and asset-manifest.json
        let group = DispatchGroup()
        var downloadSuccess = true
        
        for file in filesToDownload {
            group.enter()
            downloadFile(file) { success in
                if !success {
                    downloadSuccess = false
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            if downloadSuccess {
                // Save version.json and asset-manifest.json to mark successful cache
                try? versionData.write(to: self.cachedVersionFile)
                try? manifestData.write(to: self.cacheDirectory.appendingPathComponent("asset-manifest.json"))
                
                // Update content URL to use cache
                if self.fileManager.fileExists(atPath: self.cachedIndexFile.path) {
                    self.contentURL = self.cachedIndexFile
                    self.contentVersion += 1  // Force WebView reload
                    print("Cache updated successfully (commit: \(version.commitHash), built: \(version.buildTime))")
                }
                let validFiles = Set(manifest.files.values.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 })
                self.cleanupOrphanedFiles(keeping: validFiles)
            } else {
                print("Some files failed to download, keeping existing content")
            }
        }
    }
    
    private func downloadFile(_ relativePath: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(remoteBaseURL)/\(relativePath)") else {
            completion(false)
            return
        }
        
        let destinationURL = cacheDirectory.appendingPathComponent(relativePath)
        
        // Create subdirectories if needed
        let destinationDir = destinationURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self,
                  let tempURL = tempURL,
                  error == nil else {
                print("Failed to download \(relativePath): \(error?.localizedDescription ?? "Unknown error")")
                completion(false)
                return
            }
            
            do {
                // Remove existing file if present
                if self.fileManager.fileExists(atPath: destinationURL.path) {
                    try self.fileManager.removeItem(at: destinationURL)
                }
                try self.fileManager.moveItem(at: tempURL, to: destinationURL)
                print("Downloaded: \(relativePath)")
                completion(true)
            } catch {
                print("Failed to save \(relativePath): \(error)")
                completion(false)
            }
        }
        task.resume()
    }
    
    private func cleanupOrphanedFiles(keeping validPaths: Set<String>) {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else { return }
        
        for case let fileURL as URL in enumerator {
            // Skip directories
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  resourceValues.isDirectory != true else { continue }
            
            let relativePath = fileURL.path.replacingOccurrences(of: cacheDirectory.path + "/", with: "")
            if !validPaths.contains(relativePath) &&
               relativePath != "version.json" &&
               relativePath != "asset-manifest.json" {
                try? fileManager.removeItem(at: fileURL)
                print("Cleaned up orphaned file: \(relativePath)")
            }
        }
    }
    
    func clearCache() {
        try? fileManager.removeItem(at: cacheDirectory)
        createCacheDirectoryIfNeeded()
        loadBestAvailableContent()
    }
}

// MARK: - Version Model

struct VersionInfo: Codable {
    let commitHash: String
    let commitHashFull: String
    let branch: String
    let buildTime: String
    let buildType: String
    let commitMessage: String
    let commitDate: String
    
    // Compare by buildTime first, fall back to commitHash
    func isDifferentFrom(_ other: VersionInfo?) -> Bool {
        guard let other = other else { return true }
        return self.buildTime != other.buildTime || self.commitHash != other.commitHash
    }
}

struct AssetManifest: Codable {
    let files: [String: String]
    let entrypoints: [String]
}

// MARK: - Cached Web View

struct CachedWebView: UIViewRepresentable {
    @ObservedObject var cacheManager: WebCacheManager
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        context.coordinator.lastLoadedVersion = cacheManager.contentVersion
        loadContent(in: webView)
        
        return webView
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Reload if content version changed (new download completed)
        if context.coordinator.lastLoadedVersion != cacheManager.contentVersion {
            context.coordinator.lastLoadedVersion = cacheManager.contentVersion
            loadContent(in: uiView)
        }
    }
    
    class Coordinator {
        var lastLoadedVersion = 0
    }
    
    private func loadContent(in webView: WKWebView) {
        let contentURL: URL
        let accessURL: URL
        
        if let cachedURL = cacheManager.contentURL {
            contentURL = cachedURL
            // Allow access to entire cache directory (for videos, sounds, etc.)
            accessURL = cachedURL.deletingLastPathComponent()
        } else if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            contentURL = bundleURL.appendingPathComponent("index.html")
            // Allow access to entire dist folder
            accessURL = bundleURL
        } else {
            print("No content available to load")
            return
        }
        
        webView.loadFileURL(contentURL, allowingReadAccessTo: accessURL)
        print("Loading content from: \(contentURL.path), with access to: \(accessURL.path)")
    }
}

#Preview {
    ContentView()
}
