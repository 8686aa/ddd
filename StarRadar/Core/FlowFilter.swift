import Foundation

/// 会话流过滤器（固定开启，不下发开关，规则与桌面版 capture.go 一致，对应安卓 FlowFilter.kt）：
///   1) TCP 一律不上报：对局数据是 UDP，HTTP/HTTPS 等 TCP 报文对解码器无用；
///   2) 远端为内网/回环/广播的 UDP 不上报：局域网互访、投屏与对局无关；
///   3) 其余 UDP 必须**按序命中**握手长度签名才认定为会话流：命中前只缓冲，
///      命中瞬间把缓冲报文按到达顺序整段补发，之后该流全部直发。
/// 签名只存在于引擎内部，不打印、不显示。
///
/// 线程模型：SOCKS5 的多个会话线程并发调用，内部用 lock 串行化。
final class FlowFilter {

    private final class Gate {
        var matched = 0
        var live = false
        var lastSeen = Date()
        var pending: [[UInt8]] = []
    }

    /// 握手长度签名：(是否上行, UDP 载荷长度)
    private let hsUp = [true, false, true, false, true, false, false]
    private let hsLen = [33, 25, 33, 25, 35, 31, 10]

    private let probeLimit = 64
    private let maxFlows = 1024
    private let idleSeconds: TimeInterval = 60

    private let lock = NSLock()
    private var gates: [String: Gate] = [:]

    /// 被过滤丢弃的报文数（仅在锁内累加，由引擎每秒同步到 Globals）
    private var filtered = 0
    var filteredCount: Int {
        lock.lock(); defer { lock.unlock() }
        return filtered
    }

    /// 判定一条报文是否上报。
    ///
    /// 入参是报文的原始 src/dst（上行时 src=客户端、下行时 src=远端），
    /// 内部先按 up 归一化出「客户端侧」与「远端侧」再判定，
    /// 与桌面版 key = phone|localPort|remote|port 的固定方向一致。
    ///
    /// - Returns: 需要上报的报文列表（可能含命中瞬间按序补发的缓冲包）；空表示丢弃
    func accept(up: Bool, proto: Int,
                srcIp: String, srcPort: Int,
                dstIp: String, dstPort: Int,
                payloadLen: Int, packet: [UInt8]) -> [[UInt8]] {
        if proto != IpPacket.protoUDP {
            lock.lock(); filtered += 1; lock.unlock()
            return []
        }

        // 方向归一化：上下行都必须落到同一条流、同一个远端，否则签名按序命中永远错位
        let clientIp = up ? srcIp : dstIp
        let clientPort = up ? srcPort : dstPort
        let remoteIp = up ? dstIp : srcIp
        let remotePort = up ? dstPort : srcPort

        if isPrivate(remoteIp) {
            lock.lock(); filtered += 1; lock.unlock()
            return []
        }

        let key = "\(clientIp)|\(clientPort)|\(remoteIp)|\(remotePort)"
        let now = Date()

        lock.lock(); defer { lock.unlock() }

        var gate: Gate
        if let exist = gates[key] {
            gate = exist
        } else {
            // 只在出现签名首包长度时才开始跟踪，避免给随机 UDP 流分配缓冲
            if payloadLen != hsLen[0] {
                filtered += 1
                return []
            }
            if gates.count >= maxFlows {
                evictIdleLocked(now)
                if gates.count >= maxFlows {
                    filtered += 1
                    return []
                }
            }
            gate = Gate()
            gates[key] = gate
        }
        gate.lastSeen = now

        // 已认定：之后该流全部直发
        if gate.live { return [packet] }

        if gate.matched < hsLen.count &&
            up == hsUp[gate.matched] && payloadLen == hsLen[gate.matched] {
            gate.matched += 1
            gate.pending.append(packet)
            if gate.matched == hsLen.count {
                // 命中：整段按到达顺序补发
                gate.live = true
                let buffered = gate.pending
                gate.pending.removeAll()
                DispatchQueue.main.async {
                    Globals.shared.log(.ok, "[filter] 识别会话流 \(remoteIp):\(remotePort)")
                }
                return buffered
            }
            return []
        }

        // 乱序/重传容错：按有序子序列继续探测；缓冲超限即判定为非会话流并放弃该流
        gate.pending.append(packet)
        if gate.pending.count >= probeLimit {
            filtered += gate.pending.count
            gates.removeValue(forKey: key)
        }
        return []
    }

    /// 清空流表（停止监听时调用）
    func clear() {
        lock.lock(); defer { lock.unlock() }
        gates.removeAll()
        filtered = 0
    }

    private func evictIdleLocked(_ now: Date) {
        let stale = gates.filter { now.timeIntervalSince($0.value.lastSeen) > idleSeconds }.map { $0.key }
        for k in stale { gates.removeValue(forKey: k) }
    }

    /// 内网/回环/链路本地地址判定（对局服务器均为公网）
    private func isPrivate(_ ip: String) -> Bool {
        if ip.isEmpty { return false }
        if ip.contains(":") {
            let low = ip.lowercased()
            return low == "::1" || low.hasPrefix("fe80") ||
                low.hasPrefix("fc") || low.hasPrefix("fd") ||
                low == "::" || low.hasPrefix("ff")
        }
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        switch a {
        case 10: return true
        case 172: return (16...31).contains(b)
        case 192: return b == 168
        case 169: return b == 254
        case 127: return true
        case 255: return true
        case 0: return true
        default: return (224...239).contains(a)
        }
    }
}
