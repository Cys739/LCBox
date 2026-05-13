import SwiftUI

// MARK: - Pill Button Style

/// Visual variants for action pills. Keep this list small; each variant
/// represents a distinct semantic role, not a color choice.
enum PillVariant {
    /// Primary call-to-action (GET, OPEN). Tinted accent.
    case primary
    /// Filled accent — used for the "OPEN" affordance to mirror App Store conventions.
    case prominent
    /// Neutral secondary action (File / share). Tinted gray.
    case secondary
}

/// Sizes pills can render at. `regular` matches the main detail header;
/// `compact` matches the per-version row in the version history list.
enum PillSize {
    case regular
    case compact
    
    var hPadding: CGFloat { self == .compact ? 16 : 24 }
    var vPadding: CGFloat { 6 }
}

/// Single source of truth for action-pill styling. Every action pill in the
/// app uses this style; changing geometry or color here changes every pill.
struct PillButtonStyle: ButtonStyle {
    let variant: PillVariant
    let size: PillSize
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .compact ? .caption.bold() : .headline.bold())
            .padding(.horizontal, size.hPadding)
            .padding(.vertical, size.vPadding)
            .foregroundColor(foreground)
            .background(background)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
    
    private var foreground: Color {
        switch variant {
        case .primary, .secondary: return .blue
        case .prominent:           return .white
        }
    }
    
    private var background: Color {
        switch variant {
        case .primary:   return Color.blue.opacity(0.15)
        case .secondary: return Color.gray.opacity(0.15)
        case .prominent: return Color.blue
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ variant: PillVariant, size: PillSize = .regular) -> PillButtonStyle {
        PillButtonStyle(variant: variant, size: size)
    }
}

// MARK: - App Actions View

/// The full action cluster for an app: GET (with long-press menu for explicit
/// install vs download-only), File (when a local IPA exists), OPEN (when the
/// app is installed in LiveContainer). Mid-download it collapses to a single
/// progress affordance.
///
/// Owns its own setup-needed alert state so callers don't have to thread it
/// through.
struct AppActionsView: View {
    let app: AppItem
    var size: PillSize = .regular
    
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var showShareSheet = false
    @State private var showSetupNeeded = false
    
    var body: some View {
        let downloadURL = URL(string: app.downloadURL)
        let localURL = downloadURL.flatMap { downloadManager.getLocalFile(for: $0) }
        let status: DownloadStatus = downloadURL.map { downloadManager.getStatus(for: $0) } ?? .none
        let isInstalled = downloadManager.isAppInstalled(bundleID: app.bundleIdentifier)
        
        HStack(spacing: 8) {
            if status.isActive, let url = downloadURL {
                ProgressPill(url: url, status: status, size: size)
            } else {
                GetPill(url: downloadURL, size: size)
                if let localURL = localURL {
                    FilePill(localURL: localURL, size: size, showShareSheet: $showShareSheet)
                }
                // OPEN doesn't make sense per-version (the install is bundle-level,
                // not version-level), so it's suppressed in compact rows.
                if size == .regular && isInstalled {
                    OpenPill(bundleID: app.bundleIdentifier, showSetupNeeded: $showSetupNeeded)
                }
            }
        }
        .alert("Setup Required", isPresented: $showSetupNeeded) {
            Button("Open LiveContainer") {
                let folder = downloadManager.getInstalledAppName(bundleID: app.bundleIdentifier) ?? ""
                if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(folder)") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This app has not been configured yet. Please open LiveContainer, then find and run this app once to generate the configuration.")
        }
    }
}

// MARK: - Pills

private struct GetPill: View {
    let url: URL?
    let size: PillSize
    @EnvironmentObject private var downloadManager: DownloadManager
    
    var body: some View {
        Button {
            if let url = url { downloadManager.startDownload(url: url, intent: .useDefault) }
        } label: {
            Text("GET")
        }
        .buttonStyle(.pill(.primary, size: size))
        .contextMenu {
            Button {
                if let url = url { downloadManager.startDownload(url: url, intent: .installToLiveContainer) }
            } label: {
                Label("Install to LiveContainer", systemImage: "square.and.arrow.down.on.square")
            }
            Button {
                if let url = url { downloadManager.startDownload(url: url, intent: .downloadOnly) }
            } label: {
                Label("Download IPA Only", systemImage: "arrow.down.doc")
            }
        }
    }
}

private struct FilePill: View {
    let localURL: URL
    let size: PillSize
    @Binding var showShareSheet: Bool
    
    var body: some View {
        Button {
            showShareSheet = true
        } label: {
            if size == .compact {
                Image(systemName: "doc.fill")
            } else {
                Label("File", systemImage: "doc.fill")
            }
        }
        .buttonStyle(.pill(.secondary, size: size))
        .sheet(isPresented: $showShareSheet) {
            FileShareSheet(activityItems: [Self.prepareFileForShare(localURL)])
        }
    }
    
    /// Copy the file into a fresh temp dir so the share sheet has a stable
    /// path that won't move out from under it.
    private static func prepareFileForShare(_ url: URL) -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
        try? fileManager.removeItem(at: tempFile)
        try? fileManager.copyItem(at: url, to: tempFile)
        return tempFile
    }
}

private struct OpenPill: View {
    let bundleID: String
    @Binding var showSetupNeeded: Bool
    @EnvironmentObject private var downloadManager: DownloadManager
    
    var body: some View {
        Button {
            switch downloadManager.launchInstalledApp(bundleID: bundleID) {
            case .launched, .notInstalled:
                break
            case .needsSetup:
                showSetupNeeded = true
            }
        } label: {
            Text("OPEN")
        }
        .buttonStyle(.pill(.prominent))
    }
}

private struct ProgressPill: View {
    let url: URL
    let status: DownloadStatus
    let size: PillSize
    @EnvironmentObject private var downloadManager: DownloadManager
    
    private var diameter: CGFloat { size == .compact ? 28 : 32 }
    private var iconSize: CGFloat { size == .compact ? 10 : 14 }
    
    var body: some View {
        switch status {
        case .downloading(let progress, _, _):
            Button {
                downloadManager.pauseDownload(url: url)
            } label: {
                ZStack {
                    Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.blue)
                    Circle().trim(from: 0.0, to: CGFloat(max(0.01, progress)))
                        .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .foregroundColor(.blue)
                        .rotationEffect(Angle(degrees: 270.0))
                        .animation(.linear, value: progress)
                    Image(systemName: "pause.fill").font(.system(size: iconSize)).foregroundColor(.blue)
                }
                .frame(width: diameter, height: diameter)
            }
        case .paused:
            Button {
                downloadManager.resumeDownload(url: url)
            } label: {
                ZStack {
                    Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.blue)
                    Image(systemName: "play.fill").font(.system(size: iconSize)).foregroundColor(.blue)
                }
                .frame(width: diameter, height: diameter)
            }
        case .waitingForConnection:
            Button {
                downloadManager.pauseDownload(url: url)
            } label: {
                ZStack {
                    Circle().stroke(lineWidth: 3).opacity(0.2).foregroundColor(.orange)
                    Image(systemName: "wifi.slash").font(.system(size: iconSize)).foregroundColor(.orange)
                }
                .frame(width: diameter, height: diameter)
            }
        case .none:
            EmptyView()
        }
    }
}
