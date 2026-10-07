import SwiftUI

/// Junk on the device: scan, pick, confirm, clean.
struct CleanupPage: View {
    let model: CleanupModel
    let home: String?

    @Environment(\.locale) private var locale
    @State private var expanded: Set<String> = []
    @State private var confirming = false

    private var formats: Formats { Formats(locale: locale) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch model.state {
                    case .idle:
                        intro
                    case .scanning:
                        progress(Text("Looking for junk on the device…"))
                    case .cleaning:
                        progress(Text("Cleaning up…"))
                    case let .cleaned(freed):
                        cleaned(freed)
                    case .scanned:
                        ForEach(model.categories.indices, id: \.self) { index in
                            categoryRow(index)
                        }
                    }
                }
                .padding(20)
            }
            if model.state == .scanned {
                Divider()
                HStack {
                    Text("Selected: \(formats.bytes(model.selectedSize))")
                        .font(.headline)
                        .monospacedDigit()
                    Spacer()
                    Button("Scan Again") { Task { await model.scan() } }
                    Button("Clean Up…") { confirming = true }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selectedSize == 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .alert(Text("Clean up \(formats.bytes(model.selectedSize))?"), isPresented: $confirming) {
            Button("Clean Up", role: .destructive) { Task { await model.clean() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Selected files are deleted from the device and can't be recovered. App caches are rebuilt by the apps.")
        }
        .alert(Text("Something went wrong"), isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") { model.failure = nil }
        } message: {
            Text(verbatim: model.failure ?? "")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find junk on the device that's safe to remove: app caches, leftovers of removed apps, downloaded installers and thumbnail caches. Large files are listed for you to check. Nothing is removed until you choose to.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Scan") { Task { await model.scan() } }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func progress(_ text: Text) -> some View {
        HStack {
            ProgressView().controlSize(.small)
            text.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func cleaned(_ freed: Int64?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            if let freed {
                Text("Freed \(formats.bytes(freed))").font(.title2.weight(.semibold))
            } else {
                Text("Done").font(.title2.weight(.semibold))
            }
            Button("Scan Again") { Task { await model.scan() } }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: Categories

    private func categoryRow(_ index: Int) -> some View {
        let category = model.categories[index]
        let isEmpty = category.size == 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: Binding(get: { model.categories[index].selected && !isEmpty },
                                     set: { model.categories[index].selected = $0 })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(isEmpty)
                Image(systemName: symbol(category.kind))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    title(category.kind).font(.headline)
                    detail(category.kind)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Group {
                    if isEmpty {
                        Text("Nothing found")
                    } else {
                        Text(verbatim: formats.bytes(category.size))
                    }
                }
                .monospacedDigit()
                .foregroundStyle(isEmpty ? .secondary : .primary)
                if !category.items.isEmpty {
                    Button {
                        if expanded.contains(category.id) { expanded.remove(category.id) } else { expanded.insert(category.id) }
                    } label: {
                        Image(systemName: expanded.contains(category.id) ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded.contains(category.id) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(category.items.indices, id: \.self) { item in
                        itemRow(category: index, item: item)
                    }
                }
                .padding(.leading, 64)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private func itemRow(category: Int, item: Int) -> some View {
        let kind = model.categories[category].kind
        let entry = model.categories[category].items[item]
        return HStack(spacing: 8) {
            if kind != .appCaches {
                Toggle(isOn: Binding(get: { model.categories[category].items[item].selected },
                                     set: { model.categories[category].items[item].selected = $0 })) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .disabled(!model.categories[category].selected)
            }
            Group {
                if kind == .appCaches {
                    AppNames.text(for: entry.path, home: home)
                } else {
                    Text(verbatim: entry.path.replacingOccurrences(of: "/sdcard/", with: ""))
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 8)
            if let modified = entry.modified {
                Text(verbatim: modified.formatted(.dateTime.year().month().day().locale(locale)))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: formats.bytes(entry.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .font(.callout)
    }

    private func symbol(_ kind: CleanupCategory.Kind) -> String {
        switch kind {
        case .appCaches: "square.stack.3d.up"
        case .leftovers: "archivebox"
        case .installers: "shippingbox"
        case .thumbnails: "photo.on.rectangle"
        case .largeFiles: "doc.badge.ellipsis"
        }
    }

    private func title(_ kind: CleanupCategory.Kind) -> Text {
        switch kind {
        case .appCaches: Text("App caches")
        case .leftovers: Text("Leftovers of removed apps")
        case .installers: Text("Installer files (.apk)")
        case .thumbnails: Text("Thumbnail caches")
        case .largeFiles: Text("Large files")
        }
    }

    private func detail(_ kind: CleanupCategory.Kind) -> Text {
        switch kind {
        case .appCaches: Text("Temporary files apps keep to load faster. Android clears them for all apps at once, and the apps rebuild what they need.")
        case .leftovers: Text("Folders in Android/data, obb and media named after apps that are no longer installed.")
        case .installers: Text("Downloaded app installers. Apps stay installed when these are removed.")
        case .thumbnails: Text("Small preview pictures. The gallery makes them again when needed.")
        case .largeFiles: Text("Files over \(CleanupScan.largeFileMegabytes) MB. Not selected: check what they are first.")
        }
    }
}
