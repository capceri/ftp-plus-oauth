import AppKit
import FITStudioCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: FileStore
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fits = urls.filter { $0.pathExtension.lowercased() == "fit" }
            store.open(fits)
            return !fits.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .compare:
            CompareView()
        case .file:
            if let file = store.selectedFile {
                FileDetailView(file: file)
                    .id(file.id)
            } else {
                welcome
            }
        case nil:
            welcome
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            EmptyState(title: store.loading.isEmpty ? "Open a FIT file" : "Opening…",
                       message: "Drop .fit files here, or choose File › Open. Open two recordings of the same ride to compare them.",
                       symbol: "doc.badge.plus")
                .frame(maxHeight: 260)
            Button("Open FIT Files…") { store.showOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: FileStore

    var body: some View {
        List(selection: $store.selection) {
            Section {
                Label("Compare", systemImage: "arrow.left.arrow.right")
                    .tag(SidebarItem.compare)
            }
            Section("Files") {
                ForEach(store.files) { file in
                    FileRow(file: file)
                        .tag(SidebarItem.file(file.id))
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button("Use as Comparison Reference") {
                                store.compare.makeReference(file.id)
                                store.selection = .compare
                            }
                            Divider()
                            Button("Close") { store.close(file) }
                        }
                }
                ForEach(store.loading, id: \.self) { url in
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    store.showOpenPanel()
                } label: {
                    Label("Open", systemImage: "plus")
                }
                .help("Open FIT files (⌘O)")
            }
        }
        .onDeleteCommand {
            store.closeSelection()
        }
    }
}

private struct FileRow: View {
    @ObservedObject var file: LoadedFile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(file.name).lineLimit(1)
                if file.hasAdjustments {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(file.hasUnsavedAdjustments ? Color.orange : Color.secondary)
                        .help(file.hasUnsavedAdjustments ? "Adjustments not saved yet" : "Adjusted copy saved")
                }
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = file.activity.startDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(Format.duration(file.activity.info.elapsedTime ?? file.activity.duration))
        if let creator = file.activity.info.creator { parts.append(creator) }
        return parts.joined(separator: " · ")
    }
}

struct FileDetailView: View {
    @EnvironmentObject private var store: FileStore
    @ObservedObject var file: LoadedFile

    var body: some View {
        Group {
            switch store.tab {
            case .summary: SummaryView(file: file)
            case .charts: ChartsView(file: file)
            case .adjust: AdjustView(file: file)
            case .data: DataView(file: file)
            case .messages: MessagesView(file: file)
            }
        }
        .navigationTitle(file.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.tab) {
                    ForEach(FileTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.exportCSV(of: file)
                } label: {
                    Label("Export CSV", systemImage: "tablecells.badge.ellipsis")
                }
                .help("Export the records as CSV (⇧⌘E)")
                Button {
                    store.saveAdjustedCopy(of: file)
                } label: {
                    Label("Save Adjusted Copy", systemImage: "square.and.arrow.down")
                }
                .disabled(!file.hasAdjustments)
                .help("Save a copy of the file with your adjustments (⌘S)")
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let sport = file.activity.info.sport { parts.append(sport) }
        if file.hasAdjustments {
            parts.append("\(file.activeAdjustments.count) channel\(file.activeAdjustments.count == 1 ? "" : "s") adjusted")
        }
        return parts.joined(separator: " · ")
    }
}
