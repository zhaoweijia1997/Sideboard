import SwiftUI

/// Connect to a device on the network: by address, by scanning, or by pairing (Android 11+).
struct AddDeviceView: View {
    let store: DeviceStore
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var problem: Adb.ConnectResult?
    @State private var connecting = false
    @State private var scanning = false
    @State private var found: [String]?
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var pairing = false
    @State private var pairResult: String??

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Device").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("IP address").font(.headline)
                HStack {
                    TextField(text: $address, prompt: Text(verbatim: "192.168.1.42")) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { connect(address) }
                    Button("Connect") { connect(address) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                }
                Text("Port 5555 is used unless you add another, as in 192.168.1.42:37000.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if connecting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting…").foregroundStyle(.secondary)
                    }
                } else if let problem {
                    ConnectProblemText(problem: problem)
                    if problem == .unreachable {
                        Button("Restart adb") { Task { await store.restartAdb() } }
                            .disabled(store.restartingAdb)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Find on this network").font(.headline)
                    Spacer()
                    Button {
                        scan()
                    } label: {
                        if scanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Scan")
                        }
                    }
                    .disabled(scanning)
                }
                Text("Looks for devices with network debugging turned on. Takes a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let found {
                    if found.isEmpty {
                        Text("None found. Make sure network debugging is on and the device is on the same network.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(found, id: \.self) { candidate in
                        HStack {
                            Image(systemName: "network")
                            Text(verbatim: candidate)
                            Spacer()
                            Button("Connect") { connect(candidate) }
                                .disabled(connecting)
                        }
                    }
                }
            }

            Divider()

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the phone, open Developer options → Wireless debugging → Pair device with pairing code, then enter the address and code it shows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField(text: $pairAddress, prompt: Text(verbatim: "192.168.1.50:41234")) { EmptyView() }
                            .textFieldStyle(.roundedBorder)
                        TextField(text: $pairCode, prompt: Text(verbatim: "123456")) { EmptyView() }
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("Pair") { pair() }
                            .disabled(pairAddress.isEmpty || pairCode.isEmpty || pairing)
                    }
                    if pairing {
                        ProgressView().controlSize(.small)
                    } else if let pairResult {
                        if let failure = pairResult {
                            Text("Couldn't pair: \(failure)").font(.callout).foregroundStyle(.orange)
                        } else {
                            Text("Paired. Usually it connects by itself in a moment; if not, enter the IP address and port shown under Wireless debugging above.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Phone or tablet with Wireless debugging (Android 11 and later)")
            }

            DisclosureGroup {
                EnableDebuggingSteps().padding(.top, 6)
            } label: {
                Text("How to turn on debugging")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private func connect(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        connecting = true
        problem = nil
        Task {
            let result = await store.connect(input)
            connecting = false
            if result == .connected || result == .needsApproval {
                dismiss()
            } else {
                problem = result
            }
        }
    }

    private func scan() {
        scanning = true
        Task {
            found = await store.scan()
            scanning = false
        }
    }

    private func pair() {
        pairing = true
        Task {
            pairResult = .some(await store.pair(pairAddress, code: pairCode))
            pairing = false
        }
    }
}
