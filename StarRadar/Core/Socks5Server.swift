import Foundation
import Darwin

/// SOCKS5 服务端（无鉴权），监听 0.0.0.0:port，供热点里的设备设置代理后接入。
/// 支持 CONNECT(TCP) 与 UDP ASSOCIATE。对应安卓 Socks5Server.kt。
/// 每转发一段数据即以「完整 IP 报文」的语义交给 [onPacket]（上层过滤后 WS 上报）。
final class Socks5Server {

    typealias PacketCallback = (_ up: Bool, _ proto: Int, _ srcIp: String, _ sport: Int,
                                _ dstIp: String, _ dport: Int, _ payload: [UInt8]) -> Void

    private let port: Int
    private let onPacket: PacketCallback
    private let log: (Globals.Level, String) -> Void
    private let onClientActive: (String) -> Void

    private let lock = NSLock()
    private var listenFd: Int32 = -1
    private var running = false
    private var associates: [String: UdpAssociate] = [:]

    init(port: Int,
         onPacket: @escaping PacketCallback,
         log: @escaping (Globals.Level, String) -> Void,
         onClientActive: @escaping (String) -> Void = { _ in }) {
        self.port = port
        self.onPacket = onPacket
        self.log = log
        self.onClientActive = onClientActive
    }

    // MARK: - 启停

    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            log(.err, "SOCKS5 启动失败: socket() \(errnoText())")
            return false
        }
        setNoSigPipe(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = in_addr_t(0)          // 0.0.0.0

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRC != 0 {
            log(.err, "SOCKS5 启动失败: bind :\(port) \(errnoText())")
            Darwin.close(fd)
            return false
        }
        if Darwin.listen(fd, 64) != 0 {
            log(.err, "SOCKS5 启动失败: listen \(errnoText())")
            Darwin.close(fd)
            return false
        }

        lock.lock(); listenFd = fd; running = true; lock.unlock()
        log(.ok, "SOCKS5 已监听 :\(port)（热点设备把代理指向本机 IP:\(port)）")

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "socks-accept"
        t.start()
        return true
    }

    func stop() {
        lock.lock()
        running = false
        let fd = listenFd
        listenFd = -1
        let list = Array(associates.values)
        associates.removeAll()
        lock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for a in list { a.close() }
        log(.info, "SOCKS5 已停止")
    }

    // MARK: - 接入循环

    private func acceptLoop() {
        while isRunning() {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFd, $0, &len)
                }
            }
            if cfd < 0 {
                if isRunning() { continue }
                break
            }
            setNoSigPipe(cfd)
            var one: Int32 = 1
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

            let clientIp = ipv4String(peer.sin_addr)
            let t = Thread { [weak self] in self?.handleClient(cfd, clientIp: clientIp) }
            t.name = "socks-client"
            t.start()
        }
    }

    // MARK: - SOCKS5 会话

    private func handleClient(_ cfd: Int32, clientIp: String) {
        defer { Darwin.close(cfd) }

        // ---- 方法协商（无鉴权） ----
        guard let greet = readExact(cfd, 2) else { return }
        let nm = Int(greet[1])
        if nm <= 0 { return }
        guard readExact(cfd, nm) != nil else { return }
        guard writeAll(cfd, [5, 0]) else { return }

        // ---- 请求 ----
        guard let req = readExact(cfd, 4) else { return }
        let cmd = Int(req[1])
        let atyp = Int(req[3])
        guard let host = readSocksAddr(cfd, atyp) else { return }
        guard let portBuf = readExact(cfd, 2) else { return }
        let dstPort = (Int(portBuf[0]) << 8) | Int(portBuf[1])

        onClientActive(clientIp)

        switch cmd {
        case 1: handleConnect(cfd, clientIp: clientIp, host: host, dstPort: dstPort)
        case 3: handleUdpAssociate(cfd, clientIp: clientIp)
        default: return
        }
    }

    private func handleConnect(_ cfd: Int32, clientIp: String, host: String, dstPort: Int) {
        guard let target = connectTCP(host, dstPort) else {
            log(.warn, "TCP CONNECT 目标失败 \(host):\(dstPort) \(errnoText())")
            _ = writeAll(cfd, [5, 1, 0, 1, 0, 0, 0, 0, 0, 0])
            return
        }
        guard writeAll(cfd, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]) else {
            Darwin.close(target.fd)
            return
        }
        let clientPort = peerPort(cfd)

        // ---- 双向泵送（各占一线程循环转发 + 统计） ----
        let g = DispatchGroup()
        let up = Thread { [weak self] in
            self?.pumpLoop(cfd, target.fd) { payload in
                self?.onPacket(true, IpPacket.protoTCP, clientIp, clientPort,
                               target.ip, dstPort, payload)
            }
            Darwin.shutdown(target.fd, SHUT_WR)
            g.leave()
        }
        up.name = "socks-up"
        let down = Thread { [weak self] in
            self?.pumpLoop(target.fd, cfd) { payload in
                self?.onPacket(false, IpPacket.protoTCP, target.ip, dstPort,
                               clientIp, clientPort, payload)
            }
            Darwin.shutdown(cfd, SHUT_WR)
            g.leave()
        }
        down.name = "socks-down"
        g.enter(); g.enter()
        up.start(); down.start()
        _ = g.wait(timeout: .distantFuture)
        Darwin.close(target.fd)
    }

    /// 循环读一块转一块；对端关闭/异常时返回。
    private func pumpLoop(_ from: Int32, _ to: Int32, onChunk: ([UInt8]) -> Void) {
        var buf = [UInt8](repeating: 0, count: 16384)
        let cap = buf.count
        while true {
            let n = buf.withUnsafeMutableBytes { p in
                Darwin.read(from, p.baseAddress, cap)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 { return }
            let chunk = Array(buf[0..<n])
            onChunk(chunk)
            if !writeAll(to, chunk) { return }
        }
    }

    // MARK: - UDP ASSOCIATE

    private func handleUdpAssociate(_ cfd: Int32, clientIp: String) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        if sock < 0 { return }
        setNoSigPipe(sock)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr.s_addr = in_addr_t(0)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { Darwin.close(sock); return }

        // 1s 接收超时：让接收循环能及时响应 stop
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var big: Int32 = 65536
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))

        let localUdpPort = boundPort(sock)
        guard writeAll(cfd, [5, 0, 0, 1, 0, 0, 0, 0,
                             UInt8((localUdpPort >> 8) & 0xFF), UInt8(localUdpPort & 0xFF)]) else {
            Darwin.close(sock)
            return
        }

        let assoc = UdpAssociate(server: sock, clientIp: clientIp, server_: self)
        let key = "\(clientIp):\(peerPort(cfd))"
        lock.lock(); associates[key] = assoc; lock.unlock()
        log(.ok, "UDP ASSOCIATE 建立 <- \(clientIp) (本地UDP端口 \(localUdpPort))")
        assoc.start()

        // 阻塞直到 TCP 控制连接断开（客户端在 associate 期间保持该 TCP 连接）
        while isRunning() {
            let r = readSome(cfd, 1)
            if r == nil { break }
        }
        assoc.close()
        lock.lock(); associates.removeValue(forKey: key); lock.unlock()
    }

    /// 单个 UDP ASSOCIATE：从客户端收 SOCKS UDP 封装 → 转发目标 → 回包封装回客户端。
    /// 注意：客户端的实际 UDP 源端口 ≠ TCP 控制连接端口，因此只按 IP 校验来源；
    /// 回包发给每个数据报的实际源地址（lastClient）。
    final class UdpAssociate {
        private let server: Int32
        private let clientIp: String
        private weak var owner: Socks5Server?

        private let lock = NSLock()
        private var closed = false
        private var lastClient: sockaddr_in?
        private var relays: [String: Int32] = [:]

        fileprivate init(server: Int32, clientIp: String, server_: Socks5Server) {
            self.server = server
            self.clientIp = clientIp
            self.owner = server_
        }

        fileprivate func start() {
            let t = Thread { [weak self] in self?.run() }
            t.name = "socks-udp-assoc"
            t.start()
        }

        fileprivate func close() {
            lock.lock()
            closed = true
            let list = Array(relays.values)
            relays.removeAll()
            lock.unlock()
            Darwin.shutdown(server, SHUT_RDWR)
            Darwin.close(server)
            for fd in list {
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }

        private func isClosed() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return closed
        }

        private func run() {
            var buf = [UInt8](repeating: 0, count: 65535)
            let cap = buf.count
            while !isClosed() {
                var from = sockaddr_in()
                var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = buf.withUnsafeMutableBytes { p -> Int in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.recvfrom(server, p.baseAddress, cap, 0, sa, &flen)
                        }
                    }
                }
                if n < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                    break
                }
                if n == 0 { continue }

                let fromIp = owner?.ipv4String(from.sin_addr) ?? ""
                if fromIp != clientIp { continue }         // 只按 IP 校验来源
                let fromPort = Int(UInt16(bigEndian: from.sin_port))
                lock.lock()
                lastClient = from
                lock.unlock()

                let data = Array(buf[0..<n])
                guard data.count >= 4, data[2] == 0 else { continue }   // 不支持分片
                guard let target = owner?.parseSocksUdpHeader(data, from: 3) else { continue }
                // 目标是域名时先解析成 IPv4（上报的 IP 报文必须带真实地址）
                guard let targetIp = owner?.resolveIPv4(target.ip) else { continue }
                let payload = Array(data[target.nextOffset..<data.count])
                if payload.isEmpty { continue }

                owner?.onPacket(true, IpPacket.protoUDP, clientIp, fromPort,
                                targetIp, target.port, payload)

                guard let relay = relaySocket(targetIp, target.port) else { continue }
                var dst = sockaddr_in()
                dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                dst.sin_family = sa_family_t(AF_INET)
                dst.sin_port = in_port_t(UInt16(target.port).bigEndian)
                _ = owner?.fillIPv4(&dst.sin_addr, targetIp)
                payload.withUnsafeBytes { p in
                    withUnsafePointer(to: &dst) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            _ = Darwin.sendto(relay, p.baseAddress, payload.count, 0, sa,
                                              socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }

        /// 取（或新建）指向目标的 relay socket，并为它起一条回包线程
        private func relaySocket(_ ip: String, _ port: Int) -> Int32? {
            let key = "\(ip):\(port)"
            lock.lock()
            if let fd = relays[key] { lock.unlock(); return fd }
            lock.unlock()

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            if fd < 0 { return nil }
            owner?.setNoSigPipe(fd)
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var big: Int32 = 65536
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            relays[key] = fd
            lock.unlock()
            startReplyLoop(fd, targetPort: port, targetIp: ip)
            return fd
        }

        private func startReplyLoop(_ fd: Int32, targetPort: Int, targetIp: String) {
            let t = Thread { [weak self] in
                guard let self else { return }
                var buf = [UInt8](repeating: 0, count: 65535)
                let cap = buf.count
                while !self.isClosed() {
                    var from = sockaddr_in()
                    var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = buf.withUnsafeMutableBytes { p -> Int in
                        withUnsafeMutablePointer(to: &from) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                Darwin.recvfrom(fd, p.baseAddress, cap, 0, sa, &flen)
                            }
                        }
                    }
                    if n < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                            continue
                        }
                        break
                    }
                    if n == 0 { continue }

                    let payload = Array(buf[0..<n])
                    var realIp = [UInt8](repeating: 0, count: 4)
                    _ = withUnsafeBytes(of: from.sin_addr.s_addr) { raw in
                        for i in 0..<4 { realIp[i] = raw[i] }
                    }
                    self.lock.lock()
                    let replyTo = self.lastClient
                    self.lock.unlock()
                    guard let replyTo = replyTo else { continue }

                    // 回包封装：RSV=0 FRAG=0 ATYP=1 + 目标真实IP:端口 + 数据
                    var head = [UInt8](repeating: 0, count: 10)
                    head[2] = 0
                    head[3] = 1
                    for i in 0..<4 { head[4 + i] = realIp[i] }
                    head[8] = UInt8((targetPort >> 8) & 0xFF)
                    head[9] = UInt8(targetPort & 0xFF)
                    let reply = head + payload

                    let toPort = Int(UInt16(bigEndian: replyTo.sin_port))
                    self.owner?.onPacket(false, IpPacket.protoUDP, targetIp, targetPort,
                                         self.clientIp, toPort, payload)

                    var dst = replyTo
                    reply.withUnsafeBytes { p in
                        withUnsafePointer(to: &dst) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                _ = Darwin.sendto(self.server, p.baseAddress, reply.count, 0, sa,
                                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            t.name = "socks-udp-reply"
            t.start()
        }
    }

    // MARK: - 辅助

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func errnoText() -> String { String(cString: strerror(errno)) }

    /// 新建到目标的 TCP 连接，返回 (fd, 解析后的点分 IP)
    private func connectTCP(_ host: String, _ port: Int) -> (fd: Int32, ip: String)? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return nil }
        setNoSigPipe(fd)
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))

        if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            Darwin.close(fd)
            return nil
        }
        var ip = host
        if info.pointee.ai_family == AF_INET {
            let sa = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            ip = ipv4String(sa.sin_addr)
        }
        return (fd, ip)
    }

    /// 解析 SOCKS5 UDP 请求头里的地址，返回目标与载荷起始偏移
    private func parseSocksUdpHeader(_ data: [UInt8], from o: Int) -> (ip: String, port: Int, nextOffset: Int)? {
        guard o < data.count else { return nil }
        var off = o
        let ip: String
        switch data[off] {
        case 1:
            guard off + 4 < data.count else { return nil }
            ip = IpPacket.ipv4String(data, off + 1)
            off += 5
        case 3:
            guard off + 1 < data.count else { return nil }
            let len = Int(data[off + 1])
            guard off + 2 + len <= data.count else { return nil }
            ip = String(bytes: data[(off + 2)..<(off + 2 + len)], encoding: .utf8) ?? ""
            off += 2 + len
        case 4:
            // 回包/转发仅支持 IPv4 目标
            return nil
        default:
            return nil
        }
        guard off + 1 < data.count else { return nil }
        let port = (Int(data[off]) << 8) | Int(data[off + 1])
        return (ip, port, off + 2)
    }

    private func fillIPv4(_ dst: inout in_addr, _ ip: String) -> Bool {
        inet_pton(AF_INET, ip, &dst) == 1
    }

    /// 域名 → IPv4 点分；已是 IP 则原样返回
    private func resolveIPv4(_ host: String) -> String? {
        var a = in_addr()
        if inet_pton(AF_INET, host, &a) == 1 { return host }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = info.pointee.ai_addr else { return nil }
        let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        return ipv4String(sin.sin_addr)
    }

    private func ipv4String(_ a: in_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addr = a
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "0.0.0.0" }
        return String(cString: buf)
    }

    /// 取已绑定 socket 的实际端口
    private func boundPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard rc == 0 else { return 0 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// 取对端（客户端）端口，用作报文的源端口
    private func peerPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &len)
            }
        }
        guard rc == 0 else { return 0 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private func readExact(_ fd: Int32, _ n: Int) -> [UInt8]? {
        if n <= 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { p in
                Darwin.read(fd, p.baseAddress!.advanced(by: got), n - got)
            }
            if r < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if r == 0 { return nil }
            got += r
        }
        return buf
    }

    /// 读若干字节，返回 nil 表示对端关闭或出错
    private func readSome(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n)
        while true {
            let r = buf.withUnsafeMutableBytes { p in
                Darwin.read(fd, p.baseAddress, n)
            }
            if r < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if r == 0 { return nil }
            return Array(buf[0..<r])
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let w = bytes.withUnsafeBytes { p in
                Darwin.write(fd, p.baseAddress!.advanced(by: off), bytes.count - off)
            }
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            if w == 0 { return false }
            off += w
        }
        return true
    }

    private func readSocksAddr(_ fd: Int32, _ atyp: Int) -> String? {
        switch atyp {
        case 1:
            guard let b = readExact(fd, 4) else { return nil }
            return IpPacket.ipv4String(b, 0)
        case 3:
            guard let l = readExact(fd, 1) else { return nil }
            let len = Int(l[0])
            guard let name = readExact(fd, len) else { return nil }
            return String(bytes: name, encoding: .utf8)
        case 4:
            guard let b = readExact(fd, 16) else { return nil }
            var a = in_addr()
            withUnsafeMutableBytes(of: &a.s_addr) { raw in
                for i in 0..<4 { raw[i] = b[12 + i] }
            }
            return ipv4String(a)
        default:
            return nil
        }
    }
}
