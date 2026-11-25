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

// MARK: - High-Contrast Theme Palette

struct ThemePalette {
    let isDark: Bool

    var windowBg: Color {
        isDark ? Color(red: 0.06, green: 0.08, blue: 0.12) : Color(red: 0.96, green: 0.97, blue: 0.99)
    }
    var cardBg: Color {
        isDark ? Color(red: 0.11, green: 0.14, blue: 0.20) : Color.white
    }
    var cardBorder: Color {
        isDark ? Color(red: 0.20, green: 0.25, blue: 0.35) : Color(red: 0.82, green: 0.86, blue: 0.91)
    }
    var primaryText: Color {
        isDark ? Color(red: 0.97, green: 0.98, blue: 1.00) : Color(red: 0.06, green: 0.09, blue: 0.16)
    }
    var secondaryText: Color {
        isDark ? Color(red: 0.78, green: 0.83, blue: 0.90) : Color(red: 0.28, green: 0.35, blue: 0.44)
    }
    var mutedText: Color {
        isDark ? Color(red: 0.58, green: 0.65, blue: 0.75) : Color(red: 0.45, green: 0.51, blue: 0.60)
    }
    var trackBg: Color {
        isDark ? Color(red: 0.18, green: 0.22, blue: 0.31) : Color(red: 0.88, green: 0.91, blue: 0.95)
    }
    var divider: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    var chipBg: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }
    var accentBlue: Color {
        isDark ? Color(red: 0.38, green: 0.68, blue: 1.00) : Color(red: 0.12, green: 0.42, blue: 0.92)
    }
    var okColor: Color {
        isDark ? Color(red: 0.20, green: 0.85, blue: 0.52) : Color(red: 0.06, green: 0.62, blue: 0.35)
    }
    var warnColor: Color {
        isDark ? Color(red: 0.99, green: 0.73, blue: 0.20) : Color(red: 0.82, green: 0.48, blue: 0.02)
    }
    var dangerColor: Color {
        isDark ? Color(red: 1.00, green: 0.36, blue: 0.38) : Color(red: 0.84, green: 0.14, blue: 0.18)
    }

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
            UserDefaults.standard.set(isDarkTheme, forKey: "agentmeter_dark_theme")
        }
    }

    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private var countdownTimer: Timer?

    init() {
        if UserDefaults.standard.object(forKey: "agentmeter_dark_theme") == nil {
            self.isDarkTheme = true
        } else {
            self.isDarkTheme = UserDefaults.standard.bool(forKey: "agentmeter_dark_theme")
        }
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let cx = self.scanCodex()
            let (agCards, gm5h, gmWeek) = self.scanAntigravityQuotaCache()
            DispatchQueue.main.async {
                if self.codexCard != cx { self.codexCard = cx }
                if self.antigravityCards != agCards { self.antigravityCards = agCards }
                self.geminiShortRem = gm5h
                self.geminiWeekRem = gmWeek
                self.onUpdate?()
            }
        }
    }

    func refreshAll() {
        DispatchQueue.main.async {
            self.isRefreshing = true
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // 1. Try live fetch from Antigravity Language Server first so data is 100% up-to-date
            self.fetchLiveAntigravityQuotaIfPossible()
            // 2. Scan Codex local logs & updated Antigravity quota cache
            let cx = self.scanCodex()
            let (agCards, gm5h, gmWeek) = self.scanAntigravityQuotaCache()
            DispatchQueue.main.async {
                self.codexCard = cx
                self.antigravityCards = agCards
                self.geminiShortRem = gm5h
                self.geminiWeekRem = gmWeek
                self.lastRefresh = Date()
                self.isRefreshing = false
                self.onUpdate?()
            }
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
        let address: String
        let token: String
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func extractFlagValue(_ flag: String, from command: String) -> String? {
        let prefix = "\(flag)="
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
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

    private func listRunningProcesses() -> [(pid: String, command: String)] {
        let out = runCommandOutput(executable: "/bin/ps", arguments: ["-ax", "-o", "pid=,command="])
        var result: [(pid: String, command: String)] = []
        for rawLine in out.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pid = String(trimmed[..<spaceIdx])
            let command = trimmed[spaceIdx...].trimmingCharacters(in: .whitespaces)
            if !pid.isEmpty && !command.isEmpty {
                result.append((pid, command))
            }
        }
        return result
    }

    private func isAntigravityLanguageServerCommand(_ command: String) -> Bool {
        let execPart: String
        if let flagRange = command.range(of: " -") {
            execPart = String(command[..<flagRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else {
            execPart = command.trimmingCharacters(in: .whitespaces)
        }
        let execName = URL(fileURLWithPath: execPart).lastPathComponent
        let isLanguageServerBinary = (execName == "language_server") || execName.hasPrefix("language_server_")
        guard isLanguageServerBinary else { return false }
        return command.localizedCaseInsensitiveContains("antigravity") || execName.hasPrefix("language_server_macos")
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
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = json["csrfToken"] as? String, !token.isEmpty else { continue }

                if let pidNum = json["pid"] as? NSNumber {
                    let pid = pidNum.int32Value
                    if pid > 0 && !isProcessAlive(pid) {
                        continue
                    }
                }

                let mtime = (try? fm.attributesOfItem(atPath: fullPath)[.modificationDate] as? Date) ?? .distantPast
                if let httpPort = (json["httpPort"] as? NSNumber)?.intValue, httpPort > 0 {
                    discovered.append((mtime, LanguageServerCandidate(address: "127.0.0.1:\(httpPort)", token: token)))
                }
            }
        }

        discovered.sort { $0.mtime > $1.mtime }
        return discovered.map { $0.candidate }
    }

    private func discoverProcessCandidates(from processes: [(pid: String, command: String)]) -> [LanguageServerCandidate] {
        var candidates: [LanguageServerCandidate] = []
        for proc in processes {
            guard isAntigravityLanguageServerCommand(proc.command),
                  let csrf = extractFlagValue("--csrf_token", from: proc.command),
                  !csrf.isEmpty else { continue }

            let lsofOut = runCommandOutput(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", proc.pid]
            )
            for lline in lsofOut.split(separator: "\n") {
                let ls = String(lline)
                if let r = ls.range(of: "(?:127\\.0\\.0\\.1|localhost):\\d+", options: .regularExpression) {
                    candidates.append(LanguageServerCandidate(address: String(ls[r]), token: csrf))
                }
            }
        }
        return candidates
    }

    /// Auto-discovers candidate local Antigravity Language Server endpoints across versions (2.x daemon JSON & legacy CLI)
    /// without relying on any machine-specific paths, ports, or binary names.
    private func discoverLiveLanguageServerCandidates() -> [LanguageServerCandidate] {
        var ordered: [LanguageServerCandidate] = []
        var seen = Set<LanguageServerCandidate>()
        func appendUnique(_ c: LanguageServerCandidate) {
            guard !c.address.isEmpty, !c.token.isEmpty, !seen.contains(c) else { return }
            seen.insert(c)
            ordered.append(c)
        }

        // 1. Optional environment overrides
        let env = ProcessInfo.processInfo.environment
        if let addr = env["ANTIGRAVITY_LS_ADDRESS"], !addr.isEmpty,
           let token = env["ANTIGRAVITY_CSRF_TOKEN"], !token.isEmpty {
            appendUnique(LanguageServerCandidate(address: addr, token: token))
        }

        // 2. Inspect running processes once to discover custom --app_data_dir and legacy CLI tokens
        let processes = listRunningProcesses()
        var extraAppDataDirs: [String] = []
        for proc in processes where isAntigravityLanguageServerCommand(proc.command) {
            if let appDataDir = extractFlagValue("--app_data_dir", from: proc.command), !appDataDir.isEmpty {
                extraAppDataDirs.append(appDataDir)
            }
        }

        // 3. Antigravity 2.x+ daemon metadata files (~/.gemini/<app_data_dir>/daemon/*.json)
        for c in discoverDaemonCandidates(extraAppDataDirs: extraAppDataDirs) {
            appendUnique(c)
        }

        // 4. Legacy Antigravity process CLI (--csrf_token) + lsof listening ports
        for c in discoverProcessCandidates(from: processes) {
            appendUnique(c)
        }

        // 5. Fallback to cached ls_conn.json if present
        let connPath = "\(Self.appCacheDirectory)/ls_conn.json"
        if let connData = try? Data(contentsOf: URL(fileURLWithPath: connPath)),
           let conn = try? JSONSerialization.jsonObject(with: connData) as? [String: Any],
           let address = conn["address"] as? String, !address.isEmpty,
           let token = conn["token"] as? String, !token.isEmpty {
            appendUnique(LanguageServerCandidate(address: address, token: token))
        }

        return ordered
    }

    /// Queries candidate local Antigravity Language Server endpoints and updates `quota_summary_cache.json` atomically.
    private func fetchLiveAntigravityQuotaIfPossible() {
        let baseDir = Self.appCacheDirectory
        let cachePath = "\(baseDir)/quota_summary_cache.json"
        let connPath = "\(baseDir)/ls_conn.json"

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [:]
        sessionConfig.timeoutIntervalForRequest = 3.0
        sessionConfig.timeoutIntervalForResource = 3.5
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let candidates = discoverLiveLanguageServerCandidates()
        for candidate in candidates {
            guard let url = URL(string: "http://\(candidate.address)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
                continue
            }

            var req = URLRequest(url: url, timeoutInterval: 3.0)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            req.setValue(candidate.token, forHTTPHeaderField: "x-antigravity-csrf-token")
            req.setValue(candidate.token, forHTTPHeaderField: "x-codeium-csrf-token")
            req.httpBody = Data("{}".utf8)

            var succeeded = false
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: req) { data, resp, _ in
                defer { sem.signal() }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let responseObj = json["response"] as? [String: Any],
                      responseObj["groups"] is [[String: Any]] else {
                    return
                }
                let wrapper: [String: Any] = [
                    "updatedAt": ISO8601DateFormatter().string(from: Date()),
                    "response": responseObj
                ]
                if let outData = try? JSONSerialization.data(withJSONObject: wrapper) {
                    try? outData.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
                }
                let connObj: [String: Any] = ["address": candidate.address, "token": candidate.token]
                if let connData = try? JSONSerialization.data(withJSONObject: connObj) {
                    try? connData.write(to: URL(fileURLWithPath: connPath), options: .atomic)
                }
                succeeded = true
            }.resume()
            _ = sem.wait(timeout: .now() + 3.5)

            if succeeded {
                return
            }
        }
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
    private func scanAntigravityQuotaCache() -> ([QuotaCardModel], Int?, Int?) {
        let cachePath = "\(Self.appCacheDirectory)/quota_summary_cache.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["response"] as? [String: Any],
              let groups = resp["groups"] as? [[String: Any]] else {
            return ([
                QuotaCardModel(
                    id: "ag-empty", title: "Antigravity",
                    shortWindow: nil, weeklyWindow: nil,
                    errorMessage: "正在等待 Antigravity 同步模型额度…", isAvailable: false
                )
            ], nil, nil)
        }

        var cards: [QuotaCardModel] = []
        var gmShort: Int? = nil
        var gmWeek: Int? = nil

        for (idx, g) in groups.enumerated() {
            let rawName = (g["displayName"] as? String) ?? "Antigravity Models"
            let title: String
            if rawName == "Gemini Models" {
                title = "Gemini 模型"
            } else if rawName == "Claude and GPT models" {
                title = "Claude / GPT 模型"
            } else if rawName == "Gemini 4 Argon" {
                title = "Gemini 4 Argon"
            } else {
                title = rawName
            }

            let buckets = (g["buckets"] as? [[String: Any]]) ?? []
            var shortW: QuotaWindowStat? = nil
            var weekW: QuotaWindowStat? = nil

            for b in buckets {
                let win = (b["window"] as? String) ?? ""
                let frac = (b["remainingFraction"] as? NSNumber)?.doubleValue ?? 0.0
                let remInt = max(0, min(100, Int((frac * 100.0).rounded())))
                let resetDate = parseISO(b["resetTime"] as? String)

                if win == "5h" {
                    shortW = QuotaWindowStat(
                        label: "5h 短窗",
                        remainingInt: remInt,
                        resetsAt: resetDate,
                        countdownText: fmtCountdown(resetDate)
                    )
                } else if win == "weekly" {
                    weekW = QuotaWindowStat(
                        label: "7 天周窗",
                        remainingInt: remInt,
                        resetsAt: resetDate,
                        countdownText: fmtCountdown(resetDate)
                    )
                }
            }

            if rawName == "Gemini Models" {
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

        return (cards, gmShort, gmWeek)
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

struct QuotaWindowRowView: View {
    let defaultLabel: String
    let stat: QuotaWindowStat?
    let palette: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(stat?.label ?? defaultLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                Spacer()
                if let s = stat {
                    HStack(spacing: 5) {
                        Text("剩余 \(s.remainingInt)%")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(palette.statusColor(usedInt: s.usedInt))
                            .monospacedDigit()
                        Text("已用 \(s.usedInt)%")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(palette.mutedText)
                            .monospacedDigit()
                    }
                } else {
                    Text("剩余 ∞（无限制）")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(palette.okColor)
                }
            }

            if let s = stat {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.trackBg)
                        Capsule()
                            .fill(palette.statusColor(usedInt: s.usedInt))
                            .frame(width: max(6, geo.size.width * CGFloat(Double(s.remainingInt) / 100.0)))
                    }
                }
                .frame(height: 8)

                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9.5))
                        Text(s.countdownText)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(palette.secondaryText)
                    Spacer()
                    if s.isDanger {
                        Text("已用 >80%")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(palette.dangerColor.opacity(0.18))
                            .foregroundColor(palette.dangerColor)
                            .cornerRadius(4)
                    }
                }
            }
        }
    }
}

struct QuotaCardView: View {
    let card: QuotaCardModel
    let palette: ThemePalette

    private var accentColor: Color {
        guard card.isAvailable else { return palette.mutedText }
        return palette.statusColor(usedInt: card.maxUsedInt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                Text(card.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(palette.primaryText)
                    .lineLimit(1)
                Spacer()
            }

            if card.isAvailable {
                QuotaWindowRowView(defaultLabel: "5h 短窗", stat: card.shortWindow, palette: palette)
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                QuotaWindowRowView(defaultLabel: "7 天周窗", stat: card.weeklyWindow, palette: palette)
            } else {
                Text(card.errorMessage ?? "暂无额度数据")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.secondaryText)
            }
        }
        .padding(11)
        .background(palette.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    card.isAvailable && card.maxUsedInt > 80
                        ? palette.dangerColor.opacity(0.75)
                        : palette.cardBorder,
                    lineWidth: card.isAvailable && card.maxUsedInt > 80 ? 1.5 : 1
                )
        )
        .cornerRadius(11)
    }
}

struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    let hideWindow: () -> Void
    let quitApp: () -> Void

    private var palette: ThemePalette {
        ThemePalette(isDark: store.isDarkTheme)
    }

    var body: some View {
        ZStack {
            // Full-window background drag layer so clicking/dragging any blank area moves the window
            WindowDragArea()

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.accentBlue)
                        Text("Apollo AgentMeter")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundColor(palette.primaryText)
                    }
                    .overlay(WindowDragArea())

                    Spacer()
                        .overlay(WindowDragArea())

                    Button(action: { store.isDarkTheme.toggle() }) {
                        Image(systemName: store.isDarkTheme ? "sun.max.fill" : "moon.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(palette.secondaryText)
                            .padding(5)
                            .background(palette.chipBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("切换深浅色主题")

                    Button(action: { store.refreshAll() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(store.isRefreshing ? palette.accentBlue : palette.secondaryText)
                            .padding(5)
                            .background(palette.chipBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("手动立即刷新")

                    Button(action: hideWindow) {
                        Image(systemName: "minus")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(palette.secondaryText)
                            .padding(5)
                            .background(palette.chipBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("收起到状态栏")

                    Button(action: quitApp) {
                        Image(systemName: "power")
                            .font(.system(size: 11.5))
                            .foregroundColor(palette.secondaryText)
                            .padding(5)
                            .background(palette.chipBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("退出 Apollo AgentMeter")
                }

                QuotaCardView(card: store.codexCard, palette: palette)
                    .overlay(WindowDragArea())

                ForEach(store.antigravityCards) { card in
                    QuotaCardView(card: card, palette: palette)
                        .overlay(WindowDragArea())
                }

                HStack {
                    Text("上次刷新 \(fmtClockTime(store.lastRefresh)) · 每 5 分钟自动刷新")
                        .font(.system(size: 10.5))
                        .foregroundColor(palette.mutedText)
                    Spacer()
                    Text("按住任意处可拖动")
                        .font(.system(size: 10.5))
                        .foregroundColor(palette.mutedText)
                }
                .overlay(WindowDragArea())
            }
            .padding(14)
        }
        .frame(width: 344)
        .background(palette.windowBg)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(palette.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
        if abs(oldFrame.height - newSize.height) > 2 {
            let visible = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var newY = oldFrame.maxY - newSize.height
            newY = min(max(newY, visible.minY + 8), visible.maxY - newSize.height - 8)
            panel.setFrame(NSRect(x: oldFrame.origin.x, y: newY, width: newSize.width, height: newSize.height), display: true)
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
