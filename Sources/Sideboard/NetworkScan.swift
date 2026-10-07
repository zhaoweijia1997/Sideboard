import Foundation
import Network

/// Finds devices with network debugging on: anything on this Mac's local networks that
/// accepts a connection on adb's port. Only opens and closes a connection; sends nothing.
enum NetworkScan {
    static let port: UInt16 = 5555

    /// Hosts on the same /24 as each of this Mac's private IPv4 addresses (wired, Wi-Fi).
    static func candidates() -> [String] {
        var hosts: [String] = []
        for address in localAddresses() {
            let parts = address.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            hosts += (1...254).map { "\(prefix).\($0)" }.filter { $0 != address }
        }
        return hosts
    }

    static func localAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            if isPrivate(text) { result.append(text) }
        }
        return Array(Set(result)).sorted()
    }

    /// Only scans home and office networks, never public addresses.
    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    /// Addresses (host:port) that answered, in address order.
    static func scan() async -> [String] {
        let hosts = candidates()
        var found: [String] = []
        // A few dozen at a time, so a home router isn't flooded.
        for batch in stride(from: 0, to: hosts.count, by: 64).map({ Array(hosts[$0..<min($0 + 64, hosts.count)]) }) {
            await withTaskGroup(of: String?.self) { group in
                for host in batch {
                    group.addTask { await isOpen(host) ? host : nil }
                }
                for await host in group {
                    if let host { found.append("\(host):\(port)") }
                }
            }
        }
        return found.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    static func isOpen(_ host: String, timeout: TimeInterval = 1.2) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "sideboard.scan")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let probe = Probe()
            let finish: @Sendable (Bool) -> Void = { open in
                // Only called on `queue`, so `probe` needs no lock.
                guard !probe.finished else { return }
                probe.finished = true
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private final class Probe: @unchecked Sendable {
        var finished = false
    }
}
