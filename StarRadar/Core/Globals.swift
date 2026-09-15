import Foundation
import Combine
import Darwin

/// 运行状态 + 环形日志（对应安卓 Globals.kt）
final class Globals: ObservableObject, @unchecked Sendable {
    static let shared = Globals()

    enum Level {
        case info, ok, warn, err
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let at: Date
        let level: Level
        let msg: String
    }

    // MARK: - 运行状态

    @Published var running = false
    @Published var wsState = "未连接"
    @Published var latMs: Int64 = -1
    @Published var localIp = "—"
    @Published var listenPort = 1080
    @Published var roomKey = ""

    // MARK: - 统计

    @Published var upPackets: Int64 = 0
    @Published var downPackets: Int64 = 0
    @Published var sentPackets: Int64 = 0
    @Published var upBytes: Int64 = 0
    @Published var downBytes: Int64 = 0
    @Published var droppedPackets: Int64 = 0
    @Published var reconnects: Int64 = 0
    @Published var queueSize = 0
    /// 断线重连后成功续发的补包数
    @Published var resent: Int64 = 0
    /// 待补发积压：队首连续「代次落后于当前连接」的报文数
    @Published var replay: Int64 = 0
    /// 被会话流过滤丢弃的报文数（TCP / 内网远端 / 未命中握手签名）
    @Published var filteredPackets: Int64 = 0

    // MARK: - 订阅节点 / 日志

    @Published var nodes: [String] = []
    /// 当前用于上报/测速的节点 IP
    @Published var selectedHost = ""
    @Published var lines: [LogLine] = []

    private let maxLog = 400
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: - 日志

    func log(_ level: Level, _ msg: String) {
        lines.append(LogLine(at: Date(), level: level, msg: msg))
        if lines.count > maxLog {
            lines.removeFirst(lines.count - maxLog)
        }
    }

    func log(_ msg: String) { log(.info, msg) }

    func tail(_ n: Int) -> [LogLine] {
        lines.count <= n ? lines : Array(lines.suffix(n))
    }

    func clearLog() { lines.removeAll() }

    // MARK: - 统计复位

    func resetStats() {
        upPackets = 0
        downPackets = 0
        sentPackets = 0
        upBytes = 0
        downBytes = 0
        droppedPackets = 0
        reconnects = 0
        queueSize = 0
        resent = 0
        replay = 0
        filteredPackets = 0
    }

    // MARK: - 延迟文案

    func latLabel() -> String {
        if latMs < 0 { return "离线" }
        if latMs < 1000 { return "\(latMs)ms" }
        return String(format: "%.1fs", Double(latMs) / 1000.0)
    }

    // MARK: - 配置持久化

    func loadConfig() {
        let saved = defaults.string(forKey: "nodes") ?? ""
        let list = saved.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        nodes = list.isEmpty ? ["192.140.179.181"] : list

        let savedHost = defaults.string(forKey: "selected_host") ?? ""
        selectedHost = nodes.contains(savedHost) ? savedHost : (nodes.first ?? "")

        roomKey = defaults.string(forKey: "room_key") ?? ""

        let p = defaults.integer(forKey: "port")
        listenPort = (p >= 1 && p <= 65535) ? p : 1080
    }

    func saveConfig() {
        defaults.set(nodes.joined(separator: ","), forKey: "nodes")
        defaults.set(selectedHost, forKey: "selected_host")
        defaults.set(roomKey, forKey: "room_key")
        defaults.set(listenPort, forKey: "port")
    }

    // MARK: - 内网 IPv4

    static func findLocalIp() -> String {
        var result = "—"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr else { continue }
            let family = sa.pointee.sa_family
            let flags = Int32(cur.pointee.ifa_flags)
            guard family == UInt8(AF_INET),
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                return ip
            }
            if result == "—" { result = ip }
        }
        return result
    }
}
