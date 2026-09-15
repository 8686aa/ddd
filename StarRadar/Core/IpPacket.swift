import Foundation
import Darwin

/// 把 SOCKS5 通道上捕获的一段数据（五元组 + 载荷）封装成「完整 IPv4 报文」，
/// 与转发器 WsMirrorServer / IpPacketParser 的解析格式完全一致：
///   [IPv4头][TCP头|UDP头][载荷]
/// 转发器据此读出 src/dst/端口/协议号/载荷后封装为 TZSP 镜像给解码器。
/// 对应安卓 IpPacket.kt。
enum IpPacket {

    static let protoTCP = 6
    static let protoUDP = 17
    /// 单包载荷上限（贴合 MTU，避免 TZSP 帧超大）
    private static let maxPayload = 1400

    /// 封装一段载荷为 IPv4 报文；若载荷超长自动截断为 maxPayload。
    static func wrap(proto: Int, srcIp: String, dstIp: String,
                     sport: Int, dport: Int, payload: [UInt8]) -> [UInt8] {
        let pl = payload.count > maxPayload ? Array(payload[0..<maxPayload]) : payload
        let transHead = proto == protoTCP ? 20 : 8          // TCP 20B / UDP 8B
        let total = 20 + transHead + pl.count
        var buf = [UInt8](repeating: 0, count: total)

        // ---- IPv4 头 ----
        buf[0] = 0x45                                       // v4 + IHL=5
        put16(&buf, 2, total)                               // total length
        put16(&buf, 4, 0x4711)                              // identification
        put16(&buf, 6, 0)                                   // flags/frag
        buf[8] = 64                                         // TTL
        buf[9] = UInt8(proto & 0xFF)
        put16(&buf, 10, 0)                                  // checksum（回填）
        let s = ipv4Bytes(srcIp)
        let d = ipv4Bytes(dstIp)
        for i in 0..<4 { buf[12 + i] = s[i] }
        for i in 0..<4 { buf[16 + i] = d[i] }

        // ---- 传输层头 ----
        put16(&buf, 20, sport)
        put16(&buf, 22, dport)
        if proto == protoTCP {
            buf[20 + 12] = 0x50                             // data offset = 5
            buf[20 + 13] = 0x10                             // ACK
        } else {
            put16(&buf, 24, 8 + pl.count)                   // UDP length
        }

        for i in 0..<pl.count { buf[20 + transHead + i] = pl[i] }

        // ---- 校验和 ----
        put16(&buf, 10, checksum(buf, 0, 20))
        return buf
    }

    /// 点分十进制 IPv4 → 4 字节网络序；非法地址退化为 0.0.0.0
    static func ipv4Bytes(_ ip: String) -> [UInt8] {
        var a = in_addr()
        if inet_pton(AF_INET, ip, &a) == 1 {
            return withUnsafeBytes(of: a.s_addr) { Array($0) }
        }
        return [0, 0, 0, 0]
    }

    /// 4 字节网络序 → 点分十进制
    static func ipv4String(_ b: [UInt8], _ off: Int) -> String {
        "\(b[off]).\(b[off + 1]).\(b[off + 2]).\(b[off + 3])"
    }

    private static func checksum(_ data: [UInt8], _ off: Int, _ len: Int) -> Int {
        var sum = 0
        var i = off
        let end = off + len
        while i < end - 1 {
            sum += (Int(data[i]) & 0xFF) << 8 | (Int(data[i + 1]) & 0xFF)
            i += 2
        }
        if i < end { sum += (Int(data[i]) & 0xFF) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return (~sum) & 0xFFFF
    }

    private static func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        b[off] = UInt8((v >> 8) & 0xFF)
        b[off + 1] = UInt8(v & 0xFF)
    }
}
