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
                Logger.log("🔄 Scene phase changed: \(oldPhase) → \(newPhase)")
                if newPhase == .active {
                    Logger.log("📱 App became active, checking for updates...")
                    cacheManager.checkForUpdates()
                }
            }
            .onAppear {
                Logger.log("🚀 ContentView appeared")
            }
    }
}

// MARK: - Logger

struct Logger {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    static func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        print("[\(timestamp)] [\(fileName):\(line)] \(function) → \(message)")
    }
    
    static func logError(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        var fullMessage = "❌ [\(timestamp)] [\(fileName):\(line)] \(function) → \(message)"
        if let error = error {
            fullMessage += "\n   Error: \(error.localizedDescription)"
            fullMessage += "\n   Details: \(error)"
        }
        print(fullMessage)
    }
    
    static func logSuccess(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log("✅ \(message)", file: file, function: function, line: line)
    }
    
    static func logNetwork(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log("🌐 \(message)", file: file, function: function, line: line)
    }
    
    static func logCache(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log("💾 \(message)", file: file, function: function, line: line)
    }
    
    static func logFile(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log("📁 \(message)", file: file, function: function, line: line)
    }
}

// MARK: - Cache Manager

class WebCacheManager: ObservableObject {
    @Published var contentURL: URL?
    @Published var isLoading = true
    @Published var contentVersion = 0  // Increment to force reload
    
    private let remoteBaseURLs = [
        "https://app.totalten.io",
        "https://app.10.zawie.io"
    ]
    private var activeBaseURL: String?
    private let fileManager = FileManager.default
    private var downloadStartTime: Date?
    private var totalFilesToDownload = 0
    private var filesDownloaded = 0
    
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
        Logger.log("🏗️ WebCacheManager initializing...")
        Logger.logCache("Cache directory: \(cacheDirectory.path)")
        Logger.logCache("Remote base URLs: \(remoteBaseURLs)")
        
        createCacheDirectoryIfNeeded()
        logCacheStatus()
        loadBestAvailableContent()
        
        Logger.logSuccess("WebCacheManager initialized")
    }
    
    private func logCacheStatus() {
        Logger.logCache("=== Cache Status ===")
        Logger.logCache("Cache directory exists: \(fileManager.fileExists(atPath: cacheDirectory.path))")
        Logger.logCache("Cached index.html exists: \(fileManager.fileExists(atPath: cachedIndexFile.path))")
        Logger.logCache("Cached version.json exists: \(fileManager.fileExists(atPath: cachedVersionFile.path))")
        
        if let cachedVersion = loadCachedVersion() {
            Logger.logCache("Cached version: \(cachedVersion.commitHash) (built: \(cachedVersion.buildTime))")
        } else {
            Logger.logCache("No cached version found")
        }
        
        // List all cached files
        if let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            var fileCount = 0
            var totalSize: Int64 = 0
            
            Logger.logCache("--- Cached Files ---")
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey]),
                   resourceValues.isDirectory != true {
                    let size = resourceValues.fileSize ?? 0
                    let modDate = resourceValues.contentModificationDate ?? Date()
                    let relativePath = fileURL.path.replacingOccurrences(of: cacheDirectory.path + "/", with: "")
                    Logger.logFile("  \(relativePath) (\(formatBytes(size)), modified: \(Logger.dateFormatter.string(from: modDate)))")
                    fileCount += 1
                    totalSize += Int64(size)
                }
            }
            Logger.logCache("Total: \(fileCount) files, \(formatBytes(Int(totalSize)))")
        }
        Logger.logCache("===================")
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(bytes) / 1024.0 / 1024.0)
        }
    }
    
    private func createCacheDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            Logger.logCache("Creating cache directory...")
            do {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                Logger.logSuccess("Cache directory created at: \(cacheDirectory.path)")
            } catch {
                Logger.logError("Failed to create cache directory", error: error)
            }
        } else {
            Logger.logCache("Cache directory already exists")
        }
    }
    
    // MARK: - Content Loading Priority
    // 1. Check remote for updates
    // 2. Use local cache if valid
    // 3. Fall back to bundled dist
    
    func loadBestAvailableContent() {
        Logger.log("🔍 Loading best available content...")
        
        // Debug: what's actually in the bundle?
        Logger.logFile("=== Bundle Contents ===")
        if let resourcePath = Bundle.main.resourcePath {
            Logger.logFile("Resource path: \(resourcePath)")
            if let contents = try? fileManager.contentsOfDirectory(atPath: resourcePath) {
                Logger.logFile("Top-level bundle items: \(contents)")
            } else {
                Logger.logError("Could not list bundle contents")
            }
        } else {
            Logger.logError("No resource path in bundle")
        }
        
        if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            Logger.logFile("Found dist folder at: \(bundleURL.path)")
            if let distContents = try? fileManager.contentsOfDirectory(atPath: bundleURL.path) {
                Logger.logFile("Dist contents: \(distContents)")
                
                // Check for index.html
                let indexPath = bundleURL.appendingPathComponent("index.html").path
                if fileManager.fileExists(atPath: indexPath) {
                    Logger.logSuccess("index.html found in dist")
                } else {
                    Logger.logError("index.html NOT found in dist")
                }
            }
        } else {
            Logger.logError("dist folder NOT FOUND in bundle")
        }
        Logger.logFile("=======================")
        
        // First, set to cached or bundled content immediately for fast startup
        if fileManager.fileExists(atPath: cachedIndexFile.path) {
            Logger.logCache("Using cached content: \(cachedIndexFile.path)")
            contentURL = cachedIndexFile
            
            // Log file details
            if let attributes = try? fileManager.attributesOfItem(atPath: cachedIndexFile.path) {
                let size = attributes[.size] as? Int ?? 0
                let modDate = attributes[.modificationDate] as? Date ?? Date()
                Logger.logFile("Cached index.html: \(formatBytes(size)), modified: \(modDate)")
            }
        } else if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            let bundleIndexURL = bundleURL.appendingPathComponent("index.html")
            Logger.logFile("Using bundled content: \(bundleIndexURL.path)")
            contentURL = bundleIndexURL
        } else {
            Logger.logError("NO CONTENT AVAILABLE - neither cached nor bundled!")
        }
        
        isLoading = false
        Logger.log("Content URL set to: \(contentURL?.path ?? "nil")")
    }
    
    func checkForUpdates() {
        Logger.logNetwork("=== Checking for Updates ===")
        Logger.logNetwork("Will try URLs in order: \(remoteBaseURLs)")
        
        // Try each URL in order
        tryCheckForUpdates(urlIndex: 0)
    }
    
    private func tryCheckForUpdates(urlIndex: Int) {
        guard urlIndex < remoteBaseURLs.count else {
            Logger.logError("All remote URLs failed, giving up on update check")
            return
        }
        
        let baseURL = remoteBaseURLs[urlIndex]
        Logger.logNetwork("Trying URL \(urlIndex + 1)/\(remoteBaseURLs.count): \(baseURL)")
        
        guard let versionURL = URL(string: "\(baseURL)/version.json") else {
            Logger.logError("Invalid version URL: \(baseURL)/version.json")
            tryCheckForUpdates(urlIndex: urlIndex + 1)
            return
        }
        
        Logger.logNetwork("Fetching: \(versionURL.absoluteString)")
        let startTime = Date()
        
        var request = URLRequest(url: versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let duration = Date().timeIntervalSince(startTime)
            
            guard let self = self else {
                Logger.logError("Self deallocated during version check")
                return
            }
            
            // Log response details
            if let httpResponse = response as? HTTPURLResponse {
                Logger.logNetwork("Response status: \(httpResponse.statusCode) (took \(String(format: "%.2f", duration))s)")
                
                // If we got a non-success status, try the next URL
                if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
                    Logger.logNetwork("Non-success status from \(baseURL), trying next URL...")
                    self.tryCheckForUpdates(urlIndex: urlIndex + 1)
                    return
                }
            }
            
            if let error = error {
                Logger.logError("Failed to fetch version.json from \(baseURL)", error: error)
                Logger.logNetwork("Trying next URL...")
                self.tryCheckForUpdates(urlIndex: urlIndex + 1)
                return
            }
            
            guard let data = data else {
                Logger.logError("No data received from version.json at \(baseURL)")
                self.tryCheckForUpdates(urlIndex: urlIndex + 1)
                return
            }
            
            Logger.logNetwork("Received \(self.formatBytes(data.count)) of version data")
            
            // Log raw JSON for debugging
            if let jsonString = String(data: data, encoding: .utf8) {
                Logger.logNetwork("Raw version.json: \(jsonString)")
            }
            
            do {
                let remoteVersion = try JSONDecoder().decode(VersionInfo.self, from: data)
                Logger.logNetwork("Parsed remote version:")
                Logger.logNetwork("  Commit: \(remoteVersion.commitHash) (\(remoteVersion.commitHashFull))")
                Logger.logNetwork("  Branch: \(remoteVersion.branch)")
                Logger.logNetwork("  Build time: \(remoteVersion.buildTime)")
                Logger.logNetwork("  Build type: \(remoteVersion.buildType)")
                Logger.logNetwork("  Message: \(remoteVersion.commitMessage)")
                
                // Success! Set the active base URL and proceed
                self.activeBaseURL = baseURL
                Logger.logSuccess("Using \(baseURL) for downloads")
                
                self.handleVersionCheck(remoteVersion: remoteVersion, remoteData: data)
            } catch {
                Logger.logError("Failed to decode version.json from \(baseURL)", error: error)
                self.tryCheckForUpdates(urlIndex: urlIndex + 1)
            }
        }
        task.resume()
    }
    
    private func handleVersionCheck(remoteVersion: VersionInfo, remoteData: Data) {
        let cachedVersion = loadCachedVersion()
        
        Logger.logCache("=== Version Comparison ===")
        if let cached = cachedVersion {
            Logger.logCache("Cached: \(cached.commitHash) (built: \(cached.buildTime))")
            Logger.logCache("Remote: \(remoteVersion.commitHash) (built: \(remoteVersion.buildTime))")
        } else {
            Logger.logCache("Cached: NONE")
            Logger.logCache("Remote: \(remoteVersion.commitHash) (built: \(remoteVersion.buildTime))")
        }
        
        if remoteVersion.isDifferentFrom(cachedVersion) {
            Logger.logSuccess("New version available! Starting download...")
            downloadAndCacheContent(version: remoteVersion, versionData: remoteData)
        } else {
            Logger.logCache("Cache is up to date - no download needed")
        }
        Logger.logCache("=========================")
    }
    
    private func loadCachedVersion() -> VersionInfo? {
        Logger.logCache("Loading cached version from: \(cachedVersionFile.path)")
        
        guard fileManager.fileExists(atPath: cachedVersionFile.path) else {
            Logger.logCache("No cached version file exists")
            return nil
        }
        
        guard let data = try? Data(contentsOf: cachedVersionFile) else {
            Logger.logError("Failed to read cached version file")
            return nil
        }
        
        Logger.logCache("Read \(formatBytes(data.count)) from cached version file")
        
        do {
            let version = try JSONDecoder().decode(VersionInfo.self, from: data)
            Logger.logCache("Cached version decoded: \(version.commitHash)")
            return version
        } catch {
            Logger.logError("Failed to decode cached version", error: error)
            return nil
        }
    }
    
    private func downloadAndCacheContent(version: VersionInfo, versionData: Data) {
        Logger.logNetwork("=== Starting Content Download ===")
        downloadStartTime = Date()
        
        guard let baseURL = activeBaseURL else {
            Logger.logError("No active base URL set for download")
            return
        }
        
        guard let manifestURL = URL(string: "\(baseURL)/asset-manifest.json") else {
            Logger.logError("Invalid manifest URL")
            return
        }
        
        Logger.logNetwork("Fetching asset manifest: \(manifestURL.absoluteString)")
        
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let httpResponse = response as? HTTPURLResponse {
                Logger.logNetwork("Manifest response status: \(httpResponse.statusCode)")
            }
            
            if let error = error {
                Logger.logError("Failed to fetch asset-manifest.json", error: error)
                return
            }
            
            guard let data = data else {
                Logger.logError("No data received from asset-manifest.json")
                return
            }
            
            Logger.logNetwork("Received \(self.formatBytes(data.count)) of manifest data")
            
            // Log raw manifest
            if let jsonString = String(data: data, encoding: .utf8) {
                Logger.logNetwork("Raw asset-manifest.json:\n\(jsonString)")
            }
            
            do {
                let manifest = try JSONDecoder().decode(AssetManifest.self, from: data)
                Logger.logNetwork("Manifest parsed successfully:")
                Logger.logNetwork("  Files: \(manifest.files.count)")
                Logger.logNetwork("  Entrypoints: \(manifest.entrypoints)")
                
                for (key, value) in manifest.files {
                    Logger.logFile("  \(key) → \(value)")
                }
                
                self.downloadFiles(from: manifest, version: version, versionData: versionData, manifestData: data)
            } catch {
                Logger.logError("Failed to decode asset-manifest.json", error: error)
            }
        }
        task.resume()
    }
    
    private func downloadFiles(from manifest: AssetManifest, version: VersionInfo, versionData: Data, manifestData: Data) {
        // Get all file paths from manifest, stripping "./" prefix
        let filesToDownload = manifest.files.values.map { path -> String in
            if path.hasPrefix("./") {
                return String(path.dropFirst(2))
            }
            return path
        }
        
        totalFilesToDownload = filesToDownload.count
        filesDownloaded = 0
        
        Logger.logNetwork("=== Downloading \(totalFilesToDownload) Files ===")
        
        let group = DispatchGroup()
        var downloadSuccess = true
        var failedFiles: [String] = []
        var downloadedBytes: Int64 = 0
        let bytesLock = NSLock()
        
        for file in filesToDownload {
            group.enter()
            downloadFile(file) { [weak self] success, bytes in
                if success {
                    bytesLock.lock()
                    downloadedBytes += Int64(bytes)
                    self?.filesDownloaded += 1
                    bytesLock.unlock()
                    Logger.logSuccess("[\(self?.filesDownloaded ?? 0)/\(self?.totalFilesToDownload ?? 0)] Downloaded: \(file) (\(self?.formatBytes(bytes) ?? "?"))")
                } else {
                    downloadSuccess = false
                    failedFiles.append(file)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            let duration = Date().timeIntervalSince(self.downloadStartTime ?? Date())
            
            Logger.logNetwork("=== Download Complete ===")
            Logger.logNetwork("Duration: \(String(format: "%.2f", duration))s")
            Logger.logNetwork("Total downloaded: \(self.formatBytes(Int(downloadedBytes)))")
            Logger.logNetwork("Success: \(downloadSuccess)")
            
            if !failedFiles.isEmpty {
                Logger.logError("Failed files: \(failedFiles)")
            }
            
            if downloadSuccess {
                // Save version.json and asset-manifest.json
                do {
                    try versionData.write(to: self.cachedVersionFile)
                    Logger.logCache("Saved version.json")
                    
                    try manifestData.write(to: self.cacheDirectory.appendingPathComponent("asset-manifest.json"))
                    Logger.logCache("Saved asset-manifest.json")
                } catch {
                    Logger.logError("Failed to save metadata files", error: error)
                }
                
                // Update content URL to use cache
                if self.fileManager.fileExists(atPath: self.cachedIndexFile.path) {
                    self.contentURL = self.cachedIndexFile
                    self.contentVersion += 1
                    Logger.logSuccess("Cache updated! Version: \(version.commitHash), built: \(version.buildTime)")
                    Logger.log("Content version incremented to: \(self.contentVersion)")
                } else {
                    Logger.logError("index.html not found after download!")
                }
                
                let validFiles = Set(manifest.files.values.map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 })
                self.cleanupOrphanedFiles(keeping: validFiles)
                
                // Log final cache status
                self.logCacheStatus()
            } else {
                Logger.logError("Download incomplete, keeping existing content")
            }
            Logger.logNetwork("=========================")
        }
    }
    
    private func downloadFile(_ relativePath: String, completion: @escaping (Bool, Int) -> Void) {
        guard let baseURL = activeBaseURL else {
            Logger.logError("No active base URL for downloading: \(relativePath)")
            completion(false, 0)
            return
        }
        
        guard let url = URL(string: "\(baseURL)/\(relativePath)") else {
            Logger.logError("Invalid URL for: \(relativePath)")
            completion(false, 0)
            return
        }
        
        let destinationURL = cacheDirectory.appendingPathComponent(relativePath)
        
        // Create subdirectories if needed
        let destinationDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDir.path) {
            do {
                try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
                Logger.logFile("Created directory: \(destinationDir.path)")
            } catch {
                Logger.logError("Failed to create directory for: \(relativePath)", error: error)
            }
        }
        
        Logger.logNetwork("⬇️ Downloading: \(relativePath)")
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        
        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else {
                completion(false, 0)
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode != 200 {
                    Logger.logError("HTTP \(httpResponse.statusCode) for: \(relativePath)")
                    completion(false, 0)
                    return
                }
            }
            
            if let error = error {
                Logger.logError("Download failed for: \(relativePath)", error: error)
                completion(false, 0)
                return
            }
            
            guard let tempURL = tempURL else {
                Logger.logError("No temp URL for: \(relativePath)")
                completion(false, 0)
                return
            }
            
            do {
                // Get file size before moving
                let attributes = try self.fileManager.attributesOfItem(atPath: tempURL.path)
                let fileSize = attributes[.size] as? Int ?? 0
                
                // Remove existing file if present
                if self.fileManager.fileExists(atPath: destinationURL.path) {
                    try self.fileManager.removeItem(at: destinationURL)
                    Logger.logFile("Removed existing: \(relativePath)")
                }
                
                try self.fileManager.moveItem(at: tempURL, to: destinationURL)
                completion(true, fileSize)
            } catch {
                Logger.logError("Failed to save: \(relativePath)", error: error)
                completion(false, 0)
            }
        }
        task.resume()
    }
    
    private func cleanupOrphanedFiles(keeping validPaths: Set<String>) {
        Logger.logCache("=== Cleaning Orphaned Files ===")
        Logger.logCache("Valid paths count: \(validPaths.count)")
        
        guard let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else {
            Logger.logError("Failed to create enumerator for cache directory")
            return
        }
        
        var removedCount = 0
        var removedBytes: Int64 = 0
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
                  resourceValues.isDirectory != true else { continue }
            
            let relativePath = fileURL.path.replacingOccurrences(of: cacheDirectory.path + "/", with: "")
            
            if !validPaths.contains(relativePath) &&
               relativePath != "version.json" &&
               relativePath != "asset-manifest.json" {
                let fileSize = resourceValues.fileSize ?? 0
                do {
                    try fileManager.removeItem(at: fileURL)
                    removedCount += 1
                    removedBytes += Int64(fileSize)
                    Logger.logFile("🗑️ Removed orphan: \(relativePath) (\(formatBytes(fileSize)))")
                } catch {
                    Logger.logError("Failed to remove orphan: \(relativePath)", error: error)
                }
            }
        }
        
        Logger.logCache("Cleanup complete: removed \(removedCount) files (\(formatBytes(Int(removedBytes))))")
        Logger.logCache("==============================")
    }
    
    func clearCache() {
        Logger.logCache("=== Clearing Cache ===")
        
        // Log what we're about to delete
        logCacheStatus()
        
        do {
            try fileManager.removeItem(at: cacheDirectory)
            Logger.logSuccess("Cache directory removed")
        } catch {
            Logger.logError("Failed to remove cache directory", error: error)
        }
        
        createCacheDirectoryIfNeeded()
        loadBestAvailableContent()
        
        Logger.logCache("Cache cleared, using: \(contentURL?.path ?? "nil")")
        Logger.logCache("=====================")
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
        guard let other = other else {
            Logger.log("Version comparison: other is nil, returning true (needs update)")
            return true
        }
        
        let buildTimeDifferent = self.buildTime != other.buildTime
        let commitHashDifferent = self.commitHash != other.commitHash
        let result = buildTimeDifferent || commitHashDifferent
        
        Logger.log("Version comparison:")
        Logger.log("  Build time: \(self.buildTime) vs \(other.buildTime) → \(buildTimeDifferent ? "DIFFERENT" : "same")")
        Logger.log("  Commit hash: \(self.commitHash) vs \(other.commitHash) → \(commitHashDifferent ? "DIFFERENT" : "same")")
        Logger.log("  Result: \(result ? "NEEDS UPDATE" : "up to date")")
        
        return result
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
        Logger.log("🌐 Creating WKWebView...")
        
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // Add user script to catch errors early
        let errorCatchScript = WKUserScript(
            source: """
            window.__CAUGHT_ERRORS__ = [];
            window.__CONSOLE_LOGS__ = [];
            
            // Catch all errors
            window.onerror = function(msg, url, line, col, error) {
                window.__CAUGHT_ERRORS__.push({
                    type: 'error',
                    msg: String(msg),
                    url: String(url),
                    line: line,
                    col: col,
                    stack: error ? String(error.stack) : ''
                });
                return false;
            };
            
            // Catch unhandled promise rejections
            window.onunhandledrejection = function(event) {
                window.__CAUGHT_ERRORS__.push({
                    type: 'unhandledrejection',
                    msg: String(event.reason),
                    stack: event.reason && event.reason.stack ? String(event.reason.stack) : ''
                });
            };
            
            // Intercept console methods
            ['log', 'warn', 'error', 'info'].forEach(function(method) {
                var original = console[method];
                console[method] = function() {
                    window.__CONSOLE_LOGS__.push({
                        method: method,
                        args: Array.from(arguments).map(function(a) {
                            try { return String(a); } catch(e) { return '[unserializable]'; }
                        }),
                        time: new Date().toISOString()
                    });
                    original.apply(console, arguments);
                };
            });
            
            console.log('🔧 Error catching initialized');
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(errorCatchScript)
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        
        // Enable Safari Web Inspector (for debugging via Mac)
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
            Logger.log("Safari Web Inspector enabled")
        }
        
        context.coordinator.lastLoadedVersion = cacheManager.contentVersion
        Logger.log("Initial content version: \(cacheManager.contentVersion)")
        
        loadContent(in: webView)
        
        return webView
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        Logger.log("updateUIView called - current version: \(cacheManager.contentVersion), last loaded: \(context.coordinator.lastLoadedVersion)")
        
        // Reload if content version changed (new download completed)
        if context.coordinator.lastLoadedVersion != cacheManager.contentVersion {
            Logger.log("🔄 Content version changed, reloading WebView...")
            context.coordinator.lastLoadedVersion = cacheManager.contentVersion
            loadContent(in: uiView)
        }
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var lastLoadedVersion = 0
        var loadStartTime: Date?
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            loadStartTime = Date()
            Logger.logNetwork("WebView started loading: \(webView.url?.absoluteString ?? "nil")")
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let duration = loadStartTime.map { Date().timeIntervalSince($0) } ?? 0
            Logger.logSuccess("WebView finished loading in \(String(format: "%.2f", duration))s")
            Logger.log("Final URL: \(webView.url?.absoluteString ?? "nil")")
            
            // Wait a moment for React to mount, then debug
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.debugJavaScript(in: webView)
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Logger.logError("WebView navigation failed", error: error)
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Logger.logError("WebView provisional navigation failed", error: error)
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            Logger.log("Navigation request: \(navigationAction.request.url?.absoluteString ?? "nil")")
            Logger.log("Navigation type: \(navigationAction.navigationType.rawValue)")
            decisionHandler(.allow)
        }
        
        // WKUIDelegate - catch JavaScript alerts
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            Logger.log("⚠️ JS Alert: \(message)")
            completionHandler()
        }
        
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            Logger.log("⚠️ JS Confirm: \(message)")
            completionHandler(true)
        }
        
        private func debugJavaScript(in webView: WKWebView) {
            Logger.log("=== JavaScript Debug ===")
            
            // First, get console logs
            let consoleLogs = "JSON.stringify(window.__CONSOLE_LOGS__ || [])"
            webView.evaluateJavaScript(consoleLogs) { result, error in
                if let json = result as? String, json != "[]" {
                    Logger.log("📋 Console Logs:\n\(json)")
                }
            }
            
            // Get caught errors
            let caughtErrors = "JSON.stringify(window.__CAUGHT_ERRORS__ || [])"
            webView.evaluateJavaScript(caughtErrors) { result, error in
                if let json = result as? String, json != "[]" {
                    Logger.logError("🚨 Caught JS Errors:\n\(json)")
                } else {
                    Logger.log("No JS errors caught")
                }
            }
            
            // Check DOM state
            let domDebug = """
            (function() {
                var root = document.getElementById('root');
                var result = {
                    title: document.title,
                    readyState: document.readyState,
                    bodyChildren: document.body ? document.body.children.length : 0,
                    bodyHTML: document.body ? document.body.innerHTML.substring(0, 1000) : 'NO BODY',
                    rootExists: !!root,
                    rootChildren: root ? root.children.length : 0,
                    rootHTML: root ? root.innerHTML.substring(0, 500) : 'NO ROOT',
                    scriptsCount: document.scripts.length,
                    stylesheetsCount: document.styleSheets.length
                };
                return JSON.stringify(result, null, 2);
            })()
            """
            
            webView.evaluateJavaScript(domDebug) { result, error in
                if let error = error {
                    Logger.logError("DOM debug failed", error: error)
                } else if let json = result as? String {
                    Logger.log("📄 DOM State:\n\(json)")
                }
            }
            
            // Check for React
            let reactDebug = """
            (function() {
                var root = document.getElementById('root');
                var hasReactFiber = false;
                if (root) {
                    for (var key in root) {
                        if (key.startsWith('__reactContainer') || key.startsWith('__reactFiber')) {
                            hasReactFiber = true;
                            break;
                        }
                    }
                }
                return {
                    hasReactRoot: hasReactFiber,
                    reactInWindow: typeof React !== 'undefined',
                    reactDOMInWindow: typeof ReactDOM !== 'undefined'
                };
            })()
            """
            
            webView.evaluateJavaScript(reactDebug) { result, error in
                if let error = error {
                    Logger.logError("React debug failed", error: error)
                } else if let dict = result as? [String: Any] {
                    Logger.log("⚛️ React State: \(dict)")
                }
            }
            
            // List all script tags and check if they loaded
            let scriptStatus = """
            (function() {
                return Array.from(document.scripts).map(function(s, i) {
                    return {
                        index: i,
                        src: s.src || '(inline: ' + s.innerHTML.substring(0, 50) + '...)',
                        type: s.type || 'text/javascript',
                        async: s.async,
                        defer: s.defer
                    };
                });
            })()
            """
            
            webView.evaluateJavaScript(scriptStatus) { result, error in
                if let scripts = result as? [[String: Any]] {
                    Logger.log("📜 Script Tags (\(scripts.count) total):")
                    for script in scripts {
                        Logger.log("  \(script)")
                    }
                }
            }
            
            // Check if main chunk loaded by looking for app-specific globals
            let appGlobals = """
            (function() {
                return {
                    windowKeys: Object.keys(window).filter(k => !k.startsWith('webkit')).slice(0, 30),
                    hasWebpackJsonp: typeof webpackJsonp !== 'undefined' || typeof webpackChunk !== 'undefined',
                    documentMode: document.compatMode
                };
            })()
            """
            
            webView.evaluateJavaScript(appGlobals) { result, error in
                if let dict = result as? [String: Any] {
                    Logger.log("🌍 Global State: \(dict)")
                }
            }
            
            Logger.log("========================")
        }
    }
    
    private func loadContent(in webView: WKWebView) {
        Logger.log("=== Loading Content into WebView ===")
        
        let contentURL: URL
        let accessURL: URL
        
        if let cachedURL = cacheManager.contentURL {
            contentURL = cachedURL
            accessURL = cachedURL.deletingLastPathComponent()
            Logger.log("Source: Cache")
        } else if let bundleURL = Bundle.main.url(forResource: "dist", withExtension: nil) {
            contentURL = bundleURL.appendingPathComponent("index.html")
            accessURL = bundleURL
            Logger.log("Source: Bundle")
        } else {
            Logger.logError("No content available to load!")
            return
        }
        
        // Verify file exists
        let fileExists = FileManager.default.fileExists(atPath: contentURL.path)
        Logger.log("Content file exists: \(fileExists)")
        
        if fileExists {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: contentURL.path) {
                let size = attributes[.size] as? Int ?? 0
                Logger.log("Content file size: \(size) bytes")
            }
        }
        
        Logger.log("Content URL: \(contentURL.path)")
        Logger.log("Access URL: \(accessURL.path)")
        
        webView.loadFileURL(contentURL, allowingReadAccessTo: accessURL)
        Logger.logSuccess("loadFileURL called")
        Logger.log("====================================")
    }
}

#Preview {
    ContentView()
}
