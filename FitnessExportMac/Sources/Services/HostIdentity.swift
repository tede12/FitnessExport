import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import Network

struct HostIdentity: Sendable {
    let hostName: String

    init(hostName: String = ProcessInfo.processInfo.hostName) {

        self.hostName = hostName.hasSuffix(".local") ? String(hostName.dropLast(6)) : hostName
    }

    static func reachableHost(fallback: String) -> String {
        if let tailscale = TailscaleCLI.ipv4() { return tailscale }
        if let lan = localIPv4() { return lan }
        return fallback
    }

    static func localIPv4() -> String? {
        var address: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let flags = Int32(interface.pointee.ifa_flags)
            let family = interface.pointee.ifa_addr?.pointee.sa_family
            let name = String(cString: interface.pointee.ifa_name)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            if isUp, !isLoopback, family == UInt8(AF_INET),
                name.hasPrefix("en") || name.hasPrefix("bridge")
            {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    interface.pointee.ifa_addr,
                    socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    let candidate = String(cString: host)
                    if !candidate.isEmpty, address == nil { address = candidate }
                }
            }
            current = interface.pointee.ifa_next
        }
        return address
    }
}

enum TailscaleCLI {
    private static let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    static func ipv4() -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if let ip = run(path, ["ip", "-4"]), ip.hasPrefix("100.") {
                return ip
            }
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

enum QRCode {
    static func nsImage(from string: String, scale: CGFloat = 10) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard
            let output = filter.outputImage?.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )
        else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
