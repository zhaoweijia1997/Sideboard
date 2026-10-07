import AppKit
import SwiftUI

/// A small TV with a pulse line, drawn as a template image so it follows the menu bar's color.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.4)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            // Screen and stand.
            context.addPath(CGPath(roundedRect: CGRect(x: 1.7, y: 3, width: 14.6, height: 10), cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.strokePath()
            context.fill(CGRect(x: 6, y: 14.6, width: 6, height: 1.4))
            // Pulse.
            context.move(to: CGPoint(x: 3.8, y: 8.4))
            for point in [(6.6, 8.4), (7.6, 6.2), (8.8, 10.8), (10.2, 5.4), (11.2, 8.4), (14.2, 8.4)] {
                context.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The panel that opens from the menu bar icon: every device at a glance.
struct MenuBarPanel: View {
    let store: DeviceStore
    let monitor: Monitor

    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale
    private var formats: Formats { Formats(locale: locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppIconImage(size: 26)
                Text(verbatim: "Sideboard").font(.headline)
                Spacer()
            }
            Divider()
            if store.entries.isEmpty {
                Text("No devices yet").foregroundStyle(.secondary)
            }
            ForEach(store.entries) { entry in
                Button {
                    store.selection = entry.id
                    open()
                } label: {
                    row(entry)
                }
                .buttonStyle(.plain)
            }
            Divider()
            VStack(spacing: 8) {
                Button {
                    open()
                } label: {
                    Text("Open Sideboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                HStack {
                    SettingsLink { Text("Settings…") }
                    Spacer()
                    Button("Quit Sideboard") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func row(_ entry: DeviceStore.Entry) -> some View {
        let state = monitor.states[entry.id]
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let name = entry.name {
                        Text(verbatim: name)
                    } else {
                        Text("Android device")
                    }
                }
                .fontWeight(.medium)
                .lineLimit(1)
                Group {
                    if entry.state != .online {
                        Text("Not connected")
                    } else if let state {
                        summary(state)
                    } else {
                        Text("Connected")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(entry.state != .online ? Color.gray.opacity(0.5) : state?.isAwake == true ? .green : .secondary)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
        }
        .contentShape(Rectangle())
    }

    private func summary(_ state: Monitor.DeviceState) -> Text {
        var parts: [Text] = []
        switch state.screen {
        case .on:
            if let today = state.screenOnToday {
                parts.append(Text("Screen on · \(formats.duration(today)) today"))
            } else {
                parts.append(Text("Screen on"))
            }
        case .off: parts.append(Text(state.isTV ? "Standby" : "Screen off"))
        case .screensaver: parts.append(Text("Screensaver"))
        case .dozing: parts.append(Text("Dozing"))
        case nil: break
        }
        if let level = state.batteryLevel {
            parts.append(Text(verbatim: formats.percent(Double(level) / 100)))
        }
        if let free = state.storageAvailable {
            parts.append(Text("\(formats.bytes(free)) free"))
        }
        if let level = state.thermalStatus, level >= 2 {
            parts.append(Text("Running hot"))
        }
        return parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) { $0 + Text(verbatim: " · ") + $1 }
    }
}
