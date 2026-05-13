import Foundation
import SwiftUI
import Combine
import UserNotifications
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// Make Equatable for UI comparisons
enum DownloadStatus: Equatable {
    case downloading(progress: Double, written: Int64, total: Int64)
    case paused
    case waitingForConnection
    case none
    
    /// True when a download is in flight in any form (downloading, paused, or
    /// waiting for connectivity). Useful for switching UI between progress
    /// affordances and the idle action cluster.
    var isActive: Bool {
        switch self {
        case .downloading, .paused, .waitingForConnection: return true
        case .none: return false
        }
    }
}

/// What the user wants to happen with a download once it finishes.
/// Extend with new cases (e.g. `.reveal`) without changing call sites that
/// only consult `shouldAutoInstall`.
enum DownloadIntent: Equatable {
    /// Use the global default ("Auto .ipa to .app" setting).
    case useDefault
    /// Force installation into LiveContainer regardless of the global default.
    case installToLiveContainer
    /// Keep the .ipa in the Downloads folder; do not auto-install.
    case downloadOnly
}

enum InstallAction {
    case installSeparate
    case updateExisting
    case cancel
}

struct PendingInstallation: Identifiable {
    let id = UUID()
    let appName: String
    let bundleID: String
    let tempPayloadURL: URL 
    let extractedAppURL: URL 
    let sourceArchiveURL: URL 
    let existingApp: LocalApp? 
}

struct AppBackup: Codable, Identifiable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let version: String?
    let backupPath: String 
    let originalInstallPath: String 
    let date: Date
    let hadLCAppInfo: Bool 
}

@MainActor
class DownloadManager: NSObject, ObservableObject {
    @Published var activeDownloads: [URL: Double] = [:]
    @Published var pausedDownloads: Set<URL> = []
    
    // Files in the Download Folder
    @Published var fileList: [URL] = []
    
    // Installed Apps in the Apps Folder
    @Published var installedApps: [LocalApp] = []
    
    // Files currently being extracted
    @Published var extractingFiles: Set<URL> = []
    
    @Published var customDownloadFolder: URL? = nil
    @Published var customLiveContainerFolder: URL? = nil 
    
    // Pending Installation (Collision)
    @Published var pendingInstallation: PendingInstallation? = nil
    
    // Backups for Updates
    @Published var pendingBackups: [AppBackup] = []
    
    // Changed to Published for reactive UI updates
    @Published var isAutoUnzipEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoUnzipEnabled, forKey: "kAutoUnzipEnabled")
        }
    }
    
    @Published var downloadStates: [URL: DownloadStatus] = [:]
    
    /// Per-download user intent. Absence means `.useDefault`. Read in
    /// `urlSession(_:downloadTask:didFinishDownloadingTo:)` to decide whether
    /// to auto-install regardless of the global "Auto .ipa to .app" setting.
    private var downloadIntents: [URL: DownloadIntent] = [:]
    
    /// Per-download filename override. When set, the finish handler writes
    /// the file with this name instead of the one derived from the URL.
    /// Used by the "Download IPA Only → Rename" collision flow.
    private var downloadFilenames: [URL: String] = [:]
    
    private var urlSession: URLSession!
    private var tasks: [URL: URLSessionDownloadTask] = [:]
    private var resumeDataMap: [URL: Data] = [:]
    var backgroundCompletionHandler: (() -> Void)?
    
    private let kCustomDownloadFolderKey = "kCustomDownloadFolderBookmark"
    private let kCustomLiveContainerFolderKey = "kCustomLiveContainerFolderBookmark"
    private let kBackgroundSessionID = "com.lbox.downloadSession"
    private let kResumeDataMapKey = "kResumeDataMapKey"
    
    private let kPendingBackupsKey = "kPendingBackupsKey"
    
    // URL String -> Filename in Caches
    private var diskResumeDataPaths: [String: String] = [:]
    
    override init() {
        self.isAutoUnzipEnabled = UserDefaults.standard.bool(forKey: "kAutoUnzipEnabled")
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: kBackgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 86400 
        config.timeoutIntervalForRequest = 600 
        
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        restoreFolders()
        restoreResumeDataMapping()
        loadPendingBackups()
        reconnectExistingTasks()
        refreshFileList()
        refreshInstalledApps()
    }
    
    func getStatus(for url: URL) -> DownloadStatus {
        return downloadStates[url] ?? .none
    }
    
    func getInstalledVersion(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.version
    }
    
    func getInstalledAppName(bundleID: String) -> String? {
        return installedApps.first(where: { $0.bundleID == bundleID })?.url.lastPathComponent
    }
    
    // MARK: - Notifications
    func sendNotification(title: String, body: String, type: InAppNotification.NotificationType = .success) {
        NotificationManager.shared.show(title: title, message: body, type: type)
    }
    
    // MARK: - Directories
    
    var currentDownloadFolder: URL {
        if let custom = customDownloadFolder { return custom }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    var currentAppsFolder: URL {
        if let root = customLiveContainerFolder {
            let appsSub = root.appendingPathComponent("Applications")
            if FileManager.default.fileExists(atPath: appsSub.path) { return appsSub }
            return root
        }
        return currentDownloadFolder
    }
    
    var currentDataApplicationFolder: URL? {
        if let root = customLiveContainerFolder {
            return root.appendingPathComponent("Data").appendingPathComponent("Application")
        }
        return nil
    }
    
    var backupDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    func getLocalFile(for url: URL) -> URL? {
        var name = url.lastPathComponent
        if url.pathExtension.isEmpty { name += ".ipa" }
        
        let dest = currentDownloadFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        
        let destOriginal = currentDownloadFolder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destOriginal.path) { return destOriginal }
        
        let zipName = dest.deletingPathExtension().appendingPathExtension("zip").lastPathComponent
        let zipDest = currentDownloadFolder.appendingPathComponent(zipName)
        if FileManager.default.fileExists(atPath: zipDest.path) { return zipDest }
        
        return nil
    }
    
    func isAppInstalled(bundleID: String) -> Bool {
        return installedApps.contains { $0.bundleID == bundleID }
    }
    
    /// Try to launch an installed app via the LiveContainer URL scheme.
    /// Returns `.launched` on success, `.needsSetup` if the app exists but
    /// hasn't been run in LiveContainer yet (no LCAppInfo.plist), or
    /// `.notInstalled` if no matching installed app is found.
    enum LaunchResult {
        case launched
        case needsSetup
        case notInstalled
    }
    
    @discardableResult
    func launchInstalledApp(bundleID: String) -> LaunchResult {
        guard let installed = installedApps.first(where: { $0.bundleID == bundleID }) else {
            return .notInstalled
        }
        guard hasLCAppInfo(bundleID: bundleID) else {
            return .needsSetup
        }
        let folderName = installed.url.lastPathComponent
        guard let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(folderName)") else {
            return .notInstalled
        }
        UIApplication.shared.open(url)
        return .launched
    }
    
    // MARK: - Backup Logic
    
    func loadPendingBackups() {
        if let data = UserDefaults.standard.data(forKey: kPendingBackupsKey),
           let list = try? JSONDecoder().decode([AppBackup].self, from: data) {
            self.pendingBackups = list
        }
    }
    
    func savePendingBackups() {
        if let data = try? JSONEncoder().encode(pendingBackups) {
            UserDefaults.standard.set(data, forKey: kPendingBackupsKey)
        }
    }
    
    func hasLCAppInfo(bundleID: String) -> Bool {
        guard let app = installedApps.first(where: { $0.bundleID == bundleID }) else { return false }
        let url = app.url.appendingPathComponent("LCAppInfo.plist")
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    func checkUpdateStatus(for backup: AppBackup) -> Bool {
        refreshInstalledApps()
        
        let bundleID = backup.bundleID
        guard isAppInstalled(bundleID: bundleID) else {
            Logger.shared.log("CheckUpdate: App \(bundleID) not installed.")
            return false
        }
        
        if hasLCAppInfo(bundleID: bundleID) {
            // Verify if the plist is actually new (created after backup)
            // This prevents using a plist that might have come with the IPA or wasn't removed correctly
            if let app = installedApps.first(where: { $0.bundleID == bundleID }) {
                let plistURL = app.url.appendingPathComponent("LCAppInfo.plist")
                
                // 1. Check Creation Date
                if let attrs = try? FileManager.default.attributesOfItem(atPath: plistURL.path),
                   let date = attrs[.creationDate] as? Date {
                    // If plist is older than backup, it's not the new one generated by LiveContainer
                    // We add a small buffer (e.g. 1 second) to avoid precision issues
                    if date < backup.date.addingTimeInterval(1) {
                        Logger.shared.log("CheckUpdate: LCAppInfo.plist is older than backup. Plist: \(date), Backup: \(backup.date)")
                        return false
                    } else {
                        Logger.shared.log("CheckUpdate: New LCAppInfo found. Plist: \(date), Backup: \(backup.date)")
                    }
                } else {
                    // If we can't read attributes, assume it's invalid/old to be safe
                    Logger.shared.log("CheckUpdate: Could not read attributes of LCAppInfo.plist")
                    return false
                }
                
                // 2. Check Content (Must have at least one container)
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    
                    if let containers = plist["LCContainers"] as? [[String: Any]] {
                        if containers.isEmpty {
                            Logger.shared.log("CheckUpdate: LCAppInfo.plist has empty LCContainers. Waiting for LiveContainer to populate it.")
                            return false
                        }
                    } else {
                        Logger.shared.log("CheckUpdate: LCAppInfo.plist missing LCContainers key. Waiting...")
                        return false
                    }
                } else {
                    Logger.shared.log("CheckUpdate: Could not read LCAppInfo.plist content.")
                    return false
                }
            }
            
            if backup.hadLCAppInfo {
                Logger.shared.log("CheckUpdate: Finalizing update for \(backup.appName)")
                finalizeUpdate(backup)
            } else {
                Logger.shared.log("CheckUpdate: Discarding backup for \(backup.appName) (No previous LCAppInfo)")
                discardBackup(backup)
            }
            return true
        }
        Logger.shared.log("CheckUpdate: No LCAppInfo.plist found for \(bundleID)")
        return false
    }
    
    func finalizeUpdate(_ backup: AppBackup) {
        Logger.shared.log("FinalizeUpdate: Starting for \(backup.appName)")
        guard let app = installedApps.first(where: { $0.bundleID == backup.bundleID }) else {
            Logger.shared.log("FinalizeUpdate: App not found installed, discarding backup.")
            discardBackup(backup)
            return
        }
        
        let fileManager = FileManager.default
        let newInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        let backupAppURL = backupDirectory.appendingPathComponent(backup.backupPath).appendingPathComponent(backup.originalInstallPath)
        let oldInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
        
        if fileManager.fileExists(atPath: newInfoURL.path) && fileManager.fileExists(atPath: oldInfoURL.path) {
            do {
                let oldData = try Data(contentsOf: oldInfoURL)
                guard let oldPlist = try PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any] else {
                    Logger.shared.log("FinalizeUpdate: Failed to read old plist, discarding.")
                    discardBackup(backup)
                    return
                }
                
                let newData = try Data(contentsOf: newInfoURL)
                var newPlist = try PropertyListSerialization.propertyList(from: newData, format: nil) as? [String: Any] ?? [:]
                
                // NEW: Clean up newly created empty containers before restoring old ones
                if let newContainers = newPlist["LCContainers"] as? [[String: Any]],
                   let dataAppFolder = currentDataApplicationFolder {
                    for container in newContainers {
                        if let folderName = container["folderName"] as? String {
                            let folderURL = dataAppFolder.appendingPathComponent(folderName)
                            if fileManager.fileExists(atPath: folderURL.path) {
                                try? fileManager.removeItem(at: folderURL)
                                Logger.shared.log("FinalizeUpdate: Deleted temporary container: \(folderName)")
                            }
                        }
                    }
                }
                
                // Patch new plist with old data to preserve UserData
                for (key, value) in oldPlist {
                    newPlist[key] = value
                }
                
                let patchedData = try PropertyListSerialization.data(fromPropertyList: newPlist, format: .xml, options: 0)
                try patchedData.write(to: newInfoURL)
                Logger.shared.log("FinalizeUpdate: Patched LCAppInfo for \(backup.bundleID) with old data.")
                
                // Only send notification and discard backup if we successfully patched
                sendNotification(title: "Update Completed", body: "\(backup.appName) has been successfully updated.", type: .success)
                discardBackup(backup)
                
            } catch {
                Logger.shared.log("FinalizeUpdate: Failed to patch LCAppInfo: \(error)")
                // If patching failed, we might want to keep the backup or alert the user?
                // For now, we'll assume if it failed, we can't recover easily, so we discard to avoid loops
                discardBackup(backup)
            }
        } else {
             Logger.shared.log("FinalizeUpdate: Missing plist files (New: \(fileManager.fileExists(atPath: newInfoURL.path)), Old: \(fileManager.fileExists(atPath: oldInfoURL.path)))")
             // If files are missing, we can't proceed
             discardBackup(backup)
        }
    }
    
    // ... [Remaining Backup, Restore, Task methods unchanged]
    func restoreBackup(_ backup: AppBackup) {
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)
            guard let backedUpApp = contents.first(where: { $0.pathExtension == "app" }) else { return }
            
            let dest = currentAppsFolder.appendingPathComponent(backup.originalInstallPath)
            
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            
            try fileManager.moveItem(at: backedUpApp, to: dest)
            
            discardBackup(backup)
            refreshInstalledApps()
        } catch {
            print("Restore failed: \(error)")
        }
    }
    
    func discardBackup(_ backup: AppBackup, deleteContainers: Bool = false) {
        let fileManager = FileManager.default
        let backupFolder = backupDirectory.appendingPathComponent(backup.backupPath)
        
        if deleteContainers {
            let backupAppURL = backupFolder.appendingPathComponent(backup.originalInstallPath)
            let lcInfoURL = backupAppURL.appendingPathComponent("LCAppInfo.plist")
            
            if fileManager.fileExists(atPath: lcInfoURL.path),
               let data = try? Data(contentsOf: lcInfoURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let containers = plist["LCContainers"] as? [[String: Any]],
               let dataAppFolder = currentDataApplicationFolder {
                
                for container in containers {
                    if let folderName = container["folderName"] as? String {
                        let folderURL = dataAppFolder.appendingPathComponent(folderName)
                        try? fileManager.removeItem(at: folderURL)
                        print("Deleted backup container: \(folderName)")
                    }
                }
            }
        }
        
        try? fileManager.removeItem(at: backupFolder)
        
        if let index = pendingBackups.firstIndex(where: { $0.id == backup.id }) {
            pendingBackups.remove(at: index)
            savePendingBackups()
        }
    }
    
    private func restoreFolders() {
        restoreFolder(key: kCustomDownloadFolderKey) { self.customDownloadFolder = $0 }
        restoreFolder(key: kCustomLiveContainerFolderKey) { self.customLiveContainerFolder = $0 }
    }
    
    private func restoreFolder(key: String, assign: (URL) -> Void) {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
            if isStale {
               _ = url.startAccessingSecurityScopedResource()
               let newData = try url.bookmarkData()
               UserDefaults.standard.set(newData, forKey: key)
               url.stopAccessingSecurityScopedResource()
            }
            if url.startAccessingSecurityScopedResource() {
                assign(url)
            }
        } catch { }
    }
    
    private func reconnectExistingTasks() {
        urlSession.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let url = downloadTask.originalRequest?.url else { continue }
                    
                    self.tasks[url] = downloadTask
                    
                    if downloadTask.state == .running {
                        let written = downloadTask.countOfBytesReceived
                        let expected = downloadTask.countOfBytesExpectedToReceive
                        let p = expected > 0 ? Double(written) / Double(expected) : 0.0
                        self.downloadStates[url] = .downloading(progress: p, written: written, total: expected)
                    } else if downloadTask.state == .suspended {
                        self.downloadStates[url] = .paused
                    }
                }
                
                for (urlStr, _) in self.diskResumeDataPaths {
                    if let url = URL(string: urlStr), self.tasks[url] == nil {
                        self.downloadStates[url] = .paused
                    }
                }
            }
        }
    }
    
    private func restoreResumeDataMapping() {
        if let map = UserDefaults.standard.dictionary(forKey: kResumeDataMapKey) as? [String: String] {
            self.diskResumeDataPaths = map
        }
    }
    
    private func saveResumeDataMapping() {
        UserDefaults.standard.set(diskResumeDataPaths, forKey: kResumeDataMapKey)
    }
    
    private func storeResumeData(_ data: Data, for url: URL) {
        let filename = UUID().uuidString
        let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            diskResumeDataPaths[url.absoluteString] = filename
            saveResumeDataMapping()
            resumeDataMap[url] = data
        } catch {
            print("Failed to save resume data: \(error)")
        }
    }
    
    private func retrieveResumeData(for url: URL) -> Data? {
        if let data = resumeDataMap[url] { return data }
        if let filename = diskResumeDataPaths[url.absoluteString] {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            if let data = try? Data(contentsOf: fileURL) { return data }
        }
        return nil
    }
    
    private func clearResumeData(for url: URL) {
        resumeDataMap[url] = nil
        if let filename = diskResumeDataPaths.removeValue(forKey: url.absoluteString) {
            let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
            saveResumeDataMapping()
        }
    }
    
    func setCustomFolder(_ url: URL, forApps: Bool) {
        do {
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
            UserDefaults.standard.set(bookmarkData, forKey: key)
            
            if forApps {
                self.customLiveContainerFolder = url
                self.isAutoUnzipEnabled = true // Auto-enable as requested
                refreshInstalledApps()
            } else {
                self.customDownloadFolder = url
                refreshFileList()
            }
        } catch {
            print("Failed to save bookmark: \(error)")
        }
    }
    
    func clearCustomFolder(forApps: Bool) {
        let key = forApps ? kCustomLiveContainerFolderKey : kCustomDownloadFolderKey
        UserDefaults.standard.removeObject(forKey: key)
        if forApps {
            self.customLiveContainerFolder = nil
            refreshInstalledApps()
        } else {
            self.customDownloadFolder = nil
            refreshFileList()
        }
    }
    
    /// Convenience: starts a download with the user's default intent
    /// (honoring the global "Auto .ipa to .app" setting).
    func startDownload(url: URL) {
        startDownload(url: url, intent: .useDefault)
    }
    
    /// Legacy convenience preserved for callers that still pass a Bool.
    /// New call sites should pass a `DownloadIntent` directly.
    func startDownload(url: URL, downloadOnly: Bool) {
        startDownload(url: url, intent: downloadOnly ? .downloadOnly : .installToLiveContainer)
    }
    
    /// Start (or resume) a download, recording the user's intent so the finish
    /// handler can act on it without re-consulting global UI state.
    ///
    /// - Parameter overrideFilename: when set, the IPA is saved to the Downloads
    ///   folder under this name instead of the one derived from the URL. Used
    ///   to implement "Rename" in the download-only collision flow.
    func startDownload(url: URL, intent: DownloadIntent, overrideFilename: String? = nil) {
        downloadIntents[url] = intent
        if let name = overrideFilename {
            downloadFilenames[url] = name
        } else {
            downloadFilenames[url] = nil
        }
        
        // When the user picks "Rename", the override filename targets a
        // freshly-chosen name that, by construction, does not yet exist on
        // disk. In that case the URL-keyed `getLocalFile` check would still
        // see the *original* file and skip the download — wrong. So we only
        // short-circuit on local file presence when the user is not asking
        // for a renamed target.
        if overrideFilename == nil, let localFile = getLocalFile(for: url) {
            switch intent {
            case .installToLiveContainer:
                Task { try? await self.extractApp(from: localFile) }
            case .useDefault:
                if isAutoUnzipEnabled {
                    Task { try? await self.extractApp(from: localFile) }
                }
            case .downloadOnly:
                break
            }
            return
        }
        
        if case .paused = getStatus(for: url) {
            resumeDownload(url: url)
            return
        }
        
        if tasks[url] == nil {
            if let data = retrieveResumeData(for: url) {
                let task = urlSession.downloadTask(withResumeData: data)
                tasks[url] = task
                task.resume()
                downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
            } else {
                let task = urlSession.downloadTask(with: url)
                tasks[url] = task
                task.resume()
                downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
            }
        } else {
            tasks[url]?.resume()
            downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
        }
    }
    
    /// Decide whether a freshly-finished download should be auto-installed,
    /// given the recorded intent and the global setting.
    private func shouldAutoInstall(for url: URL) -> Bool {
        switch downloadIntents[url] ?? .useDefault {
        case .installToLiveContainer: return true
        case .downloadOnly:           return false
        case .useDefault:             return isAutoUnzipEnabled
        }
    }
    
    // MARK: - Downloads-Folder Collision Helpers
    
    /// The filename a download for `url` would land at, mirroring the logic
    /// inside the finish handler. Used by the UI to detect collisions before
    /// starting a download.
    func defaultFilename(for url: URL) -> String {
        var name = url.lastPathComponent
        if url.pathExtension.isEmpty { name += ".ipa" }
        return name
    }
    
    /// True when a file with the default-derived name already exists in the
    /// Downloads folder. Used to drive the "Replace / Rename / Cancel" prompt
    /// before issuing a `.downloadOnly` request.
    func downloadsFolderContains(filenameFor url: URL) -> Bool {
        let target = currentDownloadFolder.appendingPathComponent(defaultFilename(for: url))
        return FileManager.default.fileExists(atPath: target.path)
    }
    
    /// Delete an existing file in the Downloads folder so a fresh download
    /// can overwrite it. Used by the "Replace" branch of the collision flow.
    func deleteDownloadedFile(named filename: String) throws {
        let target = currentDownloadFolder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
            refreshFileList()
        }
    }
    
    /// Generate a filename that doesn't collide with anything currently in
    /// the Downloads folder by inserting an incrementing " (N)" suffix.
    /// Example: "1Blocker.ipa" → "1Blocker (2).ipa".
    func nonCollidingFilename(basedOn filename: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = currentDownloadFolder
        let fm = FileManager.default
        
        var n = 2
        while true {
            let candidate = ext.isEmpty
                ? "\(stem) (\(n))"
                : "\(stem) (\(n)).\(ext)"
            let target = folder.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: target.path) { return candidate }
            n += 1
            if n > 9999 { return candidate } // safety bail
        }
    }
    
    func pauseDownload(url: URL) {
        guard let task = tasks[url] else { return }
        task.cancel { [weak self] data in
            guard let self = self else { return }
            Task { @MainActor in
                if let resumeData = data { self.storeResumeData(resumeData, for: url) }
                self.downloadStates[url] = .paused
                self.tasks[url] = nil
            }
        }
    }
    
    func resumeDownload(url: URL) {
        if let data = retrieveResumeData(for: url) {
            let task = urlSession.downloadTask(withResumeData: data)
            tasks[url] = task
            task.resume()
            downloadStates[url] = .downloading(progress: 0.0, written: 0, total: -1)
        } else {
            startDownload(url: url)
        }
    }
    
    func cancelDownload(url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        clearResumeData(for: url)
        downloadStates[url] = nil
        downloadIntents[url] = nil
        downloadFilenames[url] = nil
    }
    
    func isDownloading(url: URL) -> Bool {
        if case .downloading = getStatus(for: url) { return true }
        return false
    }
    
    func isPaused(url: URL) -> Bool {
        if case .paused = getStatus(for: url) { return true }
        return false
    }
    
    func refreshFileList() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            let filtered = files.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "app" }
            self.fileList = filtered
        } catch { self.fileList = [] }
    }
    
    func refreshInstalledApps() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: currentAppsFolder, includingPropertiesForKeys: nil)
            var newApps: [LocalApp] = []
            for file in files where file.pathExtension == "app" {
                let plistURL = file.appendingPathComponent("Info.plist")
                var name = file.deletingPathExtension().lastPathComponent
                var bundleID = "unknown"
                var version: String? = nil
                var iconURL: URL? = nil
                
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let displayName = plist["CFBundleDisplayName"] as? String {
                        name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let bundleName = plist["CFBundleName"] as? String {
                        name = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    if let ver = plist["CFBundleShortVersionString"] as? String {
                        version = ver
                    } else if let ver = plist["CFBundleVersion"] as? String {
                        version = ver
                    }
                    
                    var iconFiles: [String] = []
                    if let iconsDict = plist["CFBundleIcons"] as? [String: Any],
                       let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let ipadIconsDict = plist["CFBundleIcons~ipad"] as? [String: Any],
                       let primaryIcon = ipadIconsDict["CFBundlePrimaryIcon"] as? [String: Any],
                       let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: files)
                    }
                    if let legacyFiles = plist["CFBundleIconFiles"] as? [String] {
                        iconFiles.append(contentsOf: legacyFiles)
                    }
                    
                    for iconName in iconFiles.reversed() {
                        if let found = findIconFile(in: file, name: iconName) { iconURL = found; break }
                    }
                    
                    if iconURL == nil {
                        iconURL = findIconFile(in: file, name: "AppIcon60x60") ?? findIconFile(in: file, name: "AppIcon")
                    }
                }
                newApps.append(LocalApp(name: name, bundleID: bundleID, version: version, url: file, iconURL: iconURL))
            }
            self.installedApps = newApps
        } catch { self.installedApps = [] }
    }
    
    private func findIconFile(in folder: URL, name: String) -> URL? {
        let extensions = ["png", "jpg"]
        let candidates = [name, "\(name)@2x", "\(name)@3x", "\(name)60x60@2x"]
        for c in candidates {
            for e in extensions {
                let f = folder.appendingPathComponent("\(c).\(e)")
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
        }
        return nil
    }
    
    func renameFile(_ fileURL: URL, newName: String) {
        let folder = fileURL.deletingLastPathComponent()
        let newURL = folder.appendingPathComponent(newName)
        do {
            if startAccessing(fileURL) { defer { fileURL.stopAccessingSecurityScopedResource() } }
            if FileManager.default.fileExists(atPath: newURL.path) {
                print("Error: File already exists")
                return
            }
            try FileManager.default.moveItem(at: fileURL, to: newURL)
            refreshFileList()
        } catch {
            print("Rename failed: \(error)")
        }
    }
    
    func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshFileList()
    }
    
    func deleteApp(_ app: LocalApp) {
        let fileManager = FileManager.default
        let lcInfoURL = app.url.appendingPathComponent("LCAppInfo.plist")
        if fileManager.fileExists(atPath: lcInfoURL.path),
           let data = try? Data(contentsOf: lcInfoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let containers = plist["LCContainers"] as? [[String: Any]],
           let dataAppFolder = currentDataApplicationFolder {
            for container in containers {
                if let folderName = container["folderName"] as? String {
                    try? fileManager.removeItem(at: dataAppFolder.appendingPathComponent(folderName))
                }
            }
        }
        try? fileManager.removeItem(at: app.url)
        refreshInstalledApps()
    }
    
    func clearAllFiles() {
        try? FileManager.default.contentsOfDirectory(at: currentDownloadFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension != "app" }
            .forEach { try? FileManager.default.removeItem(at: $0) }
        refreshFileList()
    }
    
    func convertToApp(file: URL) {
        Task {
            _ = await MainActor.run { self.extractingFiles.insert(file) }
            
            do {
                var accessActive = false
                if file.startAccessingSecurityScopedResource() {
                    accessActive = true
                }
                
                try await extractApp(from: file)
                
                if accessActive {
                    file.stopAccessingSecurityScopedResource()
                    accessActive = false
                }
                
                if self.pendingInstallation == nil {
                    _ = await MainActor.run {
                        self.extractingFiles.remove(file)
                        self.refreshFileList()
                        self.refreshInstalledApps()
                    }
                } else {
                     _ = await MainActor.run { self.extractingFiles.remove(file) }
                }
            } catch {
                print("Convert error: \(error)")
                _ = await MainActor.run { self.extractingFiles.remove(file) }
            }
        }
    }
    
    func importFile(at source: URL) {
        let dest = currentDownloadFolder.appendingPathComponent(source.lastPathComponent)
        do {
            if source.startAccessingSecurityScopedResource() {
                let access = true
                
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: source, to: dest)
                refreshFileList()
                
                if access { source.stopAccessingSecurityScopedResource() }
            }
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func extractApp(from sourceURL: URL) async throws {
        let fileManager = FileManager.default
        let folder = self.currentAppsFolder
        if !fileManager.fileExists(atPath: folder.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        
        #if canImport(ZIPFoundation)
        let tempUnzipDir = folder.appendingPathComponent("Temp_" + UUID().uuidString)
        try fileManager.createDirectory(at: tempUnzipDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: sourceURL, to: tempUnzipDir)
        
        let payloadDir = tempUnzipDir.appendingPathComponent("Payload")
        if fileManager.fileExists(atPath: payloadDir.path) {
            let contents = try fileManager.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
            if let appBundle = contents.first(where: { $0.pathExtension == "app" }) {
                
                var targetName = appBundle.lastPathComponent
                var bundleID = "unknown"
                
                let plistURL = appBundle.appendingPathComponent("Info.plist")
                if let plistData = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
                    if let bid = plist["CFBundleIdentifier"] as? String {
                        bundleID = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                        targetName = bundleID + ".app"
                    }
                }
                
                if let existingApp = self.installedApps.first(where: { $0.bundleID == bundleID && bundleID != "unknown" }) {
                    _ = await MainActor.run {
                        self.pendingInstallation = PendingInstallation(
                            appName: existingApp.name, 
                            bundleID: bundleID,
                            tempPayloadURL: payloadDir, 
                            extractedAppURL: appBundle,
                            sourceArchiveURL: sourceURL,
                            existingApp: existingApp
                        )
                    }
                    return
                }
                
                var finalURL = folder.appendingPathComponent(targetName)
                if fileManager.fileExists(atPath: finalURL.path) {
                    let nameWithoutExt = finalURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    while fileManager.fileExists(atPath: finalURL.path) {
                        finalURL = folder.appendingPathComponent("\(nameWithoutExt)_\(counter).app")
                        counter += 1
                    }
                }
                
                try fileManager.moveItem(at: appBundle, to: finalURL)
                
                if sourceURL.path.contains(currentDownloadFolder.path) { try? fileManager.removeItem(at: sourceURL) }
                try? fileManager.removeItem(at: tempUnzipDir)
                
            } else { try? fileManager.removeItem(at: tempUnzipDir) }
        } else { try? fileManager.removeItem(at: tempUnzipDir) }
        #else
        if sourceURL.pathExtension.lowercased() == "ipa" {
            let zipURL = sourceURL.deletingPathExtension().appendingPathExtension("zip")
            if fileManager.fileExists(atPath: zipURL.path) { try fileManager.removeItem(at: zipURL) }
            try fileManager.moveItem(at: sourceURL, to: zipURL)
        }
        #endif
    }
    
    func finalizeInstallation(action: InstallAction) {
        guard let pending = pendingInstallation else { return }
        
        let fileManager = FileManager.default
        let folder = self.currentAppsFolder
        let downloadDir = self.currentDownloadFolder
        let backupDir = self.backupDirectory
        
        Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .installSeparate:
                    var targetName = pending.extractedAppURL.lastPathComponent
                    if !pending.bundleID.isEmpty && pending.bundleID != "unknown" {
                        targetName = pending.bundleID + ".app"
                    }
                    
                    var finalURL = folder.appendingPathComponent(targetName)
                    let nameWithoutExt = finalURL.deletingPathExtension().lastPathComponent
                    var counter = 1
                    while fileManager.fileExists(atPath: finalURL.path) {
                        finalURL = folder.appendingPathComponent("\(nameWithoutExt)_\(counter).app")
                        counter += 1
                    }
                    
                    try fileManager.moveItem(at: pending.extractedAppURL, to: finalURL)
                    
                case .updateExisting:
                    guard let existing = pending.existingApp else { break }
                    
                    let existingPath = existing.url
                    let lcInfoURL = existingPath.appendingPathComponent("LCAppInfo.plist")
                    let hadInfo = fileManager.fileExists(atPath: lcInfoURL.path)
                    
                    if !hadInfo {
                        if fileManager.fileExists(atPath: existingPath.path) {
                            try fileManager.removeItem(at: existingPath)
                        }
                        try fileManager.moveItem(at: pending.extractedAppURL, to: existingPath)
                    } else {
                        let backupUUID = UUID().uuidString
                        let destFolder = backupDir.appendingPathComponent(backupUUID)
                        try fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
                        
                        let backupDest = destFolder.appendingPathComponent(existingPath.lastPathComponent)
                        
                        try fileManager.moveItem(at: existingPath, to: backupDest)
                        
                        let backupRecord = AppBackup(
                            bundleID: existing.bundleID,
                            appName: existing.name,
                            version: existing.version,
                            backupPath: backupUUID,
                            originalInstallPath: existingPath.lastPathComponent,
                            date: Date(),
                            hadLCAppInfo: hadInfo
                        )
                        
                        await MainActor.run {
                            self.pendingBackups.append(backupRecord)
                            self.savePendingBackups()
                        }
                        
                        try fileManager.moveItem(at: pending.extractedAppURL, to: existingPath)
                    }
                    
                case .cancel:
                    break
                }
            } catch {
                print("Finalize install error: \(error)")
            }
            
            let tempRoot = pending.tempPayloadURL.deletingLastPathComponent()
            try? fileManager.removeItem(at: tempRoot)
            
            if action != .cancel, pending.sourceArchiveURL.path.contains(downloadDir.path) {
                try? fileManager.removeItem(at: pending.sourceArchiveURL)
            }
            
            try? await Task.sleep(nanoseconds: 200_000_000)

            await MainActor.run {
                self.pendingInstallation = nil
                self.refreshFileList()
                self.refreshInstalledApps()
            }
        }
    }
    
    private func startAccessing(_ url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(sourceURL.pathExtension)
        
        do {
            if fileManager.fileExists(atPath: stagingURL.path) { try fileManager.removeItem(at: stagingURL) }
            try fileManager.moveItem(at: location, to: stagingURL)
        } catch {
            Task { @MainActor in self.downloadStates[sourceURL] = nil }
            return
        }
        
        Task { @MainActor in
            do {
                let manager = FileManager.default
                let folder = self.currentDownloadFolder
                if !manager.fileExists(atPath: folder.path) {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                
                var finalName = self.downloadFilenames[sourceURL] ?? sourceURL.lastPathComponent
                if (URL(fileURLWithPath: finalName).pathExtension).isEmpty {
                    finalName += ".ipa"
                }
                
                let finalURL = folder.appendingPathComponent(finalName)
                if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
                try manager.moveItem(at: stagingURL, to: finalURL)
                
                self.sendNotification(title: "Download Complete", body: "\(finalName) has been downloaded.", type: .success)
                
                let autoInstall = self.shouldAutoInstall(for: sourceURL)
                self.downloadIntents[sourceURL] = nil
                self.downloadFilenames[sourceURL] = nil
                
                if autoInstall && finalURL.pathExtension.lowercased() == "ipa" {
                    self.extractingFiles.insert(finalURL)
                    try await self.extractApp(from: finalURL)
                    if self.pendingInstallation == nil {
                        self.extractingFiles.remove(finalURL)
                    }
                }
                
                self.downloadStates[sourceURL] = nil
                self.tasks[sourceURL] = nil
                self.clearResumeData(for: sourceURL)
                self.refreshFileList()
                self.refreshInstalledApps()
            } catch {
                self.downloadStates[sourceURL] = nil
                self.refreshFileList()
                if let fname = sourceURL.lastPathComponent as String?, let furl = self.currentDownloadFolder.appendingPathComponent(fname) as URL? {
                    self.extractingFiles.remove(furl)
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0.0
        Task { @MainActor in 
            self.downloadStates[sourceURL] = .downloading(progress: progress, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let sourceURL = task.originalRequest?.url else { return }
        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled {
                if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    Task { @MainActor in
                        self.storeResumeData(resumeData, for: sourceURL)
                        self.downloadStates[sourceURL] = .paused
                    }
                } else {
                    Task { @MainActor in self.downloadStates[sourceURL] = nil }
                }
                return
            }
            if let resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Task { @MainActor in
                    self.storeResumeData(resumeData, for: sourceURL)
                    self.downloadStates[sourceURL] = .paused
                }
            } else {
                Task { @MainActor in self.downloadStates[sourceURL] = nil }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        if let url = task.originalRequest?.url {
            Task { @MainActor in self.downloadStates[url] = .waitingForConnection }
        }
    }
    
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let handler = self.backgroundCompletionHandler {
                self.backgroundCompletionHandler = nil
                handler()
            }
        }
    }
}

