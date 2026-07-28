import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

// MARK: - Codex data models

struct RateLimitWindow: Codable, Hashable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int { max(0, 100 - usedPercent) }
}

struct CreditsSnapshot: Codable, Hashable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct SpendControlLimitSnapshot: Codable, Hashable {
    let limitName: String?
    let remainingPercent: Int?
    let resetsAt: Int64?
}

struct RateLimitSnapshot: Codable, Hashable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let individualLimit: SpendControlLimitSnapshot?
    let spendControlReached: Bool?
    let planType: String?
    let rateLimitReachedType: String?
}

struct ResetCreditsSummary: Codable, Hashable {
    let availableCount: Int64
}

struct RateLimitsResponse: Codable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: ResetCreditsSummary?
}

struct TokenUsageSummary: Codable, Hashable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct DailyUsageBucket: Codable, Identifiable, Hashable {
    let startDate: String
    let tokens: Int64
    var id: String { startDate }
}

struct TokenUsageResponse: Codable {
    let summary: TokenUsageSummary
    let dailyUsageBuckets: [DailyUsageBucket]?
}

struct UsageSnapshot {
    let rates: RateLimitsResponse
    let tokens: TokenUsageResponse
    let fetchedAt: Date
}

// MARK: - Codex app-server reader

enum UsageReaderError: LocalizedError {
    case codexNotFound
    case launchFailed(String)
    case timeout
    case protocolError(String)
    case missingResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "没有找到 Codex 本机程序"
        case .launchFailed(let detail):
            return "Codex 用量服务启动失败：\(detail)"
        case .timeout:
            return "读取 Codex 用量超时"
        case .protocolError(let detail):
            return "Codex 返回的数据无法识别：\(detail)"
        case .missingResponse:
            return "Codex 没有返回完整用量数据"
        }
    }
}

final class CodexUsageReader {
    private let queue = DispatchQueue(label: "app.duanduan.codex-usage.reader", qos: .utility)

    func fetch(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        queue.async {
            do {
                let snapshot = try self.fetchSynchronously()
                DispatchQueue.main.async { completion(.success(snapshot)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func codexExecutable() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func fetchSynchronously() throws -> UsageSnapshot {
        guard let executable = codexExecutable() else { throw UsageReaderError.codexNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw UsageReaderError.launchFailed(error.localizedDescription)
        }

        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            var line = data
            line.append(0x0A)
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        }

        try send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "duanduan-usage",
                    "version": "1.0.0",
                    "title": "短短用量助手",
                ],
                "capabilities": ["experimentalApi": true],
            ],
        ])

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeoutWork)

        var buffer = Data()
        var rateResult: Any?
        var tokenResult: Any?
        var initialized = false
        let startedAt = Date()

        readLoop: while Date().timeIntervalSince(startedAt) < 16 {
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                else { continue }

                if let errorObject = object["error"] {
                    throw UsageReaderError.protocolError(String(describing: errorObject))
                }

                if (object["id"] as? Int) == 1, !initialized {
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
                    try send(["id": 3, "method": "account/usage/read", "params": NSNull()])
                } else if (object["id"] as? Int) == 2 {
                    rateResult = object["result"]
                } else if (object["id"] as? Int) == 3 {
                    tokenResult = object["result"]
                }

                if rateResult != nil && tokenResult != nil {
                    break readLoop
                }
            }
        }

        timeoutWork.cancel()
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard let rawRates = rateResult, let rawTokens = tokenResult else {
            if Date().timeIntervalSince(startedAt) >= 15 {
                throw UsageReaderError.timeout
            }
            let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if let message = String(data: stderr, encoding: .utf8), !message.isEmpty {
                throw UsageReaderError.protocolError(message)
            }
            throw UsageReaderError.missingResponse
        }

        do {
            let decoder = JSONDecoder()
            let rateData = try JSONSerialization.data(withJSONObject: rawRates)
            let tokenData = try JSONSerialization.data(withJSONObject: rawTokens)
            return UsageSnapshot(
                rates: try decoder.decode(RateLimitsResponse.self, from: rateData),
                tokens: try decoder.decode(TokenUsageResponse.self, from: tokenData),
                fetchedAt: Date()
            )
        } catch {
            throw UsageReaderError.protocolError(error.localizedDescription)
        }
    }
}

// MARK: - Presentation state

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var expanded = false {
        didSet {
            if oldValue != expanded { onExpandedChange?(expanded) }
        }
    }
    @Published var isAlarmActive = false

    private let reader = CodexUsageReader()
    private var refreshTimer: Timer?
    private var alarmTimer: Timer?
    var onAlarm: ((Int, Bool) -> Void)?
    var onExpandedChange: ((Bool) -> Void)?

    func start(demo: Bool = false) {
        if demo {
            snapshot = Self.demoSnapshot
            return
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        reader.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshing = false
            switch result {
            case .success(let snapshot):
                self.snapshot = snapshot
                self.lastError = nil
                self.evaluateAlarm(snapshot)
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func testAlarm() {
        let remaining = minimumRemaining ?? 10
        activateAlarm(remaining: min(10, remaining), isTest: true)
    }

    func dismissAlarm() {
        isAlarmActive = false
        alarmTimer?.invalidate()
        alarmTimer = nil
    }

    private func evaluateAlarm(_ snapshot: UsageSnapshot) {
        guard let remaining = minimumRemaining, remaining <= 10 else { return }
        let windows = activeRateWindows
        let resetKey = windows
            .compactMap { $0.window.resetsAt }
            .map(String.init)
            .sorted()
            .joined(separator: "-")
        let alertKey = "alerted.\(resetKey.isEmpty ? "no-reset" : resetKey)"
        guard !UserDefaults.standard.bool(forKey: alertKey) else { return }
        UserDefaults.standard.set(true, forKey: alertKey)
        activateAlarm(remaining: remaining, isTest: false)
    }

    private func activateAlarm(remaining: Int, isTest: Bool) {
        isAlarmActive = true
        expanded = true
        onAlarm?(remaining, isTest)
        alarmTimer?.invalidate()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissAlarm() }
        }
    }

    var rateSnapshots: [(String, RateLimitSnapshot)] {
        guard let snapshot else { return [] }
        if let buckets = snapshot.rates.rateLimitsByLimitId, !buckets.isEmpty {
            return buckets.sorted { $0.key < $1.key }
        }
        return [(snapshot.rates.rateLimits.limitId ?? "codex", snapshot.rates.rateLimits)]
    }

    var activeRateWindows: [(name: String, window: RateLimitWindow)] {
        var result: [(String, RateLimitWindow)] = []
        for (id, rate) in rateSnapshots {
            if let primary = rate.primary {
                result.append(("\(displayLimitName(id, rate: rate)) · \(windowName(primary))", primary))
            }
            if let secondary = rate.secondary {
                result.append(("\(displayLimitName(id, rate: rate)) · \(windowName(secondary))", secondary))
            }
        }
        return result
    }

    var minimumRemaining: Int? {
        activeRateWindows.map(\.window.remainingPercent).min()
    }

    var planName: String {
        guard let raw = rateSnapshots.first?.1.planType else { return "未知套餐" }
        return raw == "plus" ? "ChatGPT Plus" : raw.capitalized
    }

    var dailyBuckets: [DailyUsageBucket] {
        snapshot?.tokens.dailyUsageBuckets?.sorted { $0.startDate < $1.startDate } ?? []
    }

    var todayTokens: Int64 {
        let key = Self.dayFormatter.string(from: Date())
        return dailyBuckets.first(where: { $0.startDate == key })?.tokens ?? 0
    }

    var sevenDayTokens: Int64 { tokens(inLastDays: 7) }
    var thirtyDayTokens: Int64 { tokens(inLastDays: 30) }

    var lastReportedDate: String? { dailyBuckets.last?.startDate }

    private func tokens(inLastDays days: Int) -> Int64 {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return dailyBuckets.reduce(0) { total, bucket in
            guard let date = Self.dayFormatter.date(from: bucket.startDate), date >= start else { return total }
            return total + bucket.tokens
        }
    }

    private func displayLimitName(_ id: String, rate: RateLimitSnapshot) -> String {
        if let name = rate.limitName, !name.isEmpty { return name }
        return id == "codex" ? "Codex" : id
    }

    private func windowName(_ window: RateLimitWindow) -> String {
        guard let minutes = window.windowDurationMins else { return "额度" }
        if minutes >= 10080, minutes % 10080 == 0 { return "\(minutes / 10080) 周" }
        if minutes >= 1440, minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static var demoSnapshot: UsageSnapshot {
        let calendar = Calendar.current
        let buckets: [DailyUsageBucket] = (0..<30).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - 29, to: Date()) else { return nil }
            let value = Int64(2_800_000 + ((offset * 7_913_579) % 31_000_000))
            return DailyUsageBucket(startDate: dayFormatter.string(from: date), tokens: value)
        }
        let reset = Int64(Date().addingTimeInterval(3 * 24 * 3600).timeIntervalSince1970)
        let rate = RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: RateLimitWindow(usedPercent: 72, windowDurationMins: 10080, resetsAt: reset),
            secondary: nil,
            credits: CreditsSnapshot(hasCredits: false, unlimited: false, balance: "0"),
            individualLimit: nil,
            spendControlReached: false,
            planType: "plus",
            rateLimitReachedType: nil
        )
        return UsageSnapshot(
            rates: RateLimitsResponse(
                rateLimits: rate,
                rateLimitsByLimitId: ["codex": rate],
                rateLimitResetCredits: ResetCreditsSummary(availableCount: 1)
            ),
            tokens: TokenUsageResponse(
                summary: TokenUsageSummary(
                    lifetimeTokens: 384_200_000,
                    peakDailyTokens: 42_800_000,
                    longestRunningTurnSec: 5_420,
                    currentStreakDays: 5,
                    longestStreakDays: 18
                ),
                dailyUsageBuckets: buckets
            ),
            fetchedAt: Date()
        )
    }
}

// MARK: - Formatting

private let compactNumberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 1
    return formatter
}()

func tokenText(_ value: Int64?) -> String {
    guard let value else { return "—" }
    let number = Double(value)
    if number >= 1_000_000_000 {
        return String(format: "%.2fB", number / 1_000_000_000)
    }
    if number >= 1_000_000 {
        return String(format: "%.1fM", number / 1_000_000)
    }
    if number >= 1_000 {
        return String(format: "%.1fK", number / 1_000)
    }
    return compactNumberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func durationText(_ seconds: Int64?) -> String {
    guard let seconds else { return "—" }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
    return "\(minutes) 分钟"
}

func resetText(_ timestamp: Int64?) -> String {
    guard let timestamp else { return "未提供" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}

// MARK: - Pet animation

enum PetMotion: Equatable {
    case idle
    case alarm
}

final class SpriteAnimationNSView: NSView {
    private var timer: Timer?
    private var framesByRow: [Int: [NSImage]] = [:]
    private let imageView = NSImageView()
    private var frameIndex = 0
    var motion: PetMotion = .idle {
        didSet {
            if oldValue != motion {
                frameIndex = 0
                updateFrame()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        addSubview(imageView)
        loadAtlas()
        startTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        addSubview(imageView)
        loadAtlas()
        startTimer()
    }

    deinit { timer?.invalidate() }

    private func loadAtlas() {
        let definitions: [(row: Int, name: String, count: Int)] = [
            (0, "idle", 6),
            (3, "waving", 4),
            (4, "jumping", 6),
        ]
        for definition in definitions {
            var frames: [NSImage] = []
            for index in 0..<definition.count {
                let filename = "\(definition.name)-\(String(format: "%02d", index))"
                guard let url = Bundle.main.url(forResource: filename, withExtension: "png"),
                      let image = NSImage(contentsOf: url)
                else { continue }
                frames.append(image)
            }
            if !frames.isEmpty { framesByRow[definition.row] = frames }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex += 1
            self.updateFrame()
        }
        updateFrame()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    private func updateFrame() {
        let row: Int
        if motion == .alarm {
            // Alternate jumping and paw-waving: ShortShort pops up, then "knocks".
            let phase = frameIndex % 20
            row = phase < 8 ? 4 : 3
        } else {
            row = 0
        }
        guard let frames = framesByRow[row], !frames.isEmpty else { return }
        imageView.image = frames[frameIndex % frames.count]
    }
}

struct PetAnimationView: NSViewRepresentable {
    let motion: PetMotion

    func makeNSView(context: Context) -> SpriteAnimationNSView {
        let view = SpriteAnimationNSView()
        view.motion = motion
        return view
    }

    func updateNSView(_ nsView: SpriteAnimationNSView, context: Context) {
        nsView.motion = motion
    }
}

// MARK: - SwiftUI dashboard

struct MetricTile: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.48))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            if let detail {
                Text(detail)
                    .font(.system(size: 8))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 0.8)
        }
    }
}

struct RateGauge: View {
    let remaining: Int

    private var tint: Color {
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return Color(red: 0.43, green: 0.85, blue: 0.69)
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(remaining) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(remaining)%")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("剩余")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
    }
}

struct UsageBarChart: View {
    let buckets: [DailyUsageBucket]

    private var recent: [DailyUsageBucket] { Array(buckets.suffix(14)) }
    private var maxTokens: Double { Double(recent.map(\.tokens).max() ?? 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(recent) { bucket in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.46, green: 0.88, blue: 0.74), Color(red: 0.27, green: 0.58, blue: 0.92)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(height: max(4, 72 * Double(bucket.tokens) / maxTokens))
                        .help("\(bucket.startDate)：\(tokenText(bucket.tokens)) Tokens")
                    Text(String(bucket.startDate.suffix(2)))
                        .font(.system(size: 8, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 92, alignment: .bottom)
    }
}

struct RateWindowRow: View {
    let name: String
    let window: RateLimitWindow

    private var tint: Color {
        window.remainingPercent <= 10 ? .red : (window.remainingPercent <= 25 ? .orange : .mint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("已用 \(window.usedPercent)% · 剩余 \(window.remainingPercent)%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * CGFloat(window.usedPercent) / 100)
                }
            }
            .frame(height: 7)
            Text("重置：\(resetText(window.resetsAt))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @State private var alarmWiggle = false
    private let mint = Color(red: 0.38, green: 0.91, blue: 0.72)

    var body: some View {
        VStack(spacing: 0) {
            compactHeader
            if store.expanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .foregroundStyle(.white)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        store.isAlarmActive
                            ? Color(red: 0.10, green: 0.025, blue: 0.035).opacity(0.97)
                            : Color(red: 0.035, green: 0.047, blue: 0.065).opacity(0.96)
                    )
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        store.isAlarmActive ? Color.red.opacity(0.72) : mint.opacity(0.16),
                        lineWidth: store.isAlarmActive ? 2 : 1
                    )
                    .blur(radius: store.isAlarmActive ? 0 : 0.2)
            }
            .shadow(
                color: store.isAlarmActive ? Color.red.opacity(0.24) : mint.opacity(0.08),
                radius: store.isAlarmActive ? 20 : 16
            )
            .shadow(color: .black.opacity(0.32), radius: 22, y: 9)
        )
        .padding(6)
        .offset(x: store.isAlarmActive && alarmWiggle ? -7 : 0)
        .onReceive(store.$isAlarmActive.removeDuplicates()) { active in
            if active {
                withAnimation(.easeInOut(duration: 0.12).repeatCount(12, autoreverses: true)) {
                    alarmWiggle.toggle()
                }
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            PetAnimationView(motion: store.isAlarmActive ? .alarm : .idle)
                .frame(width: 76, height: 84)
                .background {
                    Circle()
                        .fill(store.isAlarmActive ? Color.red.opacity(0.18) : mint.opacity(0.12))
                        .blur(radius: 14)
                        .scaleEffect(1.15)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        store.expanded.toggle()
                    }
                }

            if let snapshot = store.snapshot {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isAlarmActive ? "CODEX ALERT" : "CODEX BUDGET")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(store.isAlarmActive ? Color.red.opacity(0.92) : Color.white.opacity(0.46))

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(store.minimumRemaining ?? 0)%")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(store.isAlarmActive ? "快敲门" : "剩余")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(store.isAlarmActive ? Color.red : mint)
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule()
                                .fill(store.isAlarmActive ? Color.red : mint)
                                .frame(
                                    width: geometry.size.width
                                        * CGFloat(max(0, min(100, store.minimumRemaining ?? 0)))
                                        / 100
                                )
                        }
                    }
                    .frame(height: 6)

                    Text(
                        store.isAlarmActive
                            ? "额度只剩 10% · 短短来敲门了"
                            : "7天 \(tokenText(store.sevenDayTokens))  ·  累计 \(tokenText(snapshot.tokens.summary.lifetimeTokens))"
                    )
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(store.isAlarmActive ? Color.red.opacity(0.82) : Color.white.opacity(0.48))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("短短正在查看 Codex 用量…")
                        .font(.system(size: 14, weight: .semibold))
                    if let error = store.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.9))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer()
            }

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    store.expanded.toggle()
                }
            } label: {
                Image(systemName: store.expanded ? "chevron.up" : "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.065), in: Circle())
                    .overlay {
                        Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var expandedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if store.isAlarmActive {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("短短来敲门了")
                                .font(.system(size: 13, weight: .bold))
                            Text("Codex 可用额度已到 10% 警戒线。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("知道了") { store.dismissAlarm() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red.opacity(0.8))
                    }
                    .padding(12)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }

                sectionTitle("订阅与额度")
                HStack {
                    Label(store.planName, systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    if let count = store.snapshot?.rates.rateLimitResetCredits?.availableCount {
                        Text("可用重置 \(count) 次")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

                ForEach(Array(store.activeRateWindows.enumerated()), id: \.offset) { _, item in
                    RateWindowRow(name: item.name, window: item.window)
                }

                if let rate = store.rateSnapshots.first?.1 {
                    HStack(spacing: 8) {
                        MetricTile(
                            label: "额外余额",
                            value: rate.credits?.unlimited == true ? "不限" : (rate.credits?.balance ?? "0"),
                            detail: rate.credits?.hasCredits == true ? "可用" : "无额外余额"
                        )
                        MetricTile(
                            label: "消费控制",
                            value: rate.spendControlReached == true ? "已触发" : "正常",
                            detail: rate.rateLimitReachedType
                        )
                    }
                }

                sectionTitle("Token 活动")
                HStack(spacing: 8) {
                    MetricTile(label: "今日", value: tokenText(store.todayTokens), detail: "官方每日汇总")
                    MetricTile(label: "近 7 天", value: tokenText(store.sevenDayTokens), detail: "按日合计")
                    MetricTile(label: "近 30 天", value: tokenText(store.thirtyDayTokens), detail: "按日合计")
                }
                HStack(spacing: 8) {
                    MetricTile(label: "历史累计", value: tokenText(store.snapshot?.tokens.summary.lifetimeTokens), detail: "Total tokens")
                    MetricTile(label: "单日峰值", value: tokenText(store.snapshot?.tokens.summary.peakDailyTokens), detail: "Peak daily")
                    MetricTile(label: "最长任务", value: durationText(store.snapshot?.tokens.summary.longestRunningTurnSec), detail: "Longest turn")
                }
                HStack(spacing: 8) {
                    MetricTile(label: "当前连续", value: "\(store.snapshot?.tokens.summary.currentStreakDays ?? 0) 天", detail: "Current streak")
                    MetricTile(label: "最长连续", value: "\(store.snapshot?.tokens.summary.longestStreakDays ?? 0) 天", detail: "Longest streak")
                    MetricTile(label: "数据截至", value: store.lastReportedDate ?? "—", detail: "官方日桶可能延迟")
                }

                sectionTitle("最近 14 个有记录日期")
                UsageBarChart(buckets: store.dailyBuckets)
                    .padding(12)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                    }

                DisclosureGroup("查看全部每日 Token 明细") {
                    LazyVStack(spacing: 0) {
                        ForEach(store.dailyBuckets.reversed()) { bucket in
                            HStack {
                                Text(bucket.startDate)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(tokenText(bucket.tokens)) Tokens")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11, design: .rounded))
                            .padding(.vertical, 6)
                            Divider().opacity(0.08)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 11, weight: .medium))
                .tint(.mint)

                HStack {
                    Text("账户级接口仅提供每日总 Token，不含输入/输出/缓存拆分。")
                    Spacer()
                    if let fetched = store.snapshot?.fetchedAt {
                        Text(fetched, style: .time)
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

                HStack {
                    Button {
                        store.refresh()
                    } label: {
                        Label("立即刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        store.testAlarm()
                    } label: {
                        Label("测试敲门", systemImage: "bell")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: 510)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
    }
}

// MARK: - App lifecycle

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PanelSize {
        static let compact = NSSize(width: 452, height: 116)
        static let expanded = NSSize(width: 500, height: 640)
    }

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var store: UsageStore!
    private var hostingView: NSHostingView<DashboardView>!
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = UsageStore()
        store.onAlarm = { [weak self] remaining, isTest in
            self?.presentAlarm(remaining: remaining, isTest: isTest)
        }

        configurePanel()
        configureStatusItem()
        if !ProcessInfo.processInfo.arguments.contains("--demo") {
            configureNotifications()
        }
        store.onExpandedChange = { [weak self] expanded in
            self?.resizePanel(expanded: expanded)
        }
        if ProcessInfo.processInfo.arguments.contains("--expanded") {
            store.expanded = true
        }
        showPanel()
        store.start(demo: ProcessInfo.processInfo.arguments.contains("--demo"))
        if ProcessInfo.processInfo.arguments.contains("--test-alarm") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.store.testAlarm()
            }
        }
    }

    private func configurePanel() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PanelSize.compact),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = PanelSize.compact
        panel.maxSize = PanelSize.expanded

        hostingView = NSHostingView(rootView: DashboardView(store: store))
        let container = NSView(frame: NSRect(origin: .zero, size: PanelSize.compact))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        positionPanel()
    }

    private func resizePanel(expanded: Bool) {
        guard panel != nil else { return }
        panel.setContentSize(expanded ? PanelSize.expanded : PanelSize.compact)
        positionPanel()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "短短用量")
        statusItem.button?.toolTip = "短短 · Codex 用量"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        let menu = NSMenu()
        menu.addItem(withTitle: "显示／隐藏短短用量", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshUsage), keyEquivalent: "r")
        menu.addItem(withTitle: "测试 10% 敲门报警", action: #selector(testAlarm), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出短短用量助手", action: #selector(quit), keyEquivalent: "q")

        // A normal click toggles the panel. Right click opens the menu.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            guard let self, event.window == self.statusItem.button?.window else { return event }
            self.statusItem.menu = menu
            self.statusItem.button?.performClick(nil)
            self.statusItem.menu = nil
            return nil
        }
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    @objc private func refreshUsage() {
        store.refresh()
        showPanel()
    }

    @objc private func testAlarm() {
        store.testAlarm()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showPanel() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - panel.frame.width - 18
        let y = visible.minY + 18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func presentAlarm(remaining: Int, isTest: Bool) {
        showPanel()
        NSApp.requestUserAttention(.criticalRequest)
        NSSound(named: "Ping")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSSound(named: "Pop")?.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { NSSound(named: "Ping")?.play() }

        let content = UNMutableNotificationContent()
        content.title = isTest ? "短短敲门测试" : "咚咚咚！短短来提醒你"
        content.body = "Codex 可用额度剩余 \(remaining)%，即将用完。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "duanduan-usage-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

@main
struct DuanduanUsageApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
