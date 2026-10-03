// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Собственный WKWebView-контроллер для OAuth-авторизации ВК на iOS.
//
// Почему не ASWebAuthenticationSession:
//   ASWebAuthenticationSession не даёт "перезагрузить URL внутри одной сессии" —
//   только close + new instance. Нам нужен цикл silent_token →
//   vk.com → AUTH_URL в ТОМ ЖЕ WebView (как на Android).
//   Поэтому — свой WKWebView с persistent cookies (WKWebsiteDataStore.default()).
//
// Цикл:
//   Pass 1: webView.load(AUTH_URL)
//             - access_token=...     → сохраняем, dismiss.
//             - payload=... (silent) → webView.load("https://vk.com/")
//                                      ждём VK_DOT_COM_WAIT_MS (2000)
//                                      webView.load(AUTH_URL) → Pass 2.
//             - error=...            → сообщаем ошибку.
//   Pass 2: VK видит cookies активной сессии → "Продолжить как <Имя>"
//           → access_token.
//
//   Максимум 1 silent-проход. Общий таймаут 5 минут.

import UIKit
import WebKit

@available(iOS 17.0, *)
final class VkWebViewController: UIViewController, WKNavigationDelegate {

    // MARK: - Constants

    private static let CLIENT_ID = "7793118"
    private static let SCOPE = "1073737727"
    private static let REDIRECT_URI = "https://oauth.vk.ru/blank.html"

    private static let AUTH_URL =
        "https://oauth.vk.ru/authorize?" +
        "client_id=\(CLIENT_ID)&" +
        "scope=\(SCOPE)&" +
        "redirect_uri=" + "https%3A%2F%2Foauth.vk.ru%2Fblank.html" + "&" +
        "display=page&" +
        "response_type=token&" +
        "revoke=1&" +
        "v=5.199"

    private static let VK_DOT_COM_URL = "https://vk.com/"

    private static let BLANK_HOSTS: Set<String> = ["oauth.vk.ru", "oauth.vk.com"]
    private static let BLANK_PATH = "/blank.html"

    private static let POLL_INTERVAL_MS: UInt64 = 1000
    private static let TIMEOUT_SEC: TimeInterval = 5 * 60

    /** Сколько ждать на vk.com, чтобы VK проставил cookies активной сессии. */
    private static let VK_DOT_COM_WAIT_MS: UInt64 = 2000

    /** Максимум silent-перезапусков. 1 = не более 2 проходов. */
    private static let MAX_SILENT_RESTARTS = 1

    // MARK: - Callbacks

    private let onSuccess: (String) -> Void
    private let onError: (String) -> Void

    // MARK: - State

    private var webView: WKWebView!
    private var pollTimer: Timer?
    private var timeoutTimer: Timer?
    private var loadingOverlay: UIView?

    private var silentRestarts = 0
    private var finished = false
    private var inSilentRecovery = false
    private var lastLoggedUrl = ""

    // MARK: - Init

    init(onSuccess: @escaping (String) -> Void,
         onError: @escaping (String) -> Void) {
        self.onSuccess = onSuccess
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
        self.isModalInPresentation = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .white

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptEnabled = true

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        view.addSubview(webView)

        // Toolbar с кнопкой "Отмена"
        let toolbar = UIView()
        toolbar.backgroundColor = .systemBackground
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Отмена", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        cancelButton.addTarget(self, action: #selector(onCancelTap), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            cancelButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            cancelButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        startTimers()
        loadAuthUrl()
    }

    deinit {
        pollTimer?.invalidate()
        timeoutTimer?.invalidate()
    }

    @objc private func onCancelTap() {
        finishWithError("окно закрыто пользователем")
    }

    // MARK: - Loading

    private func loadAuthUrl() {
        guard !finished else { return }
        guard let url = URL(string: VkWebViewController.AUTH_URL) else {
            finishWithError("invalid auth url")
            return
        }
        lastLoggedUrl = ""
        logUrl(url.absoluteString)
        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        if let url = navigationAction.request.url?.absoluteString {
            handleUrl(url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        handleUrl(webView.url?.absoluteString)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        handleUrl(webView.url?.absoluteString)
    }

    // MARK: - URL Handling

    private func handleUrl(_ url: String?) {
        guard !finished, let url = url else { return }

        // Пока идёт silent recovery — мы намеренно ходим на vk.com и обратно,
        // не трогаем распознавание.
        if inSilentRecovery {
            logUrl(url)
            return
        }

        logUrl(url)

        guard isBlankRedirect(url) else { return }
        guard let fragment = extractFragment(url), !fragment.isEmpty else { return }

        // 1. access_token
        if let token = extractQueryParam(fragment, key: "access_token"), !token.isEmpty {
            print("[VK] access_token received (pass \(silentRestarts + 1))")
            finishWithToken(token)
            return
        }

        // 2. silent_token
        if fragment.contains("payload=") {
            handleSilentToken()
            return
        }

        // 3. error
        if fragment.contains("error=") {
            let desc = extractQueryParam(fragment, key: "error_description")
                ?? extractQueryParam(fragment, key: "error")
                ?? "неизвестная ошибка"
            finishWithError("VK: \(desc)")
        }
    }

    /// silent_token: НЕ закрываем WebView. Идём на vk.com, ждём 2 сек,
    /// возвращаемся на AUTH_URL в ТОМ ЖЕ WebView.
    private func handleSilentToken() {
        if silentRestarts >= VkWebViewController.MAX_SILENT_RESTARTS {
            print("[VK] silent_token on pass \(silentRestarts + 1) — giving up")
            finishWithError("VK вернул silent_token дважды. Войдите заново вручную.")
            return
        }

        silentRestarts += 1
        inSilentRecovery = true
        print("[VK] silent_token → visiting vk.com (pass \(silentRestarts))")

        showLoadingOverlay(text: "Получаем токен, подождите...")

        // 1. Идём на vk.com — VK проставит cookies активной сессии.
        if let url = URL(string: VkWebViewController.VK_DOT_COM_URL) {
            webView.load(URLRequest(url: url))
        }

        // 2. Через VK_DOT_COM_WAIT_MS — возвращаемся на AUTH_URL.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(VkWebViewController.VK_DOT_COM_WAIT_MS))
        ) { [weak self] in
            guard let self = self, !self.finished else { return }
            print("[VK] silent recovery → back to AUTH_URL")
            self.inSilentRecovery = false
            self.hideLoadingOverlay()
            self.loadAuthUrl()
        }
    }

    private func isBlankRedirect(_ url: String) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        guard let host = parsed.host?.lowercased() else { return false }
        let hostOk = VkWebViewController.BLANK_HOSTS.contains(host)
        return hostOk && parsed.path == VkWebViewController.BLANK_PATH
    }

    private func extractFragment(_ url: String) -> String? {
        if let hash = url.firstIndex(of: "#") {
            return String(url[url.index(after: hash)...])
        }
        if let q = url.firstIndex(of: "?") {
            return String(url[url.index(after: q)...])
        }
        return nil
    }

    private func extractQueryParam(_ query: String, key: String) -> String? {
        var q = query
        if q.hasPrefix("#") || q.hasPrefix("?") { q = String(q.dropFirst()) }
        for pair in q.split(separator: "&") {
            let comps = pair.split(separator: "=", maxSplits: 1)
            guard comps.count == 2 else { continue }
            if comps[0] == key {
                return String(comps[1]).removingPercentEncoding
            }
        }
        return nil
    }

    private func logUrl(_ url: String) {
        if url == lastLoggedUrl { return }
        lastLoggedUrl = url
        print("[VK] URL: \(url)")
    }

    // MARK: - Timers

    private func startTimers() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            guard let self = self, !self.finished else { return }
            if let url = self.webView.url?.absoluteString {
                self.handleUrl(url)
            }
        }

        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: VkWebViewController.TIMEOUT_SEC,
            repeats: false
        ) { [weak self] _ in
            self?.finishWithError("тайм-аут ожидания токена")
        }
    }

    // MARK: - Loading overlay

    private func showLoadingOverlay(text: String) {
        hideLoadingOverlay()

        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(card)

        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(indicator)

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 40),
            card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -40),

            indicator.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            indicator.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            label.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])

        loadingOverlay = overlay
    }

    private func hideLoadingOverlay() {
        loadingOverlay?.removeFromSuperview()
        loadingOverlay = nil
    }

    // MARK: - Finish

    private func finishWithToken(_ token: String) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate(); pollTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        hideLoadingOverlay()

        let cb = onSuccess
        dismiss(animated: true) { cb(token) }
    }

    private func finishWithError(_ message: String) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate(); pollTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        hideLoadingOverlay()

        let cb = onError
        dismiss(animated: true) { cb(message) }
    }
}
