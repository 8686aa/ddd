import Foundation
import SwiftUI
import AVFoundation

/// 报文流行缓冲
final class PacketFeed: ObservableObject {
    @Published private(set) var rows: [PktInfo] = []
    private let maxRows = 60

    func push(_ p: PktInfo) {
        rows.insert(p, at: 0)
        if rows.count > maxRows { rows.removeLast(rows.count - maxRows) }
    }

    func clear() { rows.removeAll() }
}

/// 后台保活：播放静音音频，让 App 在关屏/切后台后继续跑采集与上报。
/// 需配合 Info.plist 的 UIBackgroundModes = audio（普通后台任务做不到长时间常驻）。
final class BackgroundKeeper {

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return }
            buf.frameLength = 44100                     // 全 0 → 静音
            e.connect(p, to: e.mainMixerNode, format: fmt)
            try e.start()
            p.scheduleBuffer(buf, at: nil, options: .loops)
            p.play()
            engine = e
            player = p
        } catch {
            engine = nil
            player = nil
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                        options: .notifyOthersOnDeactivation)
    }
}

/// 采集主编排（对应安卓 SniffService + MainActivity 的取样逻辑）：
///  · SOCKS5（[Socks5Server]）接住热点设备的代理流量，每段数据封装成 IP 报文；
///  · [FlowFilter] 只放行命中握手签名的会话流；
///  · [WsUploader] 批量上报并在断线重连后按原序补发；
///  · 每秒在主线程把链路快照写进 [Globals]，供界面读取。
final class SniffEngine: @unchecked Sendable {

    static let shared = SniffEngine()

    let radar = RadarModel()
    let wave = WaveModel()
    let feed = PacketFeed()

    private let filter = FlowFilter()
    private let keeper = BackgroundKeeper()

    private var server: Socks5Server?
    private var uploader: WsUploader?

    private let lock = NSLock()
    private var upPackets = 0
    private var downPackets = 0
    private var upBytes = 0
    private var downBytes = 0

    private var timer: Timer?
    private var ticks = 0
    private var lastUpBytes: Int64 = 0
    private var lastDownBytes: Int64 = 0
    private var probing = false

    private let rowsPerTick = 12        // 报文流限速，避免刷爆列表
    private let wsPort = 1082

    private init() {}

    // MARK: - 生命周期

    func boot() {
        let g = Globals.shared
        g.loadConfig()
        g.localIp = Globals.findLocalIp()
        g.log(.info, "本机内网地址 \(g.localIp)")
        g.log(.info, "热点设备把代理指向本机 IP:\(g.listenPort) 后开始上报")

        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func startListening(port: Int, roomKey: String) {
        let g = Globals.shared
        teardown()

        g.resetStats()
        g.listenPort = port
        g.roomKey = roomKey
        g.saveConfig()

        lock.lock()
        upPackets = 0; downPackets = 0; upBytes = 0; downBytes = 0
        lock.unlock()
        lastUpBytes = 0
        lastDownBytes = 0

        FlowHub.shared.clear()
        feed.clear()
        wave.reset()
        radar.clear()
        radar.live = true

        g.running = true
        g.wsState = "重连中…"

        let host = g.selectedHost.isEmpty ? (g.nodes.first ?? "127.0.0.1") : g.selectedHost
        let wsUrl = "ws://\(host):\(wsPort)"
        g.log(.ok, "=== 开始监听 ===")
        g.log(.info, "本机 \(g.localIp):\(port)  节点 \(wsUrl)")
        g.log(.info, "热点客户端代理指向本机后，命中会话流的报文按序上报")

        let up = WsUploader(url: wsUrl,
                            apiKey: roomKey,
                            log: { [weak self] level, msg in self?.uiLog(level, msg) },
                            onAuthFailed: { _ in })
        uploader = up
        up.start()

        let srv = Socks5Server(
            port: port,
            onPacket: { [weak self] isUp, proto, srcIp, sport, dstIp, dport, payload in
                self?.handlePacket(isUp, proto, srcIp, sport, dstIp, dport, payload)
            },
            log: { [weak self] level, msg in self?.uiLog(level, msg) },
            onClientActive: { [weak self] ip in
                FlowHub.shared.touchClient(ip)
                self?.uiLog(.ok, "客户端接入 \(ip)")
            })
        server = srv
        if !srv.start() {
            g.log(.err, "端口 \(port) 被占用，监听未启动")
            teardown()
            g.running = false
            g.wsState = "未连接"
            radar.live = false
            return
        }
        keeper.start()
    }

    func stopListening() {
        guard Globals.shared.running else { return }
        teardown()
        let g = Globals.shared
        g.running = false
        g.wsState = "未连接"
        g.latMs = -1
        g.queueSize = 0
        g.replay = 0
        radar.live = false
        radar.clear()
        wave.reset()
        g.log(.info, "=== 已停止监听 ===")
    }

    private func teardown() {
        uploader?.stop()
        uploader = nil
        server?.stop()
        server = nil
        filter.clear()
        FlowHub.shared.clear()
        keeper.stop()
    }

    // MARK: - 采集回调（SOCKS5 会话线程）

    private func handlePacket(_ up: Bool, _ proto: Int, _ srcIp: String, _ sport: Int,
                              _ dstIp: String, _ dport: Int, _ payload: [UInt8]) {
        let len = payload.count
        lock.lock()
        if up {
            upPackets += 1
            upBytes += len
        } else {
            downPackets += 1
            downBytes += len
        }
        lock.unlock()

        // 拓扑：客户端 = 调用本机 SOCKS5 的设备，远端 = 它访问的目标
        FlowHub.shared.report(up: up, proto: proto, srcIp: srcIp, sport: sport,
                              dstIp: dstIp, dport: dport, len: len)

        guard let up2 = uploader else { return }
        // 上报：经会话流过滤，命中握手签名的流才上送（含命中前缓冲的报文）
        let ip = IpPacket.wrap(proto: proto, srcIp: srcIp, dstIp: dstIp,
                               sport: sport, dport: dport, payload: payload)
        for pkt in filter.accept(up: up, proto: proto,
                                 srcIp: srcIp, srcPort: sport,
                                 dstIp: dstIp, dstPort: dport,
                                 payloadLen: len, packet: ip) {
            up2.enqueueIp(pkt)
        }
    }

    // MARK: - 每秒节拍（主线程）

    private func tick() {
        ticks += 1
        let g = Globals.shared

        if g.running {
            syncStats()
            syncRadar()
            drainPackets()
            pushWave()
        } else {
            wave.push(up: 0, down: 0)
        }

        // 未监听时每 10s 测一次节点时速（对应安卓 speedProbe）
        if ticks % 10 == 0 && !g.running { probeNode() }
    }

    /// 把各组件线程里的计数同步到界面（@Published 只能在主线程写）
    private func syncStats() {
        let g = Globals.shared
        lock.lock()
        let up = upPackets, down = downPackets, ub = upBytes, db = downBytes
        lock.unlock()

        g.upPackets = Int64(up)
        g.downPackets = Int64(down)
        g.upBytes = Int64(ub)
        g.downBytes = Int64(db)
        g.filteredPackets = Int64(filter.filteredCount)

        guard let u = uploader else { return }
        let s = u.stats()
        g.sentPackets = Int64(s.sent)
        g.droppedPackets = Int64(s.dropped)
        g.resent = Int64(s.resent)
        g.replay = Int64(s.replay)
        g.queueSize = s.queueSize
        g.reconnects = Int64(s.reconnects)
        g.wsState = u.stateText
    }

    private func syncRadar() {
        radar.setDevices(FlowHub.shared.clientIps())
        radar.setRemotes(FlowHub.shared.remoteIps(), targets: [])
    }

    private func drainPackets() {
        for p in FlowHub.shared.drain(rowsPerTick) {
            feed.push(p)
            let devIp = p.up ? p.srcIp : p.dstIp
            let remoteIp = p.up ? p.dstIp : p.srcIp
            radar.emit(up: p.up, deviceIp: devIp, remoteIp: remoteIp)
        }
    }

    /// 波形按每秒字节差换算成 kbps
    private func pushWave() {
        let g = Globals.shared
        let dUp = max(0, g.upBytes - lastUpBytes)
        let dDown = max(0, g.downBytes - lastDownBytes)
        lastUpBytes = g.upBytes
        lastDownBytes = g.downBytes
        wave.push(up: CGFloat(dUp) * 8 / 1000, down: CGFloat(dDown) * 8 / 1000)
    }

    /// 切换/新增节点后立刻测一次速（对应安卓切节点时调用 testNode()）
    func probeNow() {
        probeNode()
    }

    /// 节点测速：真实 WS 握手耗时（3s 超时）
    private func probeNode() {
        if probing { return }
        let g = Globals.shared
        let host = g.selectedHost.isEmpty ? (g.nodes.first ?? "") : g.selectedHost
        guard !host.isEmpty, let url = URL(string: "ws://\(host):\(wsPort)") else { return }
        probing = true

        let start = Date()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        let task = session.webSocketTask(with: url)
        task.resume()

        // 回调线程只负责算耗时；去重与写界面都在主线程串行完成
        task.send(.string("{\"type\":\"ping\"}")) { [weak self] err in
            let ms: Int64 = err == nil ? Int64(Date().timeIntervalSince(start) * 1000) : -1
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            DispatchQueue.main.async { self?.finishProbe(ms) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            self?.finishProbe(-1)
        }
    }

    /// 只认第一次结果（主线程调用，天然串行）
    private func finishProbe(_ ms: Int64) {
        guard probing else { return }
        probing = false
        Globals.shared.latMs = ms
    }

    // MARK: - 工具

    /// 组件线程 → 主线程写界面日志
    private func uiLog(_ level: Globals.Level, _ msg: String) {
        DispatchQueue.main.async { Globals.shared.log(level, msg) }
    }
}
