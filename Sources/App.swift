import AppKit
import WebKit
import ServiceManagement

// Usage Bar for Claude
// An independent, unofficial tool; not affiliated with or endorsed by Anthropic.
// (The app's entry point is in Entry.swift.)
// A menu bar item that shows your Claude plan usage: the current 5-hour
// session and the weekly limit. It signs in to claude.ai inside its own web
// view and reads the same numbers that Settings > Usage shows.

// MARK: - Settings

/// Any page on claude.ai works as an "anchor": the usage request has to be
/// made from that origin so the sign-in cookies are sent with it.
private let anchorURL = URL(string: "https://claude.ai/robots.txt")!
private let loginURL = URL(string: "https://claude.ai/login")!
private let usagePageURL = URL(string: "https://claude.ai/settings/usage")!

private let refreshInterval: TimeInterval = 30    // seconds between automatic refreshes
private let signedOutInterval: TimeInterval = 300 // slower checks while signed out

// Colour bands, by the rounded percentage shown:
// green up to 50, yellow 51-75, orange 76-90, red 91-100.
private let greenUpTo = 50
private let yellowUpTo = 75
private let orangeUpTo = 90

// MARK: - Usage request (runs inside the web view)

// PROBE-BEGIN
private let probeScript = #"""
const ctl = new AbortController();
const timer = setTimeout(() => ctl.abort(), 20000);
try {
  const opts = { credentials: 'include', headers: { accept: 'application/json' }, signal: ctl.signal };
  const usageURL = id => 'https://claude.ai/api/organizations/' + id + '/usage';
  if (cachedOrg) {
    const u = await fetch(usageURL(cachedOrg), opts);
    if (u.ok) return JSON.stringify({ state: 'ok', orgId: cachedOrg, usage: await u.json() });
  }
  const r = await fetch('https://claude.ai/api/organizations', opts);
  if (r.status === 401 || r.status === 403) return JSON.stringify({ state: 'signedOut' });
  if (!r.ok) return JSON.stringify({ state: 'error', message: 'claude.ai returned HTTP ' + r.status });
  const orgs = await r.json();
  if (!Array.isArray(orgs) || orgs.length === 0) {
    return JSON.stringify({ state: 'error', message: 'No organization found on this account' });
  }
  const m = document.cookie.match(/(?:^|;\s*)lastActiveOrg=([^;]+)/);
  const last = m ? decodeURIComponent(m[1]) : null;
  const rank = o => (o.uuid === last ? 0 : (Array.isArray(o.capabilities) && o.capabilities.includes('chat')) ? 1 : 2);
  orgs.sort((a, b) => rank(a) - rank(b));
  let lastStatus = 0;
  for (const o of orgs) {
    const u = await fetch(usageURL(o.uuid), opts);
    if (u.ok) return JSON.stringify({ state: 'ok', orgId: o.uuid, usage: await u.json() });
    lastStatus = u.status;
  }
  return JSON.stringify({ state: 'error', message: 'Usage request returned HTTP ' + lastStatus });
} catch (e) {
  return JSON.stringify({ state: 'error', message: String(e && e.message ? e.message : e) });
} finally {
  clearTimeout(timer);
}
"""#
// PROBE-END

// MARK: - Model

struct UsageWindow {
    let key: String
    let title: String
    let percent: Double
    let resetsAt: Date?
}

func numberValue(_ any: Any?) -> Double? {
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s) }
    return nil
}

func parseDate(_ any: Any?) -> Date? {
    if let n = any as? NSNumber {
        let v = n.doubleValue
        return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
    }
    guard var s = any as? String else { return nil }
    // Drop fractional seconds; the plain ISO 8601 parser does not accept them.
    if let r = s.range(of: "\\.[0-9]+", options: .regularExpression) {
        s.removeSubrange(r)
    }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func displayName(forKey key: String) -> String {
    switch key {
    case "five_hour": return "Current session"
    case "seven_day": return "Weekly · all models"
    case "seven_day_opus": return "Weekly · Opus"
    case "seven_day_sonnet": return "Weekly · Sonnet"
    case "seven_day_omelette": return "Weekly · Claude Design"
    case "extra_usage": return "Extra usage"
    default:
        var prefix = ""
        var rest = key
        if key.hasPrefix("seven_day_") {
            prefix = "Weekly · "
            rest = String(key.dropFirst("seven_day_".count))
        } else if key.hasPrefix("five_hour_") {
            prefix = "Session · "
            rest = String(key.dropFirst("five_hour_".count))
        }
        return prefix + rest.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Turns the usage response into rows. The two headline windows come first;
/// anything else that carries a percentage is listed after them, so new
/// limits show up without a code change.
func parseUsage(_ usage: [String: Any]) -> [UsageWindow] {
    let headline = ["five_hour", "seven_day"]
    let known = headline + ["seven_day_opus", "seven_day_sonnet", "seven_day_omelette"]
    let others = usage.keys.filter { !known.contains($0) }.sorted()
    var result: [UsageWindow] = []
    for key in known + others {
        guard let raw = usage[key] else { continue }
        if let entry = raw as? [String: Any] {
            if let enabled = entry["is_enabled"] as? Bool, !enabled { continue }
            var pct = numberValue(entry["utilization"]) ?? numberValue(entry["used_percentage"])
            if pct == nil && headline.contains(key) { pct = 0 }
            guard let percent = pct else { continue }
            result.append(UsageWindow(key: key, title: displayName(forKey: key), percent: percent,
                                      resetsAt: parseDate(entry["resets_at"])))
        } else if raw is NSNull, headline.contains(key) {
            // Present but empty: nothing used in this window yet.
            result.append(UsageWindow(key: key, title: displayName(forKey: key), percent: 0, resetsAt: nil))
        }
    }
    return result
}

// MARK: - Formatting

func countdown(to date: Date, from now: Date = Date()) -> String {
    let s = Int(date.timeIntervalSince(now))
    if s <= 0 { return "now" }
    let d = s / 86400
    let h = (s % 86400) / 3600
    let m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(max(m, 1))m"
}

func levelColor(_ percent: Double) -> NSColor {
    let shown = Int(percent.rounded())
    if shown > orangeUpTo { return NSColor.systemRed }
    if shown > yellowUpTo { return NSColor.systemOrange }
    if shown > greenUpTo { return NSColor.systemYellow }
    return NSColor.systemGreen
}

func percentText(_ percent: Double) -> String {
    return "\(Int(percent.rounded()))%"
}

private let resetFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEE j:mm")
    return f
}()

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()

// MARK: - Dropdown row

final class UsageRowView: NSView {
    private let title: String
    private let percent: Double
    private let detail: String

    init(title: String, percent: Double, detail: String) {
        self.title = title
        self.percent = percent
        self.detail = detail
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        (title as NSString).draw(at: NSPoint(x: inset, y: 34), withAttributes: titleAttrs)

        let value = percentText(percent) as NSString
        let valueSize = value.size(withAttributes: valueAttrs)
        value.draw(at: NSPoint(x: bounds.width - inset - valueSize.width, y: 34), withAttributes: valueAttrs)

        let track = NSRect(x: inset, y: 24, width: bounds.width - inset * 2, height: 6)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()

        let fraction = CGFloat(min(max(percent, 0), 100) / 100)
        if fraction > 0 {
            var fill = track
            fill.size.width = max(track.width * fraction, 6)
            levelColor(percent).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }

        (detail as NSString).draw(at: NSPoint(x: inset, y: 6), withAttributes: detailAttrs)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var webView: WKWebView!
    private var loginWindow: NSWindow!
    private var popupWindows: [NSWindow] = []

    private var windows: [UsageWindow] = []
    private var lastUpdated: Date?
    private var lastAttempt: Date?
    private var lastError: String?
    private var signedOut = false

    private var pendingProbe = false
    private var needsAnchorReload = false
    private var anchorLoadStartedAt: Date?
    private var cachedOrg = UserDefaults.standard.string(forKey: "orgId") ?? ""
    private var activity: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var probeStartedAt: Date?
    private var loginMode = false
    private var didAutoPrompt = false
    private var tickTimer: Timer?
    private var pollTimer: Timer?

    private let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "UsageBarForClaude"
        statusItem.button?.font = titleFont
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.renderTitle()
            }
        }
        statusItem.button?.toolTip = "Claude usage: current session (5h) and weekly limit (7d)"

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        // Present as Safari so sign-in providers accept the embedded browser.
        config.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let frame = NSRect(x: 0, y: 0, width: 480, height: 720)
        webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        loginWindow = NSWindow(contentRect: frame,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        loginWindow.title = "Sign in to Claude"
        loginWindow.isReleasedWhenClosed = false
        loginWindow.delegate = self
        loginWindow.contentView = webView
        loginWindow.center()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        tickTimer = Timer.scheduledTimer(timeInterval: refreshInterval, target: self, selector: #selector(tick),
                                         userInfo: nil, repeats: true)
        // Without this, macOS may put a windowless app to sleep and stretch the timer.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Refreshing Claude usage on a timer")

        renderTitle()
        refresh()
    }

    /// An accessory app has no visible menu bar of its own, but it still needs
    /// an Edit menu for Cmd-C / Cmd-V to work in the sign-in window.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Usage Bar for Claude",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Menu bar title

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let session = windows.first { $0.key == "five_hour" }
        let week = windows.first { $0.key == "seven_day" }

        var parts: [(label: String, window: UsageWindow)] = []
        if let s = session { parts.append((label: "5h", window: s)) }
        if let w = week { parts.append((label: "7d", window: w)) }

        button.image = dualRingIcon(session: session?.percent, week: week?.percent)

        if parts.isEmpty {
            if signedOut {
                button.title = " Sign in"
            } else if lastError != nil {
                button.title = " –"
            } else {
                button.title = " …"
            }
            return
        }

        // Labels follow the menu bar's own text colour; each number is coloured by its band.
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            let prefix = (index == 0 ? " " : "  ") + part.label + " "
            text.append(NSAttributedString(string: prefix, attributes: [
                .font: titleFont, .foregroundColor: NSColor.controlTextColor
            ]))
            let p = part.window.percent
            text.append(NSAttributedString(string: percentText(p), attributes: [
                .font: titleFont,
                .foregroundColor: levelColor(p)
            ]))
        }
        button.attributedTitle = text
    }

    /// Menu bar icon: two rings that fill clockwise as the limits are used up.
    /// Outer ring: the current session. Inner ring: the week. Each filled arc takes
    /// its band colour; the empty track follows the menu bar's light or dark look.
    private func dualRingIcon(session: Double?, week: Double?) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let lineWidth: CGFloat = 2.0
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base = isDark ? NSColor.white : NSColor.black
            let noData = session == nil && week == nil
            let trackColor = base.withAlphaComponent(noData ? 0.55 : 0.3)

            func ring(radius: CGFloat, percent: Double?) {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = lineWidth
                trackColor.setStroke()
                track.stroke()

                guard let percent = percent, percent > 0 else { return }
                let filled = CGFloat(min(max(percent / 100, 0.04), 1))
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * filled, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                levelColor(percent).setStroke()
                arc.stroke()
            }

            ring(radius: 7.0, percent: session)
            ring(radius: 3.5, percent: week)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Claude usage"
        return image
    }

    // MARK: Refreshing

    /// Asks claude.ai for the current figures. The request runs from the anchor
    /// page already loaded in the web view; that page is only reloaded when needed.
    @objc private func refresh() {
        guard !loginMode else { return }
        lastAttempt = Date()
        let onClaude = webView.url?.host == "claude.ai"
        if onClaude && !webView.isLoading && !needsAnchorReload {
            runProbe()
            return
        }
        let loadIsRecent = anchorLoadStartedAt.map { Date().timeIntervalSince($0) < 45 } ?? false
        if webView.isLoading && loadIsRecent && !needsAnchorReload {
            pendingProbe = true   // the page is on its way; ask when it arrives
            return
        }
        loadAnchor(thenProbe: true)
    }

    private func loadAnchor(thenProbe: Bool) {
        needsAnchorReload = false
        pendingProbe = thenProbe
        anchorLoadStartedAt = Date()
        webView.load(URLRequest(url: anchorURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    @objc private func tick() {
        if signedOut, let last = lastAttempt, Date().timeIntervalSince(last) < signedOutInterval - 1 {
            return
        }
        refresh()
    }

    @objc private func systemDidWake() {
        perform(#selector(refresh), with: nil, afterDelay: 5)
    }

    private func runProbe() {
        if let started = probeStartedAt, Date().timeIntervalSince(started) < 40 { return }
        probeStartedAt = Date()
        webView.callAsyncJavaScript(probeScript, arguments: ["cachedOrg": cachedOrg], in: nil,
                                    in: WKContentWorld.defaultClient) { [weak self] result in
            let text: String?
            let failure: String?
            switch result {
            case .success(let value):
                text = value as? String
                failure = nil
            case .failure(let error):
                text = nil
                failure = error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                self?.handleProbe(text: text, failure: failure)
            }
        }
    }

    private func handleProbe(text: String?, failure: String?) {
        probeStartedAt = nil
        if failure != nil { needsAnchorReload = true }   // the page itself is gone; load it afresh

        var state = "error"
        var message = failure ?? "Unexpected response from claude.ai"
        var payload: [String: Any] = [:]
        if let text = text, let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            payload = object
            state = (object["state"] as? String) ?? "error"
            if let m = object["message"] as? String { message = m }
        }

        if loginMode {
            // While the sign-in window is open, only success matters.
            if state == "ok" {
                finishLogin()
                applyUsage(payload)
            }
            return
        }

        switch state {
        case "ok":
            applyUsage(payload)
        case "signedOut":
            signedOut = true
            windows = []
            lastError = nil
            needsAnchorReload = true   // a fresh page load next time, in case that clears it
            renderTitle()
            if !didAutoPrompt && !UserDefaults.standard.bool(forKey: "hasSignedIn") {
                didAutoPrompt = true
                showLogin()
            }
        default:
            lastError = message
            renderTitle()
        }
    }

    private func applyUsage(_ payload: [String: Any]) {
        let usage = (payload["usage"] as? [String: Any]) ?? [:]
        let parsed = parseUsage(usage)
        if parsed.isEmpty {
            lastError = "No usage figures in the response (its format may have changed)"
        } else {
            windows = parsed
            lastError = nil
            lastUpdated = Date()
        }
        if let id = payload["orgId"] as? String, !id.isEmpty, id != cachedOrg {
            cachedOrg = id
            UserDefaults.standard.set(id, forKey: "orgId")
        }
        signedOut = false
        UserDefaults.standard.set(true, forKey: "hasSignedIn")
        renderTitle()
    }

    // MARK: Signing in and out

    @objc private func showLogin() {
        loginMode = true
        pendingProbe = false
        webView.load(URLRequest(url: loginURL))
        NSApp.activate(ignoringOtherApps: true)
        loginWindow.makeKeyAndOrderFront(nil)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(pollLogin),
                                         userInfo: nil, repeats: true)
    }

    /// Watches the sign-in window and checks for a session once it has left the login page.
    @objc private func pollLogin() {
        guard loginMode else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard let url = webView.url, url.host == "claude.ai" else { return }
        let path = url.path
        if path == "/login" || path.hasPrefix("/login/") { return }
        runProbe()
    }

    private func endLoginMode() {
        loginMode = false
        pollTimer?.invalidate()
        pollTimer = nil
        let popups = popupWindows
        popupWindows.removeAll()
        for w in popups { w.close() }
    }

    private func finishLogin() {
        endLoginMode()
        loginWindow.orderOut(nil)
        // Swap the full Claude web app for the lightweight anchor page.
        loadAnchor(thenProbe: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === loginWindow, loginMode else { return }
        endLoginMode()
        refresh()
    }

    @objc private func signInWithSessionKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sign in with a session key"
        alert.informativeText = "Paste the value of the sessionKey cookie from claude.ai "
            + "(in your browser: Developer Tools > Application > Cookies > https://claude.ai). "
            + "It is kept only in this app's local web data on this Mac."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "sessionKey value"
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: "sessionKey",
            .value: key,
            .domain: ".claude.ai",
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 180)
        ]
        guard let cookie = HTTPCookie(properties: properties) else { return }

        if loginMode {
            endLoginMode()
            loginWindow.orderOut(nil)
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }
    }

    @objc private func signOut() {
        if loginMode { endLoginMode() }
        loginWindow.orderOut(nil)
        pendingProbe = false
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: Date.distantPast) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.didSignOut()
            }
        }
    }

    private func didSignOut() {
        windows = []
        lastUpdated = nil
        lastError = nil
        signedOut = true
        didAutoPrompt = true
        cachedOrg = ""
        needsAnchorReload = true
        UserDefaults.standard.removeObject(forKey: "orgId")
        UserDefaults.standard.set(false, forKey: "hasSignedIn")
        renderTitle()
    }

    // MARK: Web view callbacks

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, pendingProbe else { return }
        pendingProbe = false
        runProbe()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        navigationFailed(webView, error)
    }

    private func navigationFailed(_ webView: WKWebView, _ error: Error) {
        guard webView === self.webView, pendingProbe else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        pendingProbe = false
        lastError = error.localizedDescription
        renderTitle()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { needsAnchorReload = true }
    }

    /// Sign-in providers such as Google open a pop-up window; give them one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 680)
        let popup = WKWebView(frame: frame, configuration: configuration)
        popup.uiDelegate = self
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popupWindows.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let window = webView.window, window !== loginWindow else { return }
        popupWindows.removeAll { $0 === window }
        window.close()
    }

    // MARK: Dropdown menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()

        if windows.isEmpty {
            if signedOut {
                addInfo("Not signed in to Claude")
            } else {
                addInfo(lastError.map { "Couldn't load usage: \(shorten($0))" } ?? "Loading usage…")
            }
        } else {
            let now = Date()
            for w in windows {
                let detail: String
                if let r = w.resetsAt {
                    detail = r > now
                        ? "Resets in \(countdown(to: r, from: now)) · \(resetFormatter.string(from: r))"
                        : "Resetting…"
                } else {
                    detail = w.key == "extra_usage" ? "Monthly extra usage" : "Not started yet"
                }
                let item = NSMenuItem()
                item.view = UsageRowView(title: w.title, percent: w.percent, detail: detail)
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            addInfo(lastUpdated.map { "Updated \(timeFormatter.string(from: $0))" } ?? "Not updated yet")
            if let e = lastError { addInfo("Last refresh failed: \(shorten(e))") }
        }

        menu.addItem(NSMenuItem.separator())
        addAction("Refresh Now", #selector(refresh), key: "r")
        addAction("Open Usage Page in Browser", #selector(openUsagePage))

        menu.addItem(NSMenuItem.separator())
        if signedOut || windows.isEmpty {
            addAction("Sign In to Claude…", #selector(showLogin))
        }
        addAction("Sign In with Session Key…", #selector(signInWithSessionKey))
        if !signedOut {
            addAction("Sign Out", #selector(signOut))
        }
        let launch = addAction("Launch at Login", #selector(toggleLaunchAtLogin))
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "Quit Usage Bar for Claude",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addInfo(_ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func shorten(_ text: String, to limit: Int = 70) -> String {
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    @objc private func openUsagePage() {
        NSWorkspace.shared.open(usagePageURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
                + "\n\nYou can also add the app yourself in System Settings > General > Login Items."
            alert.runModal()
        }
    }
}
