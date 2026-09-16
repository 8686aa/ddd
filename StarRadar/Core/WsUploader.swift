import Foundation

/// WebSocket 上报器 —— 规则与桌面版 ws.go 一致（对应安卓 WsUploader.kt）：
///
///   鉴权：连接后先发 {"type":"auth","api_key":"<32位hex>"}，等待回执
///        {"type":"auth_ok"} 视为通过；{"type":"error",...} 视为 Key 无效，
///        提示后终止且**不再重连**。
///   上报：{"batch":[{"data":"<base64 整包 IP 报文>"},...]}，单批最多 40 条。
///   补包：发送**确认成功才出队**，失败整批留在队内，重连后按原序续发；
///        入队时记录连接代次 gen，重连后 gen 落后于当前代次的报文即为补包，
///        计入 resent；队首连续落后代次的报文数即待补发 replay。
///   队列：超过 2 万条时丢弃最旧的（内存兜底）。
///   断线快速检测：① 接收回调即时感知 FIN/RST；② 单批 5s 发送确认超时；
///        ③ 空闲 15s 发一次应用层 ping，发送确认失败即判定链路异常。
///   重连退避：1s → 2s → 4s → 5s（封顶）。
///
/// 线程模型：runLoop 独占一条后台线程；队列与统计用 lock 保护；
/// 状态文本由 [stateText] 暴露，界面侧每秒同步到 Globals。
final class WsUploader {

    /// 供界面每秒同步的统计快照
    struct Stats {
        var sent = 0
        var dropped = 0
        var resent = 0
        var queueSize = 0
        var replay = 0
        var reconnects = 0
    }

    private final class Pending {
        let data: String
        let gen: Int
        let seq: Int
        let t: Date        // 入队时间：补包窗口（只补 10 秒内）判定用
        init(data: String, gen: Int, seq: Int, t: Date) {
            self.data = data
            self.gen = gen
            self.seq = seq
            self.t = t
        }
    }

    /// 跨线程回传的小容器
    private final class Flag {
        var ok = false
    }

    private let urlString: String
    private let apiKey: String
    private let log: (Globals.Level, String) -> Void
    private let onAuthFailed: (String) -> Void

    private let lock = NSLock()
    private var queue: [Pending] = []
    private var seqNo = 0
    private var genNo = 0
    private var connSeq = 0            // 累计建连次数（重连次数 = connSeq - 1）

    private var sent = 0
    private var dropped = 0
    private var resent = 0

    private var stopFlag = false
    private var connectedFlag = false
    private var everConnected = false
    private var authRejectedFlag = false
    private var authResult = 0          // 0=等待 1=通过 -1=Key 无效 -2=连接断开
    private var authMsg = ""
    private var state = "未连接"
    private var lastErrLog = Date.distantPast
    private var lastSendMs = Date()

    private var session: URLSession?
    private var currentTask: URLSessionWebSocketTask?
    private var thread: Thread?

    private let batchMax = 40
    private let queueLimit = 20000
    private let sendTimeout: TimeInterval = 5      // 单批发送确认超时
    private let dialTimeout: TimeInterval = 10     // 也作为 ping/pong 半开判定超时
    private let authWait: TimeInterval = 8
    private let idlePingMs: TimeInterval = 15
    private let reconnMin: TimeInterval = 1
    private let reconnMax: TimeInterval = 5

    init(url: String, apiKey: String,
         log: @escaping (Globals.Level, String) -> Void,
         onAuthFailed: @escaping (String) -> Void) {
        self.urlString = url
        self.apiKey = apiKey
        self.log = log
        self.onAuthFailed = onAuthFailed
    }

    // MARK: - 生命周期

    func start() {
        lock.lock()
        stopFlag = false
        authResult = 0
        state = "重连中…"
        lock.unlock()

        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "ws-uploader"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        stopFlag = true
        connectedFlag = false
        state = "未连接"
        lock.unlock()
        currentTask?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    func isConnected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connectedFlag
    }

    /// 当前连接状态文本（界面每秒同步到 Globals.wsState）
    var stateText: String {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(sent: sent, dropped: dropped, resent: resent,
                     queueSize: queue.count, replay: replayLocked(), reconnects: max(0, connSeq - 1))
    }

    /// 其他线程调用：上报一段载荷（完整 IP 报文）。
    func enqueueIp(_ ipPacket: [UInt8]) {
        let b64 = Data(ipPacket).base64EncodedString()
        lock.lock(); defer { lock.unlock() }
        seqNo += 1
        queue.append(Pending(data: b64, gen: genNo, seq: seqNo))
        while queue.count > queueLimit {
            queue.removeFirst()
            dropped += 1
        }
    }

    // MARK: - 主循环

    private func runLoop() {
        var backoff = reconnMin
        while !isStop() && !isAuthRejected() {
            let ok = connectAndAuth()
            if isStop() || isAuthRejected() { break }

            if ok {
                backoff = reconnMin
                drainLoop()
            }
            if isStop() { break }

            lock.lock(); state = "重连中…"; lock.unlock()
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, reconnMax)
        }

        lock.lock()
        connectedFlag = false
        queue.removeAll()
        lock.unlock()
        log(.info, "[ws] 上报已停止")
    }

    /// 一次完整连接：拨号 → 鉴权 → 成功后置 connected
    private func connectAndAuth() -> Bool {
        guard let url = URL(string: urlString) else {
            logThrottled(.warn, "[ws] 节点地址无效: \(urlString)")
            return false
        }

        session?.invalidateAndCancel()                  // 回收上一次的会话

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = dialTimeout      // 握手 / ping-pong 半开判定
        cfg.timeoutIntervalForResource = 0               // 长连接不设总时限
        cfg.waitsForConnectivity = false
        let s = URLSession(configuration: cfg, delegate: nil, delegateQueue: nil)
        session = s

        lock.lock()
        authResult = 0
        authMsg = ""
        lock.unlock()

        let task = s.webSocketTask(with: url)
        currentTask = task
        task.resume()
        startReceiveLoop(task)

        // 发鉴权报文并确认写出（写不出去说明握手没成）
        if !apiKey.isEmpty {
            let authJSON = "{\"type\":\"auth\",\"api_key\":\"\(apiKey)\"}"
            if !sendText(task, authJSON, timeout: sendTimeout) {
                markDown(task)
                logThrottled(.warn, "[ws] 鉴权报文发送失败，稍后重试")
                return false
            }
        } else if !sendText(task, "{\"type\":\"ping\"}", timeout: sendTimeout) {
            markDown(task)
            return false
        }

        // 到这里 TCP/WS 握手已完成，进入新连接代次
        lock.lock()
        genNo += 1
        connSeq += 1
        if apiKey.isEmpty { authResult = 1 }
        lock.unlock()

        // 等回执
        let deadline = Date().addingTimeInterval(authWait)
        while Date() < deadline {
            if isStop() { break }
            lock.lock()
            let r = authResult
            lock.unlock()
            if r != 0 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }

        lock.lock()
        let result = authResult
        let msg = authMsg
        lock.unlock()

        switch result {
        case 1:
            lock.lock()
            connectedFlag = true
            state = "已连接"
            let first = !everConnected
            everConnected = true
            lastSendMs = Date()
            lock.unlock()
            if first {
                log(.ok, "[ws] 已连接 \(urlString)")
            } else {
                log(.ok, "[ws] 链路已恢复，积压报文按原序补发")
            }
            return true
        case -1:
            lock.lock()
            authRejectedFlag = true
            state = "鉴权失败"
            lock.unlock()
            log(.err, "[ws] 鉴权失败：\(msg)")
            onAuthFailed(msg)
            return false
        default:
            lock.lock(); state = "重连中…"; lock.unlock()
            logThrottled(.warn, "[ws] 连接节点未就绪，稍后重试")
            return false
        }
    }

    /// 连接存活期间：批量取报文 → 发送确认 → 出队；失败整批留队交给重连
    private func drainLoop() {
        while !isStop() && isConnected() {
            var batch = takeBatch()
            if batch.isEmpty {
                // 空闲心跳：转发器据此保活；发送失败即判定链路异常
                if Date().timeIntervalSince(lastSendMs) > idlePingMs {
                    guard let task = currentTask else { break }
                    if !sendText(task, "{\"type\":\"ping\"}", timeout: sendTimeout) {
                        logThrottled(.warn, "[ws] 心跳发送失败，重连续发")
                        break
                    }
                    lastSendMs = Date()
                }
                Thread.sleep(forTimeInterval: 0.015)
                continue
            }
            if batch.count < batchMax {
                Thread.sleep(forTimeInterval: 0.015)     // 短暂聚合，提升批量效率
                batch = takeBatch()
            }

            guard let task = currentTask, isConnected() else { break }
            if !sendBatch(task, batch) { break }         // 整批留队，重连后按原序续发
            ackBatch(batch)
        }
    }

    /// 取队首最多 batchMax 条（只窥视，不删除）
    private func takeBatch() -> [Pending] {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return [] }
        let n = min(batchMax, queue.count)
        return Array(queue[0..<n])
    }

    private func sendBatch(_ task: URLSessionWebSocketTask, _ batch: [Pending]) -> Bool {
        var sb = "{\"batch\":["
        for i in 0..<batch.count {
            if i > 0 { sb += "," }
            sb += "{\"data\":\"\(batch[i].data)\"}"
        }
        sb += "]}"

        if !sendText(task, sb, timeout: sendTimeout) {
            logThrottled(.warn, "[ws] 发送超时，强制重连续发")
            return false
        }
        lastSendMs = Date()
        return true
    }

    /// 按入队序号前缀出队：即使期间发生溢出丢弃，也不会误删后面的报文
    private func ackBatch(_ batch: [Pending]) {
        lock.lock(); defer { lock.unlock() }
        for p in batch {
            guard let head = queue.first else { break }
            if head.seq != p.seq { break }
            queue.removeFirst()
            if p.gen < genNo { resent += 1 }        // 断线期间积压、重连后成功续发 → 补包
        }
        sent += batch.count
    }

    // MARK: - 收发

    /// 长驻接收循环：拿到回执 / 感知断开。URLSessionWebSocketTask 是拉模式，必须持续 receive。
    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard self.currentTask === task else { return }   // 已换连接，丢弃旧回调
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.handleMessage(text) }
                self.startReceiveLoop(task)
            case .failure:
                self.markDown(task)
            }
        }
    }

    private func handleMessage(_ text: String) {
        lock.lock()
        let waiting = authResult == 0
        lock.unlock()
        guard waiting else { return }

        if text.contains("\"auth_ok\"") {
            lock.lock(); authResult = 1; lock.unlock()
        } else if text.contains("\"error\"") {
            let msg = extractMsg(text)
            lock.lock(); authMsg = msg; authResult = -1; lock.unlock()
        }
    }

    /// 发送并等待「已写出」确认；超时或出错返回 false
    private func sendText(_ task: URLSessionWebSocketTask, _ text: String,
                          timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        let flag = Flag()
        task.send(.string(text)) { err in
            flag.ok = (err == nil)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return false }
        return flag.ok
    }

    // MARK: - 状态

    private func isStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopFlag
    }

    private func isAuthRejected() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return authRejectedFlag
    }

    /// 队首连续「代次落后于当前连接」的报文数（须持锁调用）
    private func replayLocked() -> Int {
        var n = 0
        for p in queue {
            if p.gen < genNo { n += 1 } else { break }
        }
        return n
    }

    private func markDown(_ task: URLSessionWebSocketTask) {
        lock.lock()
        connectedFlag = false
        if currentTask === task { currentTask = nil }
        if authResult == 0 { authResult = -2 }
        lock.unlock()
        task.cancel(with: .abnormalClosure, reason: nil)
    }

    /// 失败日志节流：自动重连场景每 10s 最多一条
    private func logThrottled(_ level: Globals.Level, _ text: String) {
        let now = Date()
        if now.timeIntervalSince(lastErrLog) < 10 { return }
        lastErrLog = now
        log(level, text)
    }

    private func extractMsg(_ json: String) -> String {
        let k = "\"msg\""
        guard let r = json.range(of: k) else { return "invalid api_key" }
        let rest = json[r.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return "invalid api_key" }
        let tail = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix("\"") else { return "invalid api_key" }
        let body = tail.dropFirst()
        guard let end = body.firstIndex(of: "\"") else { return "invalid api_key" }
        return String(body[body.startIndex..<end])
    }
}
