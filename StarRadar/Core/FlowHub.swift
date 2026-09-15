import Foundation

/// 运行期链路快照（对应安卓 FlowHub.kt）。
/// 采集线程（SOCKS5 泵送线程）写入，界面每秒读一次：
///  · 内环客户端 = 连接本机 SOCKS5 的热点设备
///  · 外环远端   = 客户端实际访问的目标
///  · 待展示报文 = 限量缓存，界面每次限速取走一批，避免刷爆列表
final class FlowHub {

    static let shared = FlowHub()

    private let maxPending = 400
    private let clientLinger: TimeInterval = 60      // 客户端离线后仍在星图上保留一会儿
    private let remoteLinger: TimeInterval = 8

    private let lock = NSLock()
    private var clients: [String: Date] = [:]
    private var remotes: [String: Date] = [:]
    private var pending: [PktInfo] = []

    private init() {}

    /// 客户端完成 SOCKS5 协商（还没转发数据也算在线）
    func touchClient(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        clients[ip] = Date()
    }

    /// 每转发一段数据调用一次：登记链路两端并把报文排进展示队列
    func report(up: Bool, proto: Int, srcIp: String, sport: Int,
                dstIp: String, dport: Int, len: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        clients[up ? srcIp : dstIp] = now
        remotes[up ? dstIp : srcIp] = now

        if pending.count >= maxPending { pending.removeFirst() }
        pending.append(PktInfo(time: now,
                               up: up,
                               srcIp: srcIp,
                               srcPort: sport,
                               dstIp: dstIp,
                               dstPort: dport,
                               proto: proto == IpPacket.protoTCP ? "TCP" : "UDP",
                               len: len,
                               target: false))
    }

    func clientIps() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return aliveLocked(&clients, linger: clientLinger)
    }

    func remoteIps() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return aliveLocked(&remotes, linger: remoteLinger)
    }

    /// 取走最多 max 条待展示报文
    func drain(_ max: Int) -> [PktInfo] {
        lock.lock(); defer { lock.unlock() }
        let n = min(max, pending.count)
        guard n > 0 else { return [] }
        let out = Array(pending[0..<n])
        pending.removeFirst(n)
        return out
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        clients.removeAll()
        remotes.removeAll()
        pending.removeAll()
    }

    /// 调用方须已持锁
    private func aliveLocked(_ map: inout [String: Date], linger: TimeInterval) -> [String] {
        let now = Date()
        let stale = map.filter { now.timeIntervalSince($0.value) > linger }.map { $0.key }
        for k in stale { map.removeValue(forKey: k) }
        return map.keys.sorted()
    }
}
