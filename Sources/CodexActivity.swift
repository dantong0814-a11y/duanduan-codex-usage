import Foundation
import SQLite3

enum CodexActivityState: String, Codable, CaseIterable {
    case idle
    case running
    case needsInput
    case ready
    case blocked

    var title: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "工作中"
        case .needsInput: return "需要你"
        case .ready: return "已完成"
        case .blocked: return "遇到问题"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "moon.zzz"
        case .running: return "gearshape.2.fill"
        case .needsInput: return "hand.raised.fill"
        case .ready: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        }
    }

    var priority: Int {
        switch self {
        case .needsInput: return 0
        case .blocked: return 1
        case .ready: return 2
        case .running: return 3
        case .idle: return 4
        }
    }
}

struct CodexActivity: Identifiable, Equatable {
    let id: String
    var workspace: String
    var detail: String
    var state: CodexActivityState
    var startedAt: Date?
    var completedAt: Date?
    var updatedAt: Date
    var toolCount: Int

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (completedAt ?? Date()).timeIntervalSince(startedAt))
    }

    var threadURL: URL? {
        URL(string: "codex://threads/\(id)")
    }
}

/// Reads the local Codex rollout event stream without attaching to, steering,
/// or modifying the user's active Codex threads.
final class CodexActivityMonitor {
    private final class Cursor {
        let url: URL
        var offset: UInt64 = 0
        var pendingData = Data()
        var waitingCallID: String?
        var activity: CodexActivity

        init(url: URL, activity: CodexActivity) {
            self.url = url
            self.activity = activity
        }
    }

    private let queue = DispatchQueue(label: "app.duanduan.codex-activity", qos: .utility)
    private let fileManager = FileManager.default
    private let sessionsRoot: URL
    private let stateDatabaseURL: URL?
    private let monitorStartedAt = Date()
    private var timer: DispatchSourceTimer?
    private var cursors: [URL: Cursor] = [:]
    private var pollCount = 0
    private var callback: (([CodexActivity]) -> Void)?

    init() {
        let environment = ProcessInfo.processInfo.environment
        let codexHome = environment["DUANDUAN_CODEX_HOME"]
            ?? environment["CODEX_HOME"]
            ?? "\(NSHomeDirectory())/.codex"
        let codexHomeURL = URL(fileURLWithPath: codexHome, isDirectory: true)
        sessionsRoot = codexHomeURL
            .appendingPathComponent("sessions", isDirectory: true)
        stateDatabaseURL = [
            codexHomeURL.appendingPathComponent("state_5.sqlite"),
            codexHomeURL.appendingPathComponent("sqlite/state_5.sqlite"),
        ].first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start(onUpdate: @escaping ([CodexActivity]) -> Void) {
        callback = onUpdate
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(180))
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit { stop() }

    private func poll() {
        pollCount += 1
        if cursors.isEmpty || pollCount.isMultiple(of: 5) {
            discoverRecentRollouts()
        }

        for cursor in cursors.values {
            readNewEvents(from: cursor)
        }

        let activities = cursors.values
            .map(\.activity)
            .filter { activity in
                activity.state != .idle
                    || Date().timeIntervalSince(activity.updatedAt) < 15 * 60
            }
            .sorted {
                if $0.state.priority != $1.state.priority {
                    return $0.state.priority < $1.state.priority
                }
                return $0.updatedAt > $1.updatedAt
            }
            .prefix(8)

        let snapshot = Array(activities)
        DispatchQueue.main.async { [weak self] in self?.callback?(snapshot) }
    }

    private func discoverRecentRollouts() {
        if let databaseCandidates = recentRolloutsFromStateDatabase(),
           !databaseCandidates.isEmpty {
            updateCursors(with: databaseCandidates)
            return
        }

        discoverRecentRolloutsByFileScan()
    }

    private func recentRolloutsFromStateDatabase() -> [(url: URL, modifiedAt: Date)]? {
        guard let stateDatabaseURL else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            stateDatabaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 80)

        let queries = [
            """
            SELECT rollout_path, updated_at_ms
            FROM threads
            WHERE archived = 0 AND rollout_path != ''
            ORDER BY updated_at_ms DESC
            LIMIT 20
            """,
            """
            SELECT rollout_path, updated_at * 1000
            FROM threads
            WHERE archived = 0 AND rollout_path != ''
            ORDER BY updated_at DESC
            LIMIT 20
            """,
        ]

        for query in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                if statement != nil { sqlite3_finalize(statement) }
                continue
            }
            defer { sqlite3_finalize(statement) }

            var result: [(url: URL, modifiedAt: Date)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pathPointer = sqlite3_column_text(statement, 0) else { continue }
                let path = String(cString: pathPointer)
                guard fileManager.fileExists(atPath: path) else { continue }
                let milliseconds = sqlite3_column_int64(statement, 1)
                result.append((
                    URL(fileURLWithPath: path),
                    Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
                ))
            }
            if !result.isEmpty { return result }
        }
        return nil
    }

    private func discoverRecentRolloutsByFileScan() {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        var candidates: [(url: URL, modifiedAt: Date)] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey, .isRegularFileKey,
                  ]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff
            else { continue }
            candidates.append((url, modifiedAt))
        }

        let selected = Array(candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(16))
        updateCursors(with: selected)
    }

    private func updateCursors(with selected: [(url: URL, modifiedAt: Date)]) {
        let selectedURLs = Set(selected.map(\.url))

        for candidate in selected where cursors[candidate.url] == nil {
            cursors[candidate.url] = makeCursor(
                for: candidate.url,
                modifiedAt: candidate.modifiedAt
            )
        }

        cursors = cursors.filter { selectedURLs.contains($0.key) }
    }

    private func makeCursor(for url: URL, modifiedAt: Date) -> Cursor {
        let metadata = readMetadata(from: url)
        let threadID = metadata.id ?? threadIDFromFilename(url)
        let workspace = metadata.cwd
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "Codex 任务"

        let activity = CodexActivity(
            id: threadID,
            workspace: workspace,
            detail: "最近使用",
            state: .idle,
            startedAt: nil,
            completedAt: nil,
            updatedAt: modifiedAt,
            toolCount: 0
        )
        let cursor = Cursor(url: url, activity: activity)

        let fileSize = fileSizeOf(url)
        let tailSize: UInt64 = 1_048_576
        cursor.offset = fileSize > tailSize ? fileSize - tailSize : 0
        readNewEvents(from: cursor, isInitialRead: true)

        if cursor.activity.state == .ready,
           cursor.activity.updatedAt < monitorStartedAt.addingTimeInterval(-20) {
            cursor.activity.state = .idle
            cursor.activity.detail = "最近使用"
        }
        if cursor.activity.state == .blocked,
           cursor.activity.updatedAt < monitorStartedAt.addingTimeInterval(-5 * 60) {
            cursor.activity.state = .idle
            cursor.activity.detail = "最近使用"
        }

        return cursor
    }

    private func readMetadata(from url: URL) -> (id: String?, cwd: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (nil, nil)
        }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        for line in data.split(separator: 0x0A) {
            guard let object = jsonObject(from: Data(line)),
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            return (payload["id"] as? String, payload["cwd"] as? String)
        }
        return (nil, nil)
    }

    private func readNewEvents(from cursor: Cursor, isInitialRead: Bool = false) {
        let fileSize = fileSizeOf(cursor.url)
        if fileSize < cursor.offset {
            cursor.offset = 0
            cursor.pendingData.removeAll(keepingCapacity: true)
        }
        guard fileSize > cursor.offset,
              let handle = try? FileHandle(forReadingFrom: cursor.url)
        else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: cursor.offset)
            let maximumRead: UInt64 = 2_097_152
            let bytesToRead = Int(min(fileSize - cursor.offset, maximumRead))
            guard let chunk = try handle.read(upToCount: bytesToRead), !chunk.isEmpty else {
                return
            }
            cursor.offset += UInt64(chunk.count)

            var incoming = chunk
            if isInitialRead, cursor.offset - UInt64(chunk.count) > 0,
               let firstNewline = incoming.firstIndex(of: 0x0A) {
                incoming.removeSubrange(...firstNewline)
            }
            cursor.pendingData.append(incoming)

            while let newline = cursor.pendingData.firstIndex(of: 0x0A) {
                let line = cursor.pendingData[..<newline]
                cursor.pendingData.removeSubrange(...newline)
                guard !line.isEmpty, let object = jsonObject(from: Data(line)) else {
                    continue
                }
                apply(object, to: cursor)
            }
        } catch {
            return
        }
    }

    private func apply(_ object: [String: Any], to cursor: Cursor) {
        guard let recordType = object["type"] as? String,
              let payload = object["payload"] as? [String: Any]
        else { return }

        let eventDate = eventDateFrom(object) ?? Date()
        let payloadType = payload["type"] as? String

        if recordType == "event_msg" {
            switch payloadType {
            case "task_started":
                cursor.activity.state = .running
                cursor.activity.detail = "正在理解你的任务"
                cursor.activity.startedAt = eventDate
                cursor.activity.completedAt = nil
                cursor.activity.toolCount = 0
            case "task_complete":
                cursor.activity.state = .ready
                cursor.activity.detail = "任务已经完成"
                cursor.activity.completedAt = eventDate
            case "agent_reasoning":
                setRunningDetail("正在分析和规划", on: cursor)
            case "agent_message":
                if payload["phase"] as? String == "commentary" {
                    setRunningDetail("正在汇报最新进度", on: cursor)
                }
            case "patch_apply_end":
                let success = payload["success"] as? Bool ?? false
                setRunningDetail(
                    success ? "文件修改完成，继续检查" : "正在处理文件修改问题",
                    on: cursor
                )
            case "mcp_tool_call_end":
                setRunningDetail("工具调用完成，继续处理", on: cursor)
            case "sub_agent_activity":
                setRunningDetail("正在协调多个任务", on: cursor)
            case "turn_aborted", "task_failed":
                cursor.activity.state = .blocked
                cursor.activity.detail = "任务遇到问题，需要查看"
                cursor.activity.completedAt = eventDate
            default:
                break
            }
        }

        if recordType == "response_item" {
            switch payloadType {
            case "custom_tool_call", "function_call":
                let name = payload["name"] as? String ?? ""
                let callID = payload["call_id"] as? String
                cursor.activity.toolCount += 1
                if isUserInputTool(name) {
                    cursor.activity.state = .needsInput
                    cursor.activity.detail = "正在等你确认或回答"
                    cursor.waitingCallID = callID
                } else {
                    cursor.activity.state = .running
                    cursor.activity.detail = progressText(forTool: name)
                }
            case "custom_tool_call_output", "function_call_output":
                if cursor.waitingCallID == nil
                    || cursor.waitingCallID == payload["call_id"] as? String {
                    cursor.waitingCallID = nil
                    setRunningDetail("收到结果，继续处理", on: cursor)
                }
            default:
                break
            }
        }

        cursor.activity.updatedAt = eventDate
    }

    private func setRunningDetail(_ detail: String, on cursor: Cursor) {
        guard cursor.activity.state != .needsInput,
              cursor.activity.state != .ready,
              cursor.activity.state != .blocked
        else { return }
        cursor.activity.state = .running
        cursor.activity.detail = detail
    }

    private func progressText(forTool name: String) -> String {
        let value = name.lowercased()
        if value.contains("apply_patch") || value.contains("write") || value.contains("edit") {
            return "正在编辑文件"
        }
        if value.contains("exec") || value.contains("shell") || value.contains("terminal") {
            return "正在执行命令"
        }
        if value.contains("web") || value.contains("search") || value.contains("fetch") {
            return "正在查找资料"
        }
        if value.contains("image") || value.contains("figma") {
            return "正在处理图片和设计"
        }
        if value.contains("browser") || value.contains("chrome") || value.contains("computer") {
            return "正在检查应用界面"
        }
        if value.contains("github") || value.contains("git") {
            return "正在处理代码仓库"
        }
        if value.contains("collaboration") || value.contains("agent") {
            return "正在协调多个任务"
        }
        return "正在调用工具"
    }

    private func isUserInputTool(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("request_user_input")
            || value.contains("requestapproval")
            || value.contains("elicitation")
    }

    private func threadIDFromFilename(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let match = stem.range(
            of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) {
            return String(stem[match])
        }
        return stem
    }

    private func fileSizeOf(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(max(0, values?.fileSize ?? 0))
    }

    private func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func eventDateFrom(_ object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] as? String else { return nil }
        return Self.isoDateFormatter.date(from: value)
            ?? Self.isoDateFormatterWithoutFraction.date(from: value)
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatterWithoutFraction = ISO8601DateFormatter()
}
