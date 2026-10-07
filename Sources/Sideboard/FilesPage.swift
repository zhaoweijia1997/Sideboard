import SwiftUI

/// The device's shared storage: browse, download to the Mac, upload (or drop files on the
/// window), new folder, rename, delete.
struct FilesPage: View {
    let model: FilesModel
    let dashboard: DashboardModel

    @Environment(\.locale) private var locale
    @State private var selection: Set<String> = []
    @State private var naming: Naming?
    @State private var name = ""
    @State private var confirmingDelete: [DeviceFile] = []

    private var formats: Formats { Formats(locale: locale) }

    enum Naming: Identifiable {
        case newFolder
        case rename(DeviceFile)
        var id: String {
            switch self {
            case .newFolder: "new"
            case let .rename(file): "rename-" + file.path
            }
        }
    }

    private var selectedFiles: [DeviceFile] { model.files.filter { selection.contains($0.path) } }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            table
            actions
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .task { if model.files.isEmpty { await model.reload() } }
        .onChange(of: dashboard.finishedTransfers) { Task { await model.reload() } }
        .onChange(of: model.path) { selection = [] }
        .sheet(item: $naming) { naming in
            NameSheet(title: namingTitle(naming), name: $name) {
                let text = name
                Task {
                    switch naming {
                    case .newFolder: await model.newFolder(named: text)
                    case let .rename(file): await model.rename(file, to: text)
                    }
                }
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let files = confirmingDelete
                confirmingDelete = []
                Task { await model.delete(files) }
            }
            Button("Cancel", role: .cancel) { confirmingDelete = [] }
        } message: {
            Text("They're removed from the device for good: there's no Trash there.")
        }
        .alert(Text("Something went wrong"), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(verbatim: model.failure ?? "")
        }
    }

    private var deleteTitle: Text {
        confirmingDelete.count == 1
            ? Text("Delete “\(confirmingDelete[0].name)” from the device?")
            : Text("Delete \(confirmingDelete.count) items from the device?")
    }

    private func namingTitle(_ naming: Naming) -> LocalizedStringKey {
        switch naming {
        case .newFolder: "New Folder"
        case .rename: "Rename"
        }
    }

    // MARK: Path bar

    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!model.canGoUp)
            .help(Text("Up"))

            Menu {
                ForEach(model.roots) { root in
                    Button { Task { await model.go(to: root.path) } } label: { rootLabel(root) }
                }
            } label: {
                rootLabel(model.root)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ForEach(model.crumbs, id: \.path) { crumb in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                Button(crumb.name) { Task { await model.go(to: crumb.path) } }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
            }
            Spacer()
            if model.loading || model.measuring {
                ProgressView().controlSize(.small)
            }
            Toggle(isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 })) {
                Text("Hidden files")
            }
            .toggleStyle(.checkbox)
            Button {
                Task { await model.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(Text("Reload"))
        }
    }

    private func rootLabel(_ root: FilesModel.Root) -> some View {
        Label {
            if root.isInternal {
                Text("Internal storage")
            } else {
                Text("USB drive \(root.volumeName)")
            }
        } icon: {
            Image(systemName: root.isInternal ? "internaldrive" : "externaldrive")
        }
    }

    // MARK: Table

    private var table: some View {
        Table(model.visibleFiles, selection: $selection) {
            TableColumn(Text("Name")) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.isFolder ? "folder.fill" : symbol(for: file.name))
                        .foregroundStyle(file.isFolder ? Color.accentColor : Color.secondary)
                        .frame(width: 18)
                    Text(verbatim: file.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 240, ideal: 380)
            TableColumn(Text("Size")) { file in
                Group {
                    if file.isFolder {
                        Text(verbatim: model.folderSizes[file.path].map(formats.bytes) ?? "–")
                    } else {
                        Text(verbatim: formats.bytes(file.size))
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
            TableColumn(Text("Modified")) { file in
                Text(verbatim: file.modified.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { paths in
            let files = model.files.filter { paths.contains($0.path) }
            if !files.isEmpty {
                Button("Download to Mac…") { download(files) }
                if files.count == 1 {
                    Button("Rename…") {
                        name = files[0].name
                        naming = .rename(files[0])
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmingDelete = files }
            }
        } primaryAction: { paths in
            if paths.count == 1, let file = model.files.first(where: { paths.contains($0.path) }), file.isFolder {
                Task { await model.go(to: file.path) }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Upload…") { upload() }
            Button("New Folder…") {
                name = ""
                naming = .newFolder
            }
            Button("Download to Mac…") { download(selectedFiles) }
                .disabled(selectedFiles.isEmpty)
            Button("Rename…") {
                if let file = selectedFiles.first {
                    name = file.name
                    naming = .rename(file)
                }
            }
            .disabled(selectedFiles.count != 1)
            Button("Delete…", role: .destructive) { confirmingDelete = selectedFiles }
                .disabled(selectedFiles.isEmpty)
            Spacer()
            Button("Show Folder Sizes") { Task { await model.measureFolders() } }
                .disabled(model.measuring)
        }
        .controlSize(.small)
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = String(localized: "Choose files or folders to copy into this folder on the device.")
        if panel.runModal() == .OK {
            dashboard.upload(panel.urls, to: model.path)
        }
    }

    private func download(_ files: [DeviceFile]) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = String(localized: "Save Here")
        if panel.runModal() == .OK, let folder = panel.url {
            dashboard.download(files.map { ($0.path, $0.name) }, to: folder)
        }
    }

    private func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp": "photo"
        case "mp4", "mkv", "mov", "avi", "webm", "ts", "m4v": "film"
        case "mp3", "flac", "aac", "m4a", "wav", "ogg": "music.note"
        case "apk": "shippingbox"
        case "zip", "rar", "7z", "gz", "tar": "doc.zipper"
        case "txt", "log", "json", "xml", "md": "doc.text"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

/// Asks for a name: new folder, rename.
private struct NameSheet: View {
    let title: LocalizedStringKey
    @Binding var name: String
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(text: $name) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(finish)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }
        .padding(20)
    }

    private func finish() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !name.contains("/") else { return }
        done()
        dismiss()
    }
}
