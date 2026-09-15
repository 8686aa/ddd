import Combine
import SwiftUI
import WebKit

// ============================================================================
// 内置雷达页：内嵌浏览器加载一个可自定义的服务器地址
// 首页「开始监听」成功后自动跳到这里；地址栏内容持久化，重启后仍是上次填写的地址。
// ============================================================================

/// 地址栏默认值；用户可在界面上改成任意链接，改动后持久化到 UserDefaults
let radarDefaultURL = "http://bnaidu.com"

/// 一次「跳到内置雷达」请求。每次都用新的 id，保证同一请求重复触发也能被 onChange 收到。
struct RadarOpenRequest: Equatable {
    let id = UUID()
    /// nil = 沿用雷达页自己保存的地址（首页自动跳转时用）
    var url: String? = nil
}

/// 首页在开始监听成功后调用 open()；根视图与雷达页各自监听同一个发布者，
/// 不依赖调用顺序（Tab 子页可能在切到该 Tab 时才构建，故页面 onAppear 里补收一次）。
final class RadarRouter: ObservableObject {
    static let shared = RadarRouter()
    @Published var request: RadarOpenRequest?
    private init() {}
    func open(url: String? = nil) { request = RadarOpenRequest(url: url) }
}

/// 供刷新按钮持有的 WebView 引用
private final class WebBox {
    weak var web: WKWebView?
}

private struct RadarWebView: UIViewRepresentable {
    let url: URL
    let box: WebBox

    final class Coordinator {
        /// 记录已加载的地址，用于区分「地址栏变更」和「SwiftUI 例行刷新」
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .clear
        box.web = w
        context.coordinator.loadedURL = url
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 只有地址栏真的改过才重新加载，否则每次界面刷新都会把页面重载一遍
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        uiView.load(URLRequest(url: url))
    }
}

/// 内置雷达页（Tab 1）：顶部地址栏 + 刷新，下方内嵌浏览器
struct RadarTabPage: View {
    @State private var box = WebBox()
    /// 地址栏文本（持久化：重启后仍是上次填写的地址）
    @AppStorage("radar_url") private var urlText: String = radarDefaultURL
    /// 当前已加载的地址
    @State private var url = URL(string: radarDefaultURL)!

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            RadarWebView(url: url, box: box)
        }
        .background(P.color(P.BG0))
        .onAppear {
            // TabView 的子页可能在切到该 Tab 时才构建，此时收不到已发出的请求，这里补一次
            if let req = RadarRouter.shared.request { open(req) }
        }
        .onReceive(RadarRouter.shared.$request.compactMap { $0 }) { req in
            open(req)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 13))
                .foregroundColor(P.color(P.CYAN))

            TextField(radarDefaultURL, text: $urlText)
                .font(Fonts.mono(12))
                .foregroundColor(P.color(P.TXT))
                .tint(P.color(P.CYAN))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { go() }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(P.color(0xB80C1323))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(P.color(0x331860DC), lineWidth: 1)
                )

            Button(action: go) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 19))
                    .foregroundColor(P.color(P.CYAN))
            }
            Button { box.web?.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(P.color(P.TXT_DIM))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [P.color(0xE60C1323), P.color(0xA0070C18)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(P.color(0x291860DC)).frame(height: 1)
            }
        )
    }

    /// 地址栏提交：未带协议头时自动补 http://
    private func go() {
        var t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") {
            t = "http://" + t
        }
        guard let u = URL(string: t), u.host != nil else { return }
        urlText = u.absoluteString   // 回填规范化后的地址
        url = u
    }

    /// 载入外部请求的地址；请求未带地址时沿用当前地址（只做跳转，不重载）
    private func open(_ req: RadarOpenRequest) {
        guard let text = req.url, let u = URL(string: text), u.host != nil else { return }
        urlText = u.absoluteString
        url = u
    }
}
