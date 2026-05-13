import SwiftUI

struct AppDetailView: View {
    let app: AppItem
    @ObservedObject var viewModel: AppStoreViewModel
    @EnvironmentObject var downloadManager: DownloadManager
    
    // Helper to extract versions cleanly and avoid compiler confusion in ViewBuilder
    private var versionHistory: [AppItem] {
        return viewModel.getVersions(for: app)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider().padding(.horizontal)
                if !app.screenshotURLs.isEmpty {
                    screenshotsSection
                    Divider().padding(.horizontal)
                }
                aboutSection
                Divider().padding(.horizontal)
                versionsSection
                    .padding(.bottom, 40)
            }
            .padding(.top)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
    
    var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                if let image = phase.image {
                    image.resizable()
                } else if phase.error != nil {
                    Color.gray
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(radius: 2)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text("v\(app.version)")
                    if let size = app.size {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                
                if let repo = app.sourceRepoName {
                     Text(repo)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                
                HStack(spacing: 12) {
                    AppActionsView(app: app)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
    
    // ... [screenshotsSection, aboutSection, versionsSection unchanged] ...
    var screenshotsSection: some View {
        VStack(alignment: .leading) {
            Text("Preview")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(app.screenshotURLs, id: \.self) { urlString in
                        AsyncImage(url: URL(string: urlString)) { phase in
                            if let image = phase.image {
                                image.resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(width: 200, height: 350)
                            }
                        }
                        .frame(height: 350)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About")
                .font(.headline)
            Text(app.localizedDescription ?? "No description available.")
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding(.horizontal)
    }
    
    var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version History")
                .font(.headline)
                .padding(.horizontal)
            
            ForEach(versionHistory) { versionApp in
                VersionRow(app: versionApp)
            }
        }
    }
}

// Separate row for versions (Unchanged)
struct VersionRow: View {
    let app: AppItem
    @EnvironmentObject var downloadManager: DownloadManager
    
    var isInstalledVersion: Bool {
        guard let current = downloadManager.getInstalledVersion(bundleID: app.bundleIdentifier) else { return false }
        return current == app.version
    }
    
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Version \(app.version)")
                        .fontWeight(.semibold)
                    
                    if let repo = app.sourceRepoName {
                        Text(repo)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    if isInstalledVersion {
                        Text("Current")
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                            .padding(.horizontal, 4)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                HStack(spacing: 4) {
                    Text(app.versionDate ?? "Unknown Date")
                    
                    if let size = app.size {
                        Text("•")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            AppActionsView(app: app, size: .compact)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// ... [FileShareSheet] ...
struct FileShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

