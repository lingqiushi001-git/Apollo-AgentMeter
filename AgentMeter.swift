import AppKit
import SwiftUI

// MARK: - Data Models

struct QuotaWindowStat: Equatable {
    var label: String
    var remainingInt: Int
    var resetsAt: Date?
    var countdownText: String

    var usedInt: Int {
        max(0, min(100, 100 - remainingInt))
    }

    var isDanger: Bool { usedInt > 80 }
    var isWarn: Bool { usedInt >= 60 && usedInt <= 80 }
}

struct QuotaCardModel: Equatable, Identifiable {
    let id: String
    let title: String
    var shortWindow: QuotaWindowStat?   // nil => Unlimited (∞)
    var weeklyWindow: QuotaWindowStat?
    var errorMessage: String?
    var isAvailable: Bool

    var maxUsedInt: Int {
        [shortWindow?.usedInt, weeklyWindow?.usedInt].compactMap { $0 }.max() ?? 0
    }
}

// MARK: - Glass Ledger Theme Palette

struct ThemePalette {
    let isDark: Bool

    var hudTint: Color { snapshotBg.opacity(isDark ? 0.84 : 0.86) }
    var snapshotBg: Color {
        isDark ? Color(red: 0.098, green: 0.106, blue: 0.125) : Color(red: 0.973, green: 0.976, blue: 0.984)
    }
    var primaryText: Color {
        isDark ? Color(red: 0.957, green: 0.961, blue: 0.969) : Color(red: 0.094, green: 0.106, blue: 0.125)
    }
    var secondaryText: Color {
        isDark ? Color(red: 0.631, green: 0.655, blue: 0.702) : Color(red: 0.322, green: 0.349, blue: 0.396)
    }
    var mutedText: Color {
        isDark ? Color(red: 0.443, green: 0.471, blue: 0.525) : Color(red: 0.482, green: 0.514, blue: 0.569)
    }
    var okColor: Color {
        isDark ? Color(red: 0.165, green: 0.616, blue: 0.561) : Color(red: 0.118, green: 0.510, blue: 0.463)
    }
    var warnColor: Color {
        isDark ? Color(red: 0.878, green: 0.541, blue: 0.118) : Color(red: 0.706, green: 0.325, blue: 0.035)
    }
    var dangerColor: Color {
        isDark ? Color(red: 0.878, green: 0.310, blue: 0.310) : Color(red: 0.784, green: 0.118, blue: 0.118)
    }
    var hairline: Color { (isDark ? Color.white : Color.black).opacity(0.085) }
    var trackBg: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    var chipBg: Color { isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.055) }

    func statusColor(usedInt: Int) -> Color {
        if usedInt > 80 { return dangerColor }
        if usedInt >= 60 { return warnColor }
        return okColor
    }
}

// MARK: - Formatting Helpers

func parseISO(_ str: String?) -> Date? {
    guard let s = str, !s.isEmpty else { return nil }
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

func fmtCountdown(_ date: Date?) -> String {
    guard let d = date else { return "重置时间未知" }
    let diff = Int(d.timeIntervalSinceNow)
    if diff <= 0 { return "即将重置" }
    let days = diff / 86400
    let hours = (diff % 86400) / 3600
    let mins = (diff % 3600) / 60
    if days > 0 { return "\(days)天\(hours)小时后重置" }
    if hours > 0 { return "\(hours)小时\(mins)分后重置" }
    return "\(max(1, mins))分钟后重置"
}

func fmtClockTime(_ date: Date?) -> String {
    guard let d = date else { return "--:--:--" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: d)
}

private func number(_ value: Any?) -> Double? {
    let n = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    return n.flatMap { $0.isFinite ? $0 : nil }
}

func parseQuotaTimestamp(_ raw: Any?) -> Date? {
    if let s = raw as? String { return parseISO(s) }
    if let obj = raw as? [String: Any], let seconds = number(obj["seconds"]) {
        return Date(timeIntervalSince1970: seconds + (number(obj["nanos"]) ?? 0) / 1e9)
    }
    return number(raw).map { Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) }
}

func parseRemainingFraction(_ bucket: [String: Any]) -> Double? {
    let nested = bucket["remaining"] as? [String: Any]
    let fraction = number(bucket["remainingFraction"]) ??
        (nested?["case"] as? String == "remainingFraction" ? number(nested?["value"]) : nil)
    if let fraction { return min(1, max(0, fraction)) }
    return bucket["resetTime"] != nil || bucket["description"] != nil ? 0 : nil
}

private final class LoopbackTLSDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           ["127.0.0.1", "localhost", "::1"].contains(space.host),
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Store (5-Minute Auto Refresh + Instant Manual Live Refresh)

final class QuotaStore: ObservableObject {
    @Published var codexCard = QuotaCardModel(
        id: "codex", title: "Codex",
        shortWindow: nil, weeklyWindow: nil, errorMessage: "正在读取…", isAvailable: false
    )
    @Published var antigravityCards: [QuotaCardModel] = []
    @Published var geminiShortRem: Int? = nil
    @Published var geminiWeekRem: Int? = nil
    @Published var lastRefresh: Date? = nil
    @Published var isRefreshing: Bool = false
    @Published var isDarkTheme: Bool {
        didSet {
            guard persistsTheme else { return }
            UserDefaults.standard.set(isDarkTheme, forKey: "agentmeter_dark_theme")
        }
    }

    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private var countdownTimer: Timer?

    @Published var antigravityStaleNotice: String?
    private let scanQueue = DispatchQueue(label: "agentmeter.quota", qos: .userInitiated)
    private var lastAntigravityLive = false
    private var lastAntigravityFailureReason: String?

    private let persistsTheme: Bool

    init(startTimers: Bool = true) {
        persistsTheme = startTimers
        if UserDefaults.standard.object(forKey: "agentmeter_dark_theme") == nil {
            self.isDarkTheme = true
        } else {
            self.isDarkTheme = UserDefaults.standard.bool(forKey: "agentmeter_dark_theme")
        }
        guard startTimers else { return }
        refreshAll()
        // Auto-refresh quota data every 5 minutes (300 seconds)
        timer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.refreshAll()
        }
        // Tick countdown labels every 30 seconds so remaining minutes always stay fresh in SwiftUI
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshCountdownsOnly()
        }
    }

    private func refreshCountdownsOnly() {
        scanQueue.async { self.scanAndPublish(refreshed: false) }
    }

    func refreshAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRefreshing else { return }
        isRefreshing = true
        scanQueue.async {
            let result = self.fetchLiveAntigravityQuotaIfPossible(forceRefresh: true)
            self.lastAntigravityLive = result.succeeded
            self.lastAntigravityFailureReason = result.failureReason
            self.scanAndPublish(refreshed: true)
        }
    }

    private func scanAndPublish(refreshed: Bool) {
        let cx = scanCodex()
        let (cards, short, week, notice) = scanAntigravityQuotaCache(
            isLive: lastAntigravityLive, failureReason: lastAntigravityFailureReason)
        DispatchQueue.main.async {
            self.codexCard = cx
            self.antigravityCards = cards
            self.geminiShortRem = short
            self.geminiWeekRem = week
            self.antigravityStaleNotice = notice
            if refreshed {
                self.lastRefresh = Date()
                self.isRefreshing = false
            }
            self.onUpdate?()
        }
    }

    private static var appCacheDirectory: String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches")
        let dir = "\(base)/io.github.agentmeter"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct LanguageServerCandidate: Hashable {
        let scheme: String
        let address: String
        let token: String?
        let source: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.scheme == rhs.scheme && lhs.address == rhs.address && (lhs.token ?? "") == (rhs.token ?? "")
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(scheme)
            hasher.combine(address)
            hasher.combine(token ?? "")
        }
    }

    private func cleanToken(_ raw: String?) -> String? {
        guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func extractFlagValue(_ flag: String, from tokens: [String]) -> String? {
        let prefix = "\(flag)="
        for i in 0..<tokens.count {
            if tokens[i] == flag, i + 1 < tokens.count {
                let val = tokens[i + 1]
                if !val.hasPrefix("-") { return val }
            } else if tokens[i].hasPrefix(prefix) {
                let val = String(tokens[i].dropFirst(prefix.count))
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    private func runCommandOutput(executable: String, arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        // Read stdout BEFORE waitUntilExit to avoid pipe buffer deadlocks when output > 64KB
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct ServerProcess {
        let pid: String
        let args: [String]
        let isACP: Bool
    }

    // ps flattens argv boundaries. Read the kernel argv for matching process names.
    private func arguments(pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return [] }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard count > 0, let end = bytes[4..<size].firstIndex(of: 0) else { return [] }
        var pos = end
        while pos < size && bytes[pos] == 0 { pos += 1 }
        var args: [String] = []
        while pos < size && args.count < count, let next = bytes[pos..<size].firstIndex(of: 0) {
            args.append(String(decoding: bytes[pos..<next], as: UTF8.self))
            pos = next + 1
        }
        return args
    }

    private func isAntigravityACPCommand(_ args: [String]) -> Bool {
        guard args.count >= 2, args[1] == "acp" else { return false }
        let name = URL(fileURLWithPath: args[0]).lastPathComponent
        return name == "antigravity" || name.hasPrefix("antigravity-")
    }

    private func listRunningProcesses() -> [ServerProcess] {
        let output = runCommandOutput(executable: "/bin/ps", arguments: ["-axww", "-o", "pid=,comm="])
        return output.split(separator: "\n").compactMap { line in
            guard line.contains("antigravity") || line.contains("language_server"),
                  let pid = line.split(whereSeparator: { $0.isWhitespace }).first.flatMap({ Int32($0) }) else { return nil }
            let args = arguments(pid: pid)
            guard let executable = args.first else { return nil }
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let acp = isAntigravityACPCommand(args)
            let legacy = (name == "language_server" || name.hasPrefix("language_server_")) &&
                (name.hasPrefix("language_server_macos") || args.contains { $0.localizedCaseInsensitiveContains("antigravity") })
            guard acp || legacy else { return nil }
            return ServerProcess(pid: String(pid), args: args, isACP: acp)
        }
    }

    private func discoverDaemonCandidates(extraAppDataDirs: [String]) -> [LanguageServerCandidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let geminiRoot = "\(home)/.gemini"

        var daemonDirs: [String] = []
        var seenDirs = Set<String>()
        func addDaemonDir(_ path: String) {
            let std = URL(fileURLWithPath: path).standardizedFileURL.path
            guard !seenDirs.contains(std) else { return }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: std, isDirectory: &isDir), isDir.boolValue {
                seenDirs.insert(std)
                daemonDirs.append(std)
            }
        }

        // Default Antigravity app_data_dir first
        addDaemonDir("\(geminiRoot)/antigravity/daemon")

        // Dynamically include any --app_data_dir seen on running language_server processes
        for dir in extraAppDataDirs {
            if dir.hasPrefix("/") {
                addDaemonDir("\(dir)/daemon")
            } else {
                addDaemonDir("\(geminiRoot)/\(dir)/daemon")
            }
        }

        // Also scan any sibling ~/.gemini/*/daemon directory for future/custom channels
        if let entries = try? fm.contentsOfDirectory(atPath: geminiRoot) {
            for entry in entries {
                addDaemonDir("\(geminiRoot)/\(entry)/daemon")
            }
        }

        var discovered: [(mtime: Date, candidate: LanguageServerCandidate)] = []
        for dir in daemonDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".json") {
                let fullPath = "\(dir)/\(file)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let token = cleanToken(json["csrfToken"] as? String)

                if let pidNum = json["pid"] as? NSNumber {
                    let pid = pidNum.int32Value
                    if pid > 0 && !isProcessAlive(pid) {
                        continue
                    }
                }

                let mtime = (try? fm.attributesOfItem(atPath: fullPath)[.modificationDate] as? Date) ?? .distantPast
                for scheme in ["http", "https"] {
                    if let port = json["\(scheme)Port"] as? Int, (1...65535).contains(port) {
                        discovered.append((mtime, LanguageServerCandidate(scheme: scheme, address: "127.0.0.1:\(port)", token: token, source: "daemon")))
                    }
                }
            }
        }
        discovered.sort { lhs, rhs in
            if lhs.mtime != rhs.mtime { return lhs.mtime > rhs.mtime }
            return lhs.candidate.scheme < rhs.candidate.scheme
        }
        return discovered.map { $0.candidate }
    }

    private func listenerCandidates(_ processes: [ServerProcess], acp: Bool) -> [LanguageServerCandidate] {
        var result: [LanguageServerCandidate] = []
        for proc in processes where proc.isACP == acp {
            let token = cleanToken(extractFlagValue("--csrf_token", from: proc.args))
            guard acp || token != nil else { continue }
            let output = runCommandOutput(executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", proc.pid, "-Fn"])
            for line in output.split(separator: "\n") where line.hasPrefix("n") {
                let address = String(line.dropFirst())
                for scheme in ["http", "https"] {
                    result.append(LanguageServerCandidate(scheme: scheme, address: address, token: token, source: acp ? "acp" : "language_server"))
                }
            }
        }
        return result.sorted { $0.scheme < $1.scheme }
    }

    private func discoverLiveLanguageServerCandidates() -> [LanguageServerCandidate] {
        var ordered: [LanguageServerCandidate] = []
        var seen = Set<LanguageServerCandidate>()
        func append(_ c: LanguageServerCandidate) {
            guard ["http", "https"].contains(c.scheme),
                  c.address.range(of: #"^(127\.0\.0\.1|localhost|\[::1\]):[0-9]{1,5}$"#, options: .regularExpression) != nil,
                  let port = c.address.split(separator: ":").last.flatMap({ UInt16($0) }), port > 0,
                  seen.insert(c).inserted else { return }
            ordered.append(c)
        }

        let env = ProcessInfo.processInfo.environment
        if let address = env["ANTIGRAVITY_LS_ADDRESS"] {
            let parts = address.components(separatedBy: "://")
            let schemes = parts.count == 1 ? ["http", "https"] : [parts[0].lowercased()]
            for scheme in schemes {
                append(LanguageServerCandidate(scheme: scheme, address: parts.last ?? "", token: cleanToken(env["ANTIGRAVITY_CSRF_TOKEN"]), source: "env"))
            }
        }
        let processes = listRunningProcesses()
        let directories = processes.compactMap { proc -> String? in
            func flag(_ name: String) -> String? {
                extractFlagValue(name, from: proc.args) ?? extractFlagValue(name.replacingOccurrences(of: "_", with: "-"), from: proc.args)
            }
            guard let appDir = flag("--app_data_dir") else { return nil }
            if !appDir.hasPrefix("/"), let root = flag("--gemini_dir") {
                return URL(fileURLWithPath: root).appendingPathComponent(appDir).path
            }
            return appDir
        }
        discoverDaemonCandidates(extraAppDataDirs: directories).forEach(append)
        listenerCandidates(processes, acp: true).forEach(append)
        listenerCandidates(processes, acp: false).forEach(append)

        let connPath = "\(Self.appCacheDirectory)/ls_conn.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: connPath)),
           let conn = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let address = conn["address"] as? String {
            append(LanguageServerCandidate(scheme: conn["scheme"] as? String ?? "http", address: address,
                token: cleanToken(conn["token"] as? String), source: "cache"))
        }
        return ordered
    }

    private struct LiveFetchResult {
        let candidates: [LanguageServerCandidate]
        var winner: LanguageServerCandidate?
        var attemptedCount = 0
        var failureReason: String?
        var succeeded: Bool { winner != nil }
    }

    private final class RPCReply: @unchecked Sendable {
        var status = 0
        var data = Data()
    }

    private func fetchLiveAntigravityQuotaIfPossible(forceRefresh: Bool) -> LiveFetchResult {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2.5
        let session = URLSession(configuration: config, delegate: LoopbackTLSDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var result = LiveFetchResult(candidates: discoverLiveLanguageServerCandidates())
        var authFailed = false
        for c in result.candidates {
            guard let url = URL(string: "\(c.scheme)://\(c.address)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            result.attemptedCount += 1
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            if let token = c.token {
                req.setValue(token, forHTTPHeaderField: "x-antigravity-csrf-token")
                req.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
            }
            for force in forceRefresh ? [true, false] : [false] {
                req.httpBody = Data((force ? #"{"forceRefresh":true}"# : "{}").utf8)
                let sem = DispatchSemaphore(value: 0)
                let reply = RPCReply()
                let task = session.dataTask(with: req) { data, response, _ in
                    reply.status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    reply.data = data ?? Data()
                    sem.signal()
                }
                task.resume()
                guard sem.wait(timeout: .now() + 2.5) == .success else { task.cancel(); break }
                if force, [400, 422, 500].contains(reply.status),
                   !String(decoding: reply.data, as: UTF8.self).localizedCaseInsensitiveContains("https") { continue }
                if [401, 403].contains(reply.status) { authFailed = true }
                guard reply.status == 200,
                      let json = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
                      let resp = json["response"] as? [String: Any], resp["groups"] is [[String: Any]] else { break }
                let dir = URL(fileURLWithPath: Self.appCacheDirectory)
                let wrapper: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()), "source": c.source, "response": resp]
                var conn = ["scheme": c.scheme, "address": c.address]
                conn["token"] = c.token
                do {
                    try JSONSerialization.data(withJSONObject: conn).write(to: dir.appendingPathComponent("ls_conn.json"), options: .atomic)
                    try JSONSerialization.data(withJSONObject: wrapper).write(to: dir.appendingPathComponent("quota_summary_cache.json"), options: .atomic)
                    result.winner = c
                } catch { result.failureReason = "无法写入 Antigravity 本地缓存" }
                return result
            }
        }
        if result.candidates.isEmpty { result.failureReason = "未发现 Antigravity 进程或本地服务" }
        else if authFailed { result.failureReason = "Antigravity 令牌认证失败（HTTP 401/403）" }
        else { result.failureReason = "Antigravity 连接或额度接口失败（已尝试 \(result.attemptedCount) 个端点）" }
        return result
    }

    func probe() -> Bool {
        let result = fetchLiveAntigravityQuotaIfPossible(forceRefresh: true)
        let (cards, short, week, notice) = scanAntigravityQuotaCache(isLive: result.succeeded, failureReason: result.failureReason)
        let codex = scanCodex()
        print("candidatesCount=\(result.candidates.count) attemptedCount=\(result.attemptedCount)")
        for c in result.candidates { print("candidate \(c.source) \(c.scheme)://\(c.address) hasToken=\(c.token != nil)") }
        if let c = result.winner { print("winner \(c.source) \(c.scheme)://\(c.address)") }
        if let reason = result.failureReason { print(reason) }
        if let notice { print(notice) }
        for card in cards {
            // Only expose known model labels in diagnostics.
            let title = ["Gemini", "Gemini 4 Argon", "Claude / GPT"].contains(card.title) ? card.title : "Antigravity"
            let windows = [card.shortWindow, card.weeklyWindow].compactMap { $0 }.map { "\($0.label) \($0.remainingInt)% \($0.countdownText)" }
            print(([title] + windows).joined(separator: " | "))
        }
        print("Gemini 5h=\(short.map(String.init) ?? "--")% 7d=\(week.map(String.init) ?? "--")% Codex available=\(codex.isAvailable)")
        return result.succeeded
    }

    // 1. Codex from ~/.codex/sessions/
    private func scanCodex() -> QuotaCardModel {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.codex/sessions"
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dir) else {
            return QuotaCardModel(id: "codex", title: "Codex", shortWindow: nil, weeklyWindow: nil, errorMessage: "未找到 ~/.codex/sessions", isAvailable: false)
        }

        var files: [(path: String, mtime: Date)] = []
        while let rel = enumerator.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let full = "\(dir)/\(rel)"
            if let attrs = try? fm.attributesOfItem(atPath: full),
               let mtime = attrs[.modificationDate] as? Date,
               let size = attrs[.size] as? Int64, size > 0 {
                files.append((full, mtime))
            }
        }
        files.sort { $0.mtime > $1.mtime }

        for f in files.prefix(15) {
            guard let content = try? String(contentsOfFile: f.path, encoding: .utf8) else { continue }
            var foundRL: [String: Any]? = nil
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.contains("rate_limits"),
                      let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                foundRL = rl
            }

            if let rl = foundRL {
                func parseBucket(_ key: String) -> (mins: Int, stat: QuotaWindowStat)? {
                    guard let w = rl[key] as? [String: Any],
                          let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                    let label = mins >= 1440 ? "7 天周窗" : "5h 短窗"
                    var resetDate: Date? = nil
                    if let ts = (w["resets_at"] as? NSNumber)?.doubleValue {
                        resetDate = Date(timeIntervalSince1970: ts)
                    }
                    var usedClamped = max(0, min(100, Int(used.rounded())))
                    // If the recorded reset time in the local log has already passed, the window has reset to 100%
                    if let rd = resetDate, Date() >= rd {
                        usedClamped = 0
                        if mins > 0 {
                            let step = Double(mins) * 60.0
                            var nextReset = rd
                            while nextReset <= Date() {
                                nextReset = nextReset.addingTimeInterval(step)
                            }
                            resetDate = nextReset
                        }
                    }
                    let remInt = 100 - usedClamped
                    return (mins, QuotaWindowStat(
                        label: label,
                        remainingInt: remInt,
                        resetsAt: resetDate,
                        countdownText: fmtCountdown(resetDate)
                    ))
                }

                var shortW: QuotaWindowStat? = nil
                var weekW: QuotaWindowStat? = nil
                for item in [parseBucket("primary"), parseBucket("secondary")].compactMap({ $0 }) {
                    if item.mins >= 1440 { weekW = item.stat } else { shortW = item.stat }
                }

                return QuotaCardModel(
                    id: "codex",
                    title: "Codex",
                    shortWindow: shortW,
                    weeklyWindow: weekW,
                    errorMessage: nil,
                    isAvailable: shortW != nil || weekW != nil
                )
            }
        }

        return QuotaCardModel(id: "codex", title: "Codex", shortWindow: nil, weeklyWindow: nil, errorMessage: "近期会话无额度记录", isAvailable: false)
    }

    // 2. Antigravity Model Groups from quota_summary_cache.json
    private func scanAntigravityQuotaCache(isLive: Bool, failureReason: String?) -> ([QuotaCardModel], Int?, Int?, String?) {
        let cachePath = "\(Self.appCacheDirectory)/quota_summary_cache.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["response"] as? [String: Any],
              let groups = resp["groups"] as? [[String: Any]] else {
            return ([
                QuotaCardModel(
                    id: "ag-empty", title: "Antigravity",
                    shortWindow: nil, weeklyWindow: nil,
                    errorMessage: failureReason ?? "正在等待 Antigravity 同步模型额度…", isAvailable: false
                )
            ], nil, nil, nil)
        }

        var cards: [QuotaCardModel] = []
        var gmShort: Int? = nil
        var gmWeek: Int? = nil

        let updated = parseQuotaTimestamp(root["updatedAt"])
        let now = Date()
        for (idx, g) in groups.enumerated() {
            let rawName = (g["displayName"] as? String) ?? "Antigravity Models"
            let buckets = (g["buckets"] as? [[String: Any]] ?? []).filter { $0["disabled"] as? Bool != true }
            let identity = ([rawName] + buckets.compactMap { $0["bucketId"] as? String }).joined(separator: " ").lowercased()
            let title: String
            if identity.contains("argon") { title = "Gemini 4 Argon" }
            else if identity.range(of: #"claude|gpt|\b3p\b"#, options: .regularExpression) != nil { title = "Claude / GPT" }
            else if identity.contains("gemini") { title = "Gemini" }
            else { title = rawName }

            var shortW: QuotaWindowStat?
            var weekW: QuotaWindowStat?
            for b in buckets {
                guard let fraction = parseRemainingFraction(b) else { continue }
                let win = ["window", "bucketId"].compactMap { b[$0] as? String }.joined(separator: " ").lowercased()
                let weekly = win.contains("week") || win.contains("7d")
                guard weekly || win.contains("5h") || win.contains("five") else { continue }
                let rem = Int((fraction * 100).rounded())
                let reset = parseQuotaTimestamp(b["resetTime"])
                var stat = QuotaWindowStat(label: weekly ? "7 天周窗" : "5h 短窗", remainingInt: rem,
                    resetsAt: reset, countdownText: rem == 100 && reset == nil ? "未使用（满额）" : fmtCountdown(reset))
                if !isLive, let reset, now >= reset, rem < 100, updated.map({ $0 < reset }) ?? true {
                    stat.remainingInt = 100
                    stat.resetsAt = nil
                    stat.countdownText = "已过重置时间（按缓存推算已满）"
                }
                if weekly { weekW = stat } else { shortW = stat }
            }
            guard shortW != nil || weekW != nil else { continue }
            if title == "Gemini" {
                gmShort = shortW?.remainingInt
                gmWeek = weekW?.remainingInt
            }

            cards.append(
                QuotaCardModel(
                    id: "ag-\(idx)-\(rawName)",
                    title: title,
                    shortWindow: shortW,
                    weeklyWindow: weekW,
                    errorMessage: nil,
                    isAvailable: shortW != nil || weekW != nil
                )
            )
        }

        if cards.isEmpty {
            cards.append(QuotaCardModel(id: "ag-empty", title: "Antigravity", shortWindow: nil, weeklyWindow: nil,
                errorMessage: failureReason ?? "暂无可用模型额度", isAvailable: false))
        }
        let notice = "Antigravity 离线，显示缓存" + (updated.map { "（更新于 \(fmtClockTime($0))）" } ?? "")
        return (cards, gmShort, gmWeek, isLive ? nil : notice)
    }
}

// MARK: - Native AppKit Drag Handle View (100% Reliable Window Dragging)

final class WindowDragNSView: NSView {
    private var initialMouseLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        initialMouseLocation = NSEvent.mouseLocation
        initialWindowOrigin = win.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let cur = NSEvent.mouseLocation
        let newOrigin = NSPoint(
            x: initialWindowOrigin.x + (cur.x - initialMouseLocation.x),
            y: initialWindowOrigin.y + (cur.y - initialMouseLocation.y)
        )
        win.setFrameOrigin(newOrigin)
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

// MARK: - SwiftUI Views

struct VisualEffectBackground: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = isDark ? .hudWindow : .popover
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

private struct LedgerQuotaSection: View {
    let card: QuotaCardModel
    let palette: ThemePalette

    private var color: Color {
        card.isAvailable ? palette.statusColor(usedInt: card.maxUsedInt) : palette.mutedText
    }

    private func meter(_ label: String, _ stat: QuotaWindowStat?) -> some View {
        let tint = stat.map { palette.statusColor(usedInt: $0.usedInt) } ?? palette.okColor
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11)).foregroundColor(palette.secondaryText)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.trackBg)
                    if let stat {
                        Capsule().fill(tint)
                            .frame(width: stat.remainingInt > 0 ? max(4, geometry.size.width * CGFloat(stat.remainingInt) / 100) : 0)
                    } else {
                        Capsule().fill(tint.opacity(0.48))
                    }
                }
            }.frame(height: 4.5)
            Text(stat.map { "\($0.remainingInt)%" } ?? "∞")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(tint).frame(width: 42, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(card.title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(palette.primaryText)
                Spacer()
                if card.isAvailable && card.maxUsedInt >= 60 {
                    Text(card.maxUsedInt > 80 ? "已用 \(card.maxUsedInt)%" : "预警")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(color).padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(color.opacity(0.14), in: Capsule())
                }
            }
            if card.isAvailable {
                meter("5h 短窗", card.shortWindow).padding(.top, 7)
                meter("7 天周窗", card.weeklyWindow).padding(.top, 7)
                HStack {
                    Text("5h \(card.shortWindow?.countdownText ?? "无限制")")
                    Spacer(minLength: 8)
                    Text("7d \(card.weeklyWindow?.countdownText ?? "无限制")")
                }
                .font(.system(size: 10, design: .monospaced)).foregroundColor(palette.mutedText)
                .lineLimit(1).minimumScaleFactor(0.85).padding(.top, 2)
            } else {
                Text(card.errorMessage ?? "暂无额度数据")
                    .font(.system(size: 11)).foregroundColor(palette.secondaryText).padding(.top, 7)
            }
        }
        .padding(.vertical, 11).padding(.leading, 17).padding(.trailing, 14)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 10)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    let hideWindow: () -> Void
    let quitApp: () -> Void
    var snapshot = false

    private var palette: ThemePalette { ThemePalette(isDark: store.isDarkTheme) }
    private var hasQuota: Bool { store.antigravityCards.contains(where: { $0.isAvailable }) }
    @ViewBuilder private var dragArea: some View {
        if !snapshot { WindowDragArea() }
    }

    private func iconButton(_ symbol: String, _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(palette.secondaryText)
                .frame(width: 24, height: 24)
                .background(palette.chipBg,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var topBar: some View {
        HStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundColor(palette.okColor)
                Text("Apollo AgentMeter").font(.system(size: 13, weight: .semibold)).foregroundColor(palette.primaryText)
                Circle().fill(hasQuota ? (store.antigravityStaleNotice == nil ? palette.okColor : palette.warnColor) : palette.mutedText)
                    .frame(width: 6, height: 6)
                Spacer()
            }.overlay { dragArea }
            iconButton("arrow.clockwise", "手动立即刷新", action: store.refreshAll)
                .opacity(store.isRefreshing ? 0.55 : 1)
            iconButton(store.isDarkTheme ? "sun.max.fill" : "moon.fill", "切换深浅色主题") { store.isDarkTheme.toggle() }
            iconButton("minus", "收起到状态栏", action: hideWindow)
            iconButton("power", "退出 AgentMeter", action: quitApp)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background { dragArea }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13)
        VStack(spacing: 0) {
            topBar
            palette.hairline.frame(height: 1)
            VStack(spacing: 0) {
                if let notice = store.antigravityStaleNotice, hasQuota {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text(notice).font(.system(size: 10.5))
                    }
                    .foregroundColor(palette.warnColor).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 7).background(palette.warnColor.opacity(0.13))
                    palette.hairline.frame(height: 1)
                }
                ForEach([store.codexCard] + store.antigravityCards) { card in
                    LedgerQuotaSection(card: card, palette: palette)
                    palette.hairline.frame(height: 1)
                }
                HStack {
                    Text("刷新 \(fmtClockTime(store.lastRefresh)) · 5分钟自动").font(.system(size: 10, design: .monospaced))
                    Spacer()
                    Text("按住任意处拖动").font(.system(size: 10))
                }.foregroundColor(palette.mutedText).padding(.horizontal, 14).padding(.vertical, 9)
            }.overlay { dragArea }
        }
        .frame(width: 356)
        .background {
            if snapshot {
                palette.snapshotBg
            } else {
                ZStack {
                    VisualEffectBackground(isDark: store.isDarkTheme)
                    palette.hudTint
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.hairline, lineWidth: 1).allowsHitTesting(false) }
    }
}

// MARK: - Custom Draggable Panel Subclass

final class DraggableFloatingPanel: NSPanel {
    var isUserExpanded: Bool = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func orderFront(_ sender: Any?) {
        guard isUserExpanded else { return }
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        guard isUserExpanded else { return }
        super.orderFrontRegardless()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard isUserExpanded else { return }
        super.makeKeyAndOrderFront(sender)
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out && !isUserExpanded {
            return
        }
        super.order(place, relativeTo: otherWin)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var floatingPanel: DraggableFloatingPanel?
    private let store = QuotaStore()

    private let posXKey = "agentmeter_panel_x"
    private let posYKey = "agentmeter_panel_y"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(toggleFloatingWindow)
            btn.target = self
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AgentMeter") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                btn.image = img.withSymbolConfiguration(cfg)
                btn.imagePosition = .imageLeading
            }
        }

        store.onUpdate = { [weak self] in
            self?.updateStatusTitle()
            self?.resizePanelIfNeeded()
        }

        // Start collapsed in the menu bar; only open when user explicitly clicks the status item
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        guard let btn = statusItem?.button else { return }

        // Format: Codex ∞/3% · Gemini 3%/72%
        let cx5h = store.codexCard.shortWindow.map { "\($0.remainingInt)%" } ?? "∞"
        let cxWeek = store.codexCard.weeklyWindow.map { "\($0.remainingInt)%" } ?? "--"

        let gm5h = store.geminiShortRem.map { "\($0)%" } ?? "--"
        let gmWeek = store.geminiWeekRem.map { "\($0)%" } ?? "--"

        btn.title = "Codex \(cx5h)/\(cxWeek) · Gemini \(gm5h)/\(gmWeek)"
    }

    private func resizePanelIfNeeded() {
        guard let panel = floatingPanel,
              panel.isUserExpanded,
              panel.isVisible,
              let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let newSize = view.fittingSize
        let oldFrame = panel.frame
        if abs(oldFrame.width - newSize.width) > 2 || abs(oldFrame.height - newSize.height) > 2 {
            let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var newY = oldFrame.maxY - newSize.height
            newY = min(max(newY, visible.minY + 8), visible.maxY - newSize.height - 8)
            let newX = min(max(oldFrame.maxX - newSize.width, visible.minX + 8), visible.maxX - newSize.width - 8)
            panel.setFrame(NSRect(x: newX, y: newY, width: newSize.width, height: newSize.height), display: true)
        }
    }

    private func collapseFloatingWindow() {
        guard let panel = floatingPanel else { return }
        panel.isUserExpanded = false
        panel.orderOut(nil)
    }

    @objc private func toggleFloatingWindow() {
        if let panel = floatingPanel, panel.isUserExpanded && panel.isVisible {
            collapseFloatingWindow()
        } else {
            store.refreshAll()
            showFloatingWindow()
        }
    }

    private func showFloatingWindow() {
        if floatingPanel == nil {
            let hosting = NSHostingController(
                rootView: DashboardView(
                    store: store,
                    hideWindow: { [weak self] in self?.collapseFloatingWindow() },
                    quitApp: { NSApp.terminate(nil) }
                )
            )
            hosting.view.layoutSubtreeIfNeeded()
            let size = hosting.view.fittingSize

            let panel = DraggableFloatingPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovable = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.contentViewController = hosting

            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var origin = NSPoint(
                x: visible.maxX - size.width - 20,
                y: visible.maxY - size.height - 20
            )
            if UserDefaults.standard.object(forKey: posXKey) != nil && UserDefaults.standard.object(forKey: posYKey) != nil {
                let savedX = UserDefaults.standard.double(forKey: posXKey)
                let savedY = UserDefaults.standard.double(forKey: posYKey)
                let clampedX = min(max(savedX, visible.minX + 8), visible.maxX - size.width - 8)
                let clampedY = min(max(savedY, visible.minY + 8), visible.maxY - size.height - 8)
                origin = NSPoint(x: clampedX, y: clampedY)
            }
            panel.setFrame(NSRect(origin: origin, size: size), display: true)

            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self, weak panel] _ in
                guard let self = self, let p = panel else { return }
                UserDefaults.standard.set(Double(p.frame.origin.x), forKey: self.posXKey)
                UserDefaults.standard.set(Double(p.frame.origin.y), forKey: self.posYKey)
            }

            floatingPanel = panel
        }
        floatingPanel?.isUserExpanded = true
        floatingPanel?.orderFrontRegardless()
        resizePanelIfNeeded()
    }
}

if CommandLine.arguments.contains("--probe") {
    exit(QuotaStore(startTimers: false).probe() ? 0 : 1)
}

@MainActor
private func writeSnapshots(store: QuotaStore, directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for dark in [true, false] {
        store.isDarkTheme = dark
        let renderer = ImageRenderer(content: DashboardView(store: store, hideWindow: {}, quitApp: {}, snapshot: true))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = directory.appendingPathComponent(dark ? "dark.png" : "light.png")
        try png.write(to: destination, options: .atomic)
        print(destination.path)
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.dropFirst(index + 1).first ?? ".apollo-ui/agentmeter-redesign/shots"
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    _ = NSApplication.shared
    let store = QuotaStore(startTimers: false)
    store.onUpdate = {
        Task { @MainActor in
            do {
                try writeSnapshots(store: store, directory: directory)
                exit(0)
            } catch {
                fputs("无法写入面板截图。\n", stderr)
                exit(1)
            }
        }
    }
    store.refreshAll()
    RunLoop.main.run()
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
