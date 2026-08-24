import Foundation
import PotluckDBRuntime

private enum ABI {
    static let errorCaller: UInt32 = 1
    static let errorTemporary: UInt32 = 2
    static let errorPermanent: UInt32 = 3
    static let transactionDeferred: UInt32 = 1
    static let transactionImmediate: UInt32 = 2
    static let transactionExclusive: UInt32 = 3
    static let syncAutomatic: UInt32 = 1
    static let syncManual: UInt32 = 2
    static let prefetchAutomatic: UInt32 = 1
    static let prefetchDisabled: UInt32 = 2
    static let checkpointAutomatic: UInt32 = 1
    static let checkpointDisabled: UInt32 = 2
    static let bindingsPositional: UInt32 = 1
    static let bindingsNamed: UInt32 = 2
    static let valueNull: UInt32 = 1
    static let valueBoolean: UInt32 = 2
    static let valueInteger: UInt32 = 3
    static let valueReal: UInt32 = 4
    static let valueText: UInt32 = 5
    static let valueBlob: UInt32 = 6
    static let syncUpToDate: UInt32 = 1
    static let syncPushed: UInt32 = 2
    static let syncPulled: UInt32 = 3
    static let syncConflict: UInt32 = 4
    static let openEncryptionKey: UInt32 = 1
    static let openClientID: UInt32 = 2
    static let remoteRetention: UInt32 = 1
    static let reencryptSourceKey: UInt32 = 1
    static let reencryptRevision: UInt32 = 2
}

public enum ErrorCategory: String, Sendable {
    case caller
    case temporary
    case permanent
    case `internal`
}

public struct PotluckDBError: Error, LocalizedError, Sendable {
    public let code: String
    public let category: ErrorCategory
    public let message: String
    public let action: String
    public let retryAfter: TimeInterval?

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { action }

    fileprivate static func invalidArgument(_ message: String, action: String) -> Self {
        Self(
            code: "invalid_argument",
            category: .caller,
            message: message,
            action: action,
            retryAfter: nil
        )
    }
}

private func copyString(_ value: PotluckDbBufferV1) -> String {
    guard value.length > 0, let data = value.data else { return "" }
    return String(
        decoding: UnsafeBufferPointer(start: data, count: Int(value.length)),
        as: UTF8.self
    )
}

private func copyString(_ value: PotluckDbSliceV1) -> String {
    guard value.length > 0, let data = value.data else { return "" }
    return String(
        decoding: UnsafeBufferPointer(start: data, count: Int(value.length)),
        as: UTF8.self
    )
}

private func copyData(_ value: PotluckDbSliceV1) -> Data {
    guard value.length > 0, let data = value.data else { return Data() }
    return Data(bytes: data, count: Int(value.length))
}

private func errorCategory(_ value: UInt32) -> ErrorCategory {
    switch value {
    case ABI.errorCaller: return .caller
    case ABI.errorTemporary: return .temporary
    case ABI.errorPermanent: return .permanent
    default: return .internal
    }
}

private func applicationCall(
    _ body: (UnsafeMutablePointer<PotluckDbErrorV1>) -> Int32
) throws {
    var error = PotluckDbErrorV1()
    potluckdb_error_init_v1(&error)
    let result = body(&error)
    guard result == 0 else {
        let translated = PotluckDBError(
            code: copyString(error.code),
            category: errorCategory(error.category),
            message: copyString(error.message),
            action: copyString(error.action),
            retryAfter: error.has_retry_after != 0
                ? TimeInterval(error.retry_after_ms) / 1_000
                : nil
        )
        _ = potluckdb_error_release_v1(&error)
        throw translated
    }
    _ = potluckdb_error_release_v1(&error)
}

private func withSlice<T>(
    _ value: String,
    _ body: (PotluckDbSliceV1) throws -> T
) rethrows -> T {
    let bytes = Array(value.utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
        var slice = PotluckDbSliceV1()
        slice.data = buffer.baseAddress
        slice.length = UInt64(buffer.count)
        return try body(slice)
    }
}

public struct Revision: Hashable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw PotluckDBError.invalidArgument(
                "revision must contain exactly 32 bytes",
                action: "Supply a 32-byte revision and retry."
            )
        }
        self.bytes = bytes
    }

    fileprivate init(raw: PotluckDbRevisionV1) {
        var value = raw
        bytes = withUnsafeBytes(of: &value.bytes) { Data($0) }
    }

    fileprivate var raw: PotluckDbRevisionV1 {
        var value = PotluckDbRevisionV1()
        _ = withUnsafeMutableBytes(of: &value.bytes) { destination in
            bytes.copyBytes(to: destination)
        }
        return value
    }

    public static func parse(_ text: String) throws -> Self {
        try withSlice(text) { slice in
            var output = PotluckDbRevisionV1()
            try applicationCall { error in
                potluckdb_revision_parse_v1(slice, &output, error)
            }
            return Self(raw: output)
        }
    }

    public func formatted() throws -> String {
        var revision = raw
        var output = PotluckDbBufferV1()
        try applicationCall { error in
            potluckdb_revision_format_v1(&revision, &output, error)
        }
        defer { _ = potluckdb_buffer_release_v1(&output) }
        return copyString(output)
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum TransactionMode: Sendable {
    case deferred
    case immediate
    case exclusive

    fileprivate var raw: UInt32 {
        switch self {
        case .deferred: return ABI.transactionDeferred
        case .immediate: return ABI.transactionImmediate
        case .exclusive: return ABI.transactionExclusive
        }
    }
}

public struct AutomaticSyncOptions: Equatable, Sendable {
    public let outboundDebounceMilliseconds: UInt64
    public let activePullIntervalMilliseconds: UInt64
    public let idlePullIntervalMilliseconds: UInt64
    public let retryInitialMilliseconds: UInt64
    public let retryMaximumMilliseconds: UInt64

    public init(
        outboundDebounceMilliseconds: UInt64 = 30,
        activePullIntervalMilliseconds: UInt64 = 200,
        idlePullIntervalMilliseconds: UInt64 = 1_000,
        retryInitialMilliseconds: UInt64 = 250,
        retryMaximumMilliseconds: UInt64 = 30_000
    ) {
        self.outboundDebounceMilliseconds = outboundDebounceMilliseconds
        self.activePullIntervalMilliseconds = activePullIntervalMilliseconds
        self.idlePullIntervalMilliseconds = idlePullIntervalMilliseconds
        self.retryInitialMilliseconds = retryInitialMilliseconds
        self.retryMaximumMilliseconds = retryMaximumMilliseconds
    }
}

public struct SyncPolicy: Equatable, Sendable {
    fileprivate enum Mode: Equatable, Sendable { case automatic, manual }
    fileprivate let mode: Mode
    fileprivate let options: AutomaticSyncOptions

    public static func automatic() -> Self {
        Self(mode: .automatic, options: AutomaticSyncOptions())
    }

    public static func automatic(_ options: AutomaticSyncOptions) throws -> Self {
        let maximum: UInt64 = 86_400_000
        let timers = [
            options.outboundDebounceMilliseconds,
            options.activePullIntervalMilliseconds,
            options.idlePullIntervalMilliseconds,
            options.retryInitialMilliseconds,
            options.retryMaximumMilliseconds,
        ]
        guard timers.allSatisfy({ (1 ... maximum).contains($0) }) else {
            throw PotluckDBError.invalidArgument(
                "sync timers must be from 1 through 86400000 milliseconds",
                action: "Correct the timer values and retry."
            )
        }
        guard options.idlePullIntervalMilliseconds
                >= options.activePullIntervalMilliseconds else {
            throw PotluckDBError.invalidArgument(
                "idle pull interval must be at least the active pull interval",
                action: "Correct the pull intervals and retry."
            )
        }
        guard options.retryMaximumMilliseconds >= options.retryInitialMilliseconds else {
            throw PotluckDBError.invalidArgument(
                "maximum retry delay must be at least the initial retry delay",
                action: "Correct the retry delays and retry."
            )
        }
        return Self(mode: .automatic, options: options)
    }

    public static func manual() -> Self {
        Self(mode: .manual, options: AutomaticSyncOptions())
    }
}

public struct PrefetchPolicy: Equatable, Sendable {
    fileprivate let enabled: Bool
    fileprivate let backgroundTargetBytes: UInt64
    fileprivate let memoryBudgetBytes: UInt64

    public static func automatic() -> Self {
        Self(enabled: true, backgroundTargetBytes: 0, memoryBudgetBytes: 64 * 1_024 * 1_024)
    }

    public static func automatic(
        backgroundTargetBytes: UInt64,
        memoryBudgetBytes: UInt64
    ) throws -> Self {
        guard memoryBudgetBytes > 0 else {
            throw PotluckDBError.invalidArgument(
                "prefetch memory budget must be positive",
                action: "Raise the prefetch memory budget and retry."
            )
        }
        return Self(
            enabled: true,
            backgroundTargetBytes: backgroundTargetBytes,
            memoryBudgetBytes: memoryBudgetBytes
        )
    }

    public static func disabled() -> Self {
        Self(enabled: false, backgroundTargetBytes: 0, memoryBudgetBytes: 0)
    }
}

public struct CheckpointPolicy: Equatable, Sendable {
    fileprivate let enabled: Bool
    fileprivate let softLimitBytes: UInt64
    fileprivate let forcedLimitBytes: UInt64

    public static func automatic() -> Self {
        Self(
            enabled: true,
            softLimitBytes: 64 * 1_024 * 1_024,
            forcedLimitBytes: 128 * 1_024 * 1_024
        )
    }

    public static func automatic(
        softLimitBytes: UInt64,
        forcedLimitBytes: UInt64
    ) throws -> Self {
        guard softLimitBytes > 0, forcedLimitBytes >= softLimitBytes else {
            throw PotluckDBError.invalidArgument(
                "checkpoint limits must be positive and forced must not be below soft",
                action: "Correct the checkpoint limits and retry."
            )
        }
        return Self(
            enabled: true,
            softLimitBytes: softLimitBytes,
            forcedLimitBytes: forcedLimitBytes
        )
    }

    public static func disabled() -> Self {
        Self(enabled: false, softLimitBytes: 0, forcedLimitBytes: 0)
    }
}

public struct RetentionPolicy: Equatable, Sendable {
    public static let defaults = try! RetentionPolicy.bounded()

    fileprivate let keepLast: UInt64
    fileprivate let collectAt: UInt64

    public static func bounded(keepLast: UInt64 = 10, collectAt: UInt64 = 20) throws -> Self {
        guard keepLast > 0, collectAt > keepLast else {
            throw PotluckDBError.invalidArgument(
                "retention keepLast must be positive and collectAt must be greater",
                action: "Correct the retention bounds and retry."
            )
        }
        return Self(keepLast: keepLast, collectAt: collectAt)
    }
}

public struct ConnectionOptions: Equatable, Sendable {
    public static let defaults = try! ConnectionOptions()

    public let timeoutMilliseconds: UInt64
    public let maximumRows: UInt64
    public let prefetch: PrefetchPolicy
    public let checkpoint: CheckpointPolicy

    public init(
        timeoutMilliseconds: UInt64 = 5_000,
        maximumRows: UInt64 = 100_000,
        prefetch: PrefetchPolicy = .automatic(),
        checkpoint: CheckpointPolicy = .automatic()
    ) throws {
        guard timeoutMilliseconds <= 86_400_000, maximumRows > 0 else {
            throw PotluckDBError.invalidArgument(
                "connection timeout or result limit is outside the supported bounds",
                action: "Use a timeout up to one day and a positive maximumRows."
            )
        }
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumRows = maximumRows
        self.prefetch = prefetch
        self.checkpoint = checkpoint
    }
}

public struct OpenOptions: Equatable, Sendable {
    public static let defaults = try! OpenOptions()

    public let localBudgetBytes: UInt64
    public let minimumLocalBudgetBytes: UInt64
    public let localCompactionBytes: UInt64
    public let encryptionKey: Data?
    public let syncPolicy: SyncPolicy
    public let clientID: String?
    public let connection: ConnectionOptions

    public init(
        localBudgetBytes: UInt64 = 1_024 * 1_024 * 1_024,
        minimumLocalBudgetBytes: UInt64 = 10 * 1_024 * 1_024,
        localCompactionBytes: UInt64 = 256 * 1_024 * 1_024,
        encryptionKey: Data? = nil,
        syncPolicy: SyncPolicy = .automatic(),
        clientID: String? = nil,
        connection: ConnectionOptions = .defaults
    ) throws {
        guard localBudgetBytes >= minimumLocalBudgetBytes else {
            throw PotluckDBError.invalidArgument(
                "local budget must be at least the minimum local budget",
                action: "Raise the local budget or lower the minimum and retry."
            )
        }
        guard localCompactionBytes > 0 else {
            throw PotluckDBError.invalidArgument(
                "local compaction threshold must be positive",
                action: "Raise the compaction threshold and retry."
            )
        }
        guard encryptionKey == nil || encryptionKey?.count == 32 else {
            throw PotluckDBError.invalidArgument(
                "encryption key must contain exactly 32 bytes",
                action: "Supply a 32-byte key and retry."
            )
        }
        if let clientID {
            let range = clientID.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
                options: .regularExpression
            )
            guard range != nil else {
                throw PotluckDBError.invalidArgument(
                    "clientID must be a portable identity of 1 through 128 characters",
                    action: "Correct the client identity and retry."
                )
            }
        }
        self.localBudgetBytes = localBudgetBytes
        self.minimumLocalBudgetBytes = minimumLocalBudgetBytes
        self.localCompactionBytes = localCompactionBytes
        self.encryptionKey = encryptionKey
        self.syncPolicy = syncPolicy
        self.clientID = clientID
        self.connection = connection
    }
}

public struct RemoteOptions: Equatable, Sendable {
    public static let defaults = try! RemoteOptions()

    public let readConcurrency: UInt32
    public let writeConcurrency: UInt32
    public let retention: RetentionPolicy?

    public init(
        readConcurrency: UInt32 = 32,
        writeConcurrency: UInt32 = 16,
        retention: RetentionPolicy? = nil
    ) throws {
        guard (1 ... 256).contains(readConcurrency), (1 ... 128).contains(writeConcurrency) else {
            throw PotluckDBError.invalidArgument(
                "remote concurrency is outside the supported bounds",
                action: "Use read concurrency 1 through 256 and write concurrency 1 through 128."
            )
        }
        self.readConcurrency = readConcurrency
        self.writeConcurrency = writeConcurrency
        self.retention = retention
    }
}

public enum SQLValue: Equatable, Sendable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct Bindings: Equatable, Sendable {
    fileprivate enum Storage: Equatable, Sendable {
        case positional([SQLValue])
        case named([(String, SQLValue)])

        static func == (left: Self, right: Self) -> Bool {
            switch (left, right) {
            case let (.positional(a), .positional(b)): return a == b
            case let (.named(a), .named(b)):
                return a.elementsEqual(b) { $0.0 == $1.0 && $0.1 == $1.1 }
            default: return false
            }
        }
    }

    fileprivate let storage: Storage
    public static let none = Bindings(storage: .positional([]))

    public static func positional(_ values: [SQLValue]) -> Self {
        Self(storage: .positional(values))
    }

    public static func named(_ values: [String: SQLValue]) -> Self {
        Self(storage: .named(values.sorted { $0.key < $1.key }))
    }
}

public typealias Row = [SQLValue]
public typealias Rows = [Row]

public struct ExecuteResult: Equatable, Sendable {
    public let rowsAffected: Int64
    public let lastInsertID: Int64?
}

public enum SyncResult: Equatable, Sendable {
    case upToDate(revision: Revision?)
    case pushed(revision: Revision)
    case pulled(revision: Revision, replayed: [String], quarantined: [String])
    case conflict(remoteRevision: Revision?, reason: String)
}

public struct ConflictResolution: Equatable, Sendable {
    public let revision: Revision
    public let alreadyPublished: [String]
    public let replayed: [String]
    public let quarantined: [String]
    public let pending: [String]
}

public struct CollectionReport: Equatable, Sendable {
    public let floorBefore: Revision?
    public let floorAfter: Revision?
    public let epoch: UInt64
    public let marked: UInt64
    public let swept: UInt64
    public let aborted: Bool
}

public struct DatabaseStatus: Equatable, Sendable {
    public let revision: Revision?
    public let pendingWrites: UInt64
    public let localBytes: UInt64
    public let localBudgetBytes: UInt64
    public let connectionCount: UInt64
    public let syncState: String
    public let nextSyncInMilliseconds: UInt64?
    public let conflictRemoteRevision: Revision?
    public let closed: Bool
}

public struct CheckpointCounters: Equatable, Sendable {
    public let softScheduled: UInt64
    public let forcedCheckpointAttempts: UInt64
    public let manual: UInt64
    public let completed: UInt64
    public let failures: UInt64
    public let staleCommands: UInt64
    public let pagesVerified: UInt64
    public let walBytesReclaimed: UInt64
}

public struct CheckpointStatus: Equatable, Sendable {
    public let softLimitBytes: UInt64
    public let forcedLimitBytes: UInt64
    public let walBytes: UInt64
    public let due: Bool
    public let scheduled: Bool
    public let counters: CheckpointCounters
}

public struct PrefetchCounters: Equatable, Sendable {
    public let demandSubmitted: UInt64
    public let demandJoined: UInt64
    public let demandReady: UInt64
    public let statementSubmitted: UInt64
    public let backgroundSubmitted: UInt64
    public let speculativeCancelled: UInt64
    public let speculativeCompleted: UInt64
    public let speculativeDiscarded: UInt64
    public let speculativeFailed: UInt64
    public let backgroundInstalled: UInt64
    public let backgroundInstallRefused: UInt64
    public let backgroundBatches: UInt64
    public let backgroundInstallFailed: UInt64
    public let policyFailures: UInt64
    public let limitIncreases: UInt64
    public let limitDecreases: UInt64
}

public struct PrefetchStatus: Equatable, Sendable {
    public let backgroundState: String
    public let limit: UInt64
    public let active: UInt64
    public let queued: UInt64
    public let readyPages: UInt64
    public let readyBytes: UInt64
    public let backgroundTargetBytes: UInt64
    public let counters: PrefetchCounters
}

public struct ConnectionStatus: Equatable, Sendable {
    public let transactionActive: Bool
    public let checkpoint: CheckpointStatus?
    public let prefetch: PrefetchStatus?
    public let closed: Bool
}

public struct SnapshotStatus: Equatable, Sendable {
    public let revision: Revision
    public let localBytes: UInt64
    public let closed: Bool
}

public struct RemoteStatus: Equatable, Sendable {
    public let retainedRevisions: UInt64?
    public let maintenancePending: Bool
    public let policyFailures: UInt64
    public let closed: Bool
}

public struct KeyRotationReport: Equatable, Sendable {
    public let sourceRevision: Revision
    public let targetRevision: Revision
    public let sourceKeyID: Revision?
    public let targetKeyID: Revision
    public let pieceCount: UInt64
    public let published: Bool
}

private func rawSyncPolicy(_ source: SyncPolicy) -> PotluckDbSyncPolicyV1 {
    var value = PotluckDbSyncPolicyV1()
    potluckdb_sync_policy_init_v1(&value)
    value.mode = source.mode == .automatic ? ABI.syncAutomatic : ABI.syncManual
    value.outbound_debounce_ms = source.options.outboundDebounceMilliseconds
    value.active_pull_interval_ms = source.options.activePullIntervalMilliseconds
    value.idle_pull_interval_ms = source.options.idlePullIntervalMilliseconds
    value.retry_initial_ms = source.options.retryInitialMilliseconds
    value.retry_max_ms = source.options.retryMaximumMilliseconds
    return value
}

private func rawConnectionOptions(
    _ source: ConnectionOptions
) -> PotluckDbConnectionOptionsV1 {
    var value = PotluckDbConnectionOptionsV1()
    potluckdb_connection_options_init_v1(&value)
    value.timeout_ms = source.timeoutMilliseconds
    value.maximum_rows = source.maximumRows
    value.prefetch_mode = source.prefetch.enabled
        ? ABI.prefetchAutomatic
        : ABI.prefetchDisabled
    value.prefetch_background_target_bytes = source.prefetch.backgroundTargetBytes
    value.prefetch_memory_budget_bytes = source.prefetch.memoryBudgetBytes
    value.checkpoint_mode = source.checkpoint.enabled
        ? ABI.checkpointAutomatic
        : ABI.checkpointDisabled
    value.checkpoint_soft_limit_bytes = source.checkpoint.softLimitBytes
    value.checkpoint_forced_limit_bytes = source.checkpoint.forcedLimitBytes
    return value
}

private func withRawOpenOptions<T>(
    _ source: OpenOptions,
    _ body: (UnsafePointer<PotluckDbOpenOptionsV1>) throws -> T
) throws -> T {
    func invoke(_ clientID: PotluckDbSliceV1?) throws -> T {
        var value = PotluckDbOpenOptionsV1()
        potluckdb_open_options_init_v1(&value)
        value.local_budget_bytes = source.localBudgetBytes
        value.minimum_local_budget_bytes = source.minimumLocalBudgetBytes
        value.local_compaction_bytes = source.localCompactionBytes
        value.sync_policy = rawSyncPolicy(source.syncPolicy)
        value.connection = rawConnectionOptions(source.connection)
        if let key = source.encryptionKey {
            value.flags |= ABI.openEncryptionKey
            _ = withUnsafeMutableBytes(of: &value.encryption_key) { destination in
                key.copyBytes(to: destination)
            }
        }
        if let clientID {
            value.flags |= ABI.openClientID
            value.client_id = clientID
        }
        return try withUnsafePointer(to: &value, body)
    }

    if let clientID = source.clientID {
        return try withSlice(clientID) { slice in try invoke(slice) }
    }
    return try invoke(nil)
}

private func rawRetentionPolicy(_ source: RetentionPolicy) -> PotluckDbRetentionPolicyV1 {
    var value = PotluckDbRetentionPolicyV1()
    potluckdb_retention_policy_init_v1(&value)
    value.keep_last = source.keepLast
    value.collect_at = source.collectAt
    return value
}

private func rawRemoteOptions(_ source: RemoteOptions) -> PotluckDbRemoteOptionsV1 {
    var value = PotluckDbRemoteOptionsV1()
    potluckdb_remote_options_init_v1(&value)
    value.read_concurrency = source.readConcurrency
    value.write_concurrency = source.writeConcurrency
    if let retention = source.retention {
        value.flags |= ABI.remoteRetention
        value.retention = rawRetentionPolicy(retention)
    }
    return value
}

private final class RawBindings {
    private var raw = PotluckDbBindingsV1()
    private var items: UnsafeMutablePointer<PotluckDbBindingV1>?
    private var itemCount = 0
    private var buffers: [UnsafeMutablePointer<UInt8>] = []

    init(_ source: Bindings) {
        potluckdb_bindings_init_v1(&raw)
        let values: [(String?, SQLValue)]
        switch source.storage {
        case let .positional(selected):
            raw.kind = ABI.bindingsPositional
            values = selected.map { (nil, $0) }
        case let .named(selected):
            raw.kind = ABI.bindingsNamed
            values = selected.map { ($0.0, $0.1) }
        }
        itemCount = values.count
        guard !values.isEmpty else { return }
        let allocated = UnsafeMutablePointer<PotluckDbBindingV1>.allocate(
            capacity: values.count
        )
        allocated.initialize(repeating: PotluckDbBindingV1(), count: values.count)
        items = allocated
        for (index, entry) in values.enumerated() {
            potluckdb_binding_init_v1(allocated.advanced(by: index))
            if let name = entry.0 {
                allocated[index].name = slice(Data(name.utf8))
            }
            allocated[index].value = rawValue(entry.1)
        }
        raw.items = UnsafePointer(allocated)
        raw.count = UInt64(values.count)
    }

    deinit {
        if let items {
            items.deinitialize(count: itemCount)
            items.deallocate()
        }
        buffers.forEach { $0.deallocate() }
    }

    func withPointer<T>(
        _ body: (UnsafePointer<PotluckDbBindingsV1>) throws -> T
    ) rethrows -> T {
        try withUnsafePointer(to: &raw, body)
    }

    private func slice(_ data: Data) -> PotluckDbSliceV1 {
        var result = PotluckDbSliceV1()
        guard !data.isEmpty else { return result }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        data.copyBytes(to: buffer, count: data.count)
        buffers.append(buffer)
        result.data = UnsafePointer(buffer)
        result.length = UInt64(data.count)
        return result
    }

    private func rawValue(_ source: SQLValue) -> PotluckDbValueV1 {
        var value = PotluckDbValueV1()
        potluckdb_value_init_v1(&value)
        switch source {
        case .null:
            value.kind = ABI.valueNull
        case let .boolean(selected):
            value.kind = ABI.valueBoolean
            value.boolean_value = selected ? 1 : 0
        case let .integer(selected):
            value.kind = ABI.valueInteger
            value.integer_value = selected
        case let .real(selected):
            value.kind = ABI.valueReal
            value.real_value = selected
        case let .text(selected):
            value.kind = ABI.valueText
            value.bytes = slice(Data(selected.utf8))
        case let .blob(selected):
            value.kind = ABI.valueBlob
            value.bytes = slice(selected)
        }
        return value
    }
}

private func internalFailure(_ message: String) -> PotluckDBError {
    PotluckDBError(
        code: "internal_failure",
        category: .internal,
        message: message,
        action: "Preserve the failure details and report this error.",
        retryAfter: nil
    )
}

private func sqlValue(_ source: PotluckDbValueV1) throws -> SQLValue {
    switch source.kind {
    case ABI.valueNull: return .null
    case ABI.valueBoolean: return .boolean(source.boolean_value != 0)
    case ABI.valueInteger: return .integer(source.integer_value)
    case ABI.valueReal: return .real(source.real_value)
    case ABI.valueText: return .text(copyString(source.bytes))
    case ABI.valueBlob: return .blob(copyData(source.bytes))
    default: throw internalFailure("potluckdb returned an unknown SQL value kind")
    }
}

private func copiedRows(_ handle: PotluckDbRowsHandleV1) throws -> Rows {
    var released = false
    defer {
        if !released { _ = potluckdb_rows_release_v1(handle, nil) }
    }
    var rowCount: UInt64 = 0
    try applicationCall { error in
        potluckdb_rows_row_count_v1(handle, &rowCount, error)
    }
    var rows: Rows = []
    rows.reserveCapacity(Int(rowCount))
    for rowIndex in 0 ..< rowCount {
        var columnCount: UInt64 = 0
        try applicationCall { error in
            potluckdb_rows_column_count_v1(handle, rowIndex, &columnCount, error)
        }
        var row: Row = []
        row.reserveCapacity(Int(columnCount))
        for columnIndex in 0 ..< columnCount {
            var value = PotluckDbValueV1()
            potluckdb_value_init_v1(&value)
            try applicationCall { error in
                potluckdb_rows_value_v1(
                    handle,
                    rowIndex,
                    columnIndex,
                    &value,
                    UInt32(MemoryLayout<PotluckDbValueV1>.size),
                    error
                )
            }
            row.append(try sqlValue(value))
        }
        rows.append(row)
    }
    try applicationCall { error in potluckdb_rows_release_v1(handle, error) }
    released = true
    return rows
}

private func executeResult(_ source: PotluckDbExecuteResultV1) -> ExecuteResult {
    ExecuteResult(
        rowsAffected: source.rows_affected,
        lastInsertID: source.has_last_insert_id != 0 ? source.last_insert_id : nil
    )
}

private func strings(_ handle: PotluckDbStringListHandleV1) throws -> [String] {
    var count: UInt64 = 0
    try applicationCall { error in
        potluckdb_string_list_count_v1(handle, &count, error)
    }
    var result: [String] = []
    result.reserveCapacity(Int(count))
    for index in 0 ..< count {
        var value = PotluckDbSliceV1()
        try applicationCall { error in
            potluckdb_string_list_get_v1(handle, index, &value, error)
        }
        result.append(copyString(value))
    }
    return result
}

private func syncState(_ value: UInt32) -> String {
    switch value {
    case 1: return "manual"
    case 2: return "unbound"
    case 3: return "scheduled"
    case 4: return "synchronizing"
    case 5: return "idle"
    case 6: return "backoff"
    case 7: return "conflict"
    case 8: return "failed"
    case 9: return "closed"
    default: return "unknown"
    }
}

private func databaseStatus(_ source: PotluckDbDatabaseStatusV1) -> DatabaseStatus {
    DatabaseStatus(
        revision: source.has_revision != 0 ? Revision(raw: source.revision) : nil,
        pendingWrites: source.pending_writes,
        localBytes: source.local_bytes,
        localBudgetBytes: source.local_budget_bytes,
        connectionCount: source.connection_count,
        syncState: syncState(source.sync_state),
        nextSyncInMilliseconds: source.has_next_sync != 0
            ? source.next_sync_in_ms
            : nil,
        conflictRemoteRevision: source.has_conflict_revision != 0
            ? Revision(raw: source.conflict_revision)
            : nil,
        closed: source.closed != 0
    )
}

private func checkpointStatus(
    _ source: PotluckDbRuntimeCheckpointStatusV1
) -> CheckpointStatus {
    CheckpointStatus(
        softLimitBytes: source.soft_limit_bytes,
        forcedLimitBytes: source.forced_checkpoint_threshold_bytes,
        walBytes: source.wal_bytes,
        due: source.due != 0,
        scheduled: source.scheduled != 0,
        counters: CheckpointCounters(
            softScheduled: source.soft_scheduled,
            forcedCheckpointAttempts: source.forced_checkpoint_attempts,
            manual: source.manual,
            completed: source.completed,
            failures: source.failures,
            staleCommands: source.stale_commands,
            pagesVerified: source.pages_verified,
            walBytesReclaimed: source.wal_bytes_reclaimed
        )
    )
}

private func prefetchBackgroundState(_ value: UInt32) -> String {
    switch value {
    case 0: return "disabled"
    case 1: return "idle"
    case 2: return "fetching"
    case 3: return "installing"
    case 4: return "paused"
    case 5: return "complete"
    case 6: return "saturated"
    case 7: return "failed"
    case 8: return "closed"
    default: return "unknown"
    }
}

private func prefetchStatus(_ source: PotluckDbRuntimePrefetchStatusV1) -> PrefetchStatus {
    PrefetchStatus(
        backgroundState: prefetchBackgroundState(source.background_state),
        limit: source.limit,
        active: source.active,
        queued: source.queued,
        readyPages: source.ready_pages,
        readyBytes: source.ready_bytes,
        backgroundTargetBytes: source.background_target_bytes,
        counters: PrefetchCounters(
            demandSubmitted: source.demand_submitted,
            demandJoined: source.demand_joined,
            demandReady: source.demand_ready,
            statementSubmitted: source.statement_submitted,
            backgroundSubmitted: source.background_submitted,
            speculativeCancelled: source.speculative_cancelled,
            speculativeCompleted: source.speculative_completed,
            speculativeDiscarded: source.speculative_discarded,
            speculativeFailed: source.speculative_failed,
            backgroundInstalled: source.background_installed,
            backgroundInstallRefused: source.background_install_refused,
            backgroundBatches: source.background_batches,
            backgroundInstallFailed: source.background_install_failed,
            policyFailures: source.policy_failures,
            limitIncreases: source.limit_increases,
            limitDecreases: source.limit_decreases
        )
    )
}

private typealias OwnerFunction = (
    UInt64,
    UnsafeMutablePointer<PotluckDbErrorV1>?
) -> Int32

private final class HandleState {
    fileprivate let lock = NSLock()
    fileprivate var handle: UInt64
    private let closeFunction: OwnerFunction?
    private let releaseFunction: OwnerFunction
    private var retained: AnyObject?
    private var closed = false

    init(
        handle: UInt64,
        close: OwnerFunction?,
        release: @escaping OwnerFunction,
        retained: AnyObject? = nil
    ) throws {
        guard handle != 0 else {
            throw internalFailure("potluckdb returned a zero owner handle")
        }
        self.handle = handle
        closeFunction = close
        releaseFunction = release
        self.retained = retained
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0 else { return }
        if let closeFunction, !closed { _ = closeFunction(handle, nil) }
        _ = releaseFunction(handle, nil)
        handle = 0
    }

    func withHandle<T>(_ body: (UInt64) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0 else {
            throw PotluckDBError(
                code: "invalid_state",
                category: .caller,
                message: "potluckdb owner is released",
                action: "Open a new owner and retry.",
                retryAfter: nil
            )
        }
        return try body(handle)
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0, !closed else { return }
        guard let closeFunction else {
            throw internalFailure("this potluckdb capability has no close operation")
        }
        try applicationCall { error in closeFunction(handle, error) }
        closed = true
    }

    func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0 else { return }
        try applicationCall { error in releaseFunction(handle, error) }
        handle = 0
        retained = nil
    }

    static func withPair<T>(
        _ left: HandleState,
        _ right: HandleState,
        _ body: (UInt64, UInt64) throws -> T
    ) throws -> T {
        guard left !== right else {
            throw PotluckDBError.invalidArgument(
                "source and target must be distinct Remote values",
                action: "Open a distinct target Remote and retry."
            )
        }
        let leftAddress = UInt(bitPattern: Unmanaged.passUnretained(left).toOpaque())
        let rightAddress = UInt(bitPattern: Unmanaged.passUnretained(right).toOpaque())
        let first = leftAddress < rightAddress ? left : right
        let second = leftAddress < rightAddress ? right : left
        first.lock.lock()
        second.lock.lock()
        defer {
            second.lock.unlock()
            first.lock.unlock()
        }
        guard left.handle != 0, right.handle != 0 else {
            throw PotluckDBError(
                code: "invalid_state",
                category: .caller,
                message: "potluckdb Remote is released",
                action: "Open new Remote values and retry.",
                retryAfter: nil
            )
        }
        return try body(left.handle, right.handle)
    }
}

public enum Integrator {
    public final class StorageAdapter {
        fileprivate var raw: PotluckDbRuntimeBucketAdapterV1
        private let owner: AnyObject?

        public init(
            raw: PotluckDbRuntimeBucketAdapterV1,
            retaining owner: AnyObject
        ) {
            self.raw = raw
            self.owner = owner
        }

        public static func borrowed(_ raw: PotluckDbRuntimeBucketAdapterV1) -> StorageAdapter {
            StorageAdapter(raw: raw, owner: nil)
        }

        private init(raw: PotluckDbRuntimeBucketAdapterV1, owner: AnyObject?) {
            self.raw = raw
            self.owner = owner
        }

        fileprivate func withRaw<T>(
            _ body: (UnsafePointer<PotluckDbRuntimeBucketAdapterV1>) throws -> T
        ) rethrows -> T {
            try withUnsafePointer(to: &raw, body)
        }
    }
}

public final class Remote {
    fileprivate let state: HandleState

    private init(state: HandleState) {
        self.state = state
    }

    public static func fromDirectory(
        _ path: String,
        options: RemoteOptions = .defaults
    ) throws -> Remote {
        var rawOptions = rawRemoteOptions(options)
        return try withSlice(path) { pathSlice in
            var handle: PotluckDbRemoteHandleV1 = 0
            try applicationCall { error in
                potluckdb_remote_from_directory_v1(
                    pathSlice,
                    &rawOptions,
                    &handle,
                    error
                )
            }
            return try Remote(
                state: HandleState(
                    handle: handle,
                    close: potluckdb_remote_close_v1,
                    release: potluckdb_remote_release_v1
                )
            )
        }
    }

    public static func fromStorage(
        _ storage: Integrator.StorageAdapter,
        options: RemoteOptions = .defaults
    ) throws -> Remote {
        var rawOptions = rawRemoteOptions(options)
        return try storage.withRaw { rawStorage in
            var handle: PotluckDbRemoteHandleV1 = 0
            try applicationCall { error in
                potluckdb_remote_from_storage_v1(
                    rawStorage,
                    &rawOptions,
                    &handle,
                    error
                )
            }
            return try Remote(
                state: HandleState(
                    handle: handle,
                    close: potluckdb_remote_close_v1,
                    release: potluckdb_remote_release_v1,
                    retained: storage
                )
            )
        }
    }

    public func status() throws -> RemoteStatus {
        try state.withHandle { handle in
            var output = PotluckDbRemoteStatusV1()
            potluckdb_remote_status_init_v1(&output)
            try applicationCall { error in
                potluckdb_remote_status_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbRemoteStatusV1>.size),
                    error
                )
            }
            return RemoteStatus(
                retainedRevisions: output.has_retained_revisions != 0
                    ? output.retained_revisions
                    : nil,
                maintenancePending: output.maintenance_pending != 0,
                policyFailures: output.policy_failures,
                closed: output.closed != 0
            )
        }
    }

    @discardableResult
    public func collect(_ retention: RetentionPolicy = .defaults) throws -> CollectionReport {
        var rawRetention = rawRetentionPolicy(retention)
        return try state.withHandle { handle in
            var output = PotluckDbCollectionReportV1()
            potluckdb_collection_report_init_v1(&output)
            try applicationCall { error in
                potluckdb_remote_collect_v1(
                    handle,
                    &rawRetention,
                    &output,
                    UInt32(MemoryLayout<PotluckDbCollectionReportV1>.size),
                    error
                )
            }
            return Self.collectionReport(output)
        }
    }

    @discardableResult
    public func recoverAbandonedCollection() throws -> CollectionReport {
        try state.withHandle { handle in
            var output = PotluckDbCollectionReportV1()
            potluckdb_collection_report_init_v1(&output)
            try applicationCall { error in
                potluckdb_remote_recover_abandoned_collection_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbCollectionReportV1>.size),
                    error
                )
            }
            return Self.collectionReport(output)
        }
    }

    public func close() throws {
        try state.close()
    }

    private static func collectionReport(
        _ source: PotluckDbCollectionReportV1
    ) -> CollectionReport {
        CollectionReport(
            floorBefore: source.has_floor_before != 0
                ? Revision(raw: source.floor_before)
                : nil,
            floorAfter: source.has_floor_after != 0
                ? Revision(raw: source.floor_after)
                : nil,
            epoch: source.epoch,
            marked: source.marked,
            swept: source.swept,
            aborted: source.aborted != 0
        )
    }
}

public final class Transaction {
    fileprivate let state: HandleState

    fileprivate init(state: HandleState) {
        self.state = state
    }

    public func query(_ sql: String, bindings: Bindings = .none) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_transaction_query_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &rows,
                            error
                        )
                    }
                    return try copiedRows(rows)
                }
            }
        }
    }

    @discardableResult
    public func execute(
        _ sql: String,
        bindings: Bindings = .none
    ) throws -> ExecuteResult {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var output = PotluckDbExecuteResultV1()
                    potluckdb_execute_result_init_v1(&output)
                    try applicationCall { error in
                        potluckdb_transaction_execute_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &output,
                            UInt32(MemoryLayout<PotluckDbExecuteResultV1>.size),
                            error
                        )
                    }
                    return executeResult(output)
                }
            }
        }
    }

    fileprivate func commit() throws {
        try state.withHandle { handle in
            try applicationCall { error in
                potluckdb_transaction_commit_v1(handle, error)
            }
        }
        try state.release()
    }

    fileprivate func rollback() throws {
        try state.withHandle { handle in
            try applicationCall { error in
                potluckdb_transaction_rollback_v1(handle, error)
            }
        }
        try state.release()
    }

    fileprivate func rollbackQuietly() {
        try? rollback()
    }
}

private typealias TransactionBeginFunction = (
    UInt64,
    UInt32,
    UnsafeMutablePointer<PotluckDbTransactionHandleV1>?,
    UnsafeMutablePointer<PotluckDbErrorV1>?
) -> Int32

private func executeTransaction<T>(
    owner: HandleState,
    begin: TransactionBeginFunction,
    mode: TransactionMode,
    body: (Transaction) throws -> T
) throws -> T {
    let transactionState = try owner.withHandle { handle -> HandleState in
        var output: PotluckDbTransactionHandleV1 = 0
        try applicationCall { error in
            begin(handle, mode.raw, &output, error)
        }
        return try HandleState(
            handle: output,
            close: nil,
            release: potluckdb_transaction_release_v1,
            retained: owner
        )
    }
    let transaction = Transaction(state: transactionState)
    do {
        let result = try body(transaction)
        try transaction.commit()
        return result
    } catch {
        transaction.rollbackQuietly()
        throw error
    }
}

public final class Connection {
    fileprivate let state: HandleState

    fileprivate init(state: HandleState) {
        self.state = state
    }

    public func query(_ sql: String, bindings: Bindings = .none) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_connection_query_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &rows,
                            error
                        )
                    }
                    return try copiedRows(rows)
                }
            }
        }
    }

    @discardableResult
    public func execute(
        _ sql: String,
        bindings: Bindings = .none
    ) throws -> ExecuteResult {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var output = PotluckDbExecuteResultV1()
                    potluckdb_execute_result_init_v1(&output)
                    try applicationCall { error in
                        potluckdb_connection_execute_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &output,
                            UInt32(MemoryLayout<PotluckDbExecuteResultV1>.size),
                            error
                        )
                    }
                    return executeResult(output)
                }
            }
        }
    }

    @discardableResult
    public func transaction<T>(
        _ mode: TransactionMode = .immediate,
        _ body: (Transaction) throws -> T
    ) throws -> T {
        try executeTransaction(
            owner: state,
            begin: potluckdb_connection_transaction_begin_v1,
            mode: mode,
            body: body
        )
    }

    @discardableResult
    public func checkpoint() throws -> (logFrames: Int32, checkpointedFrames: Int32) {
        try state.withHandle { handle in
            var output = PotluckDbCheckpointResultV1()
            potluckdb_checkpoint_result_init_v1(&output)
            try applicationCall { error in
                potluckdb_connection_checkpoint_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbCheckpointResultV1>.size),
                    error
                )
            }
            return (
                logFrames: output.log_frames,
                checkpointedFrames: output.checkpointed_frames
            )
        }
    }

    public func status() throws -> ConnectionStatus {
        try state.withHandle { handle in
            var output = PotluckDbConnectionStatusV1()
            potluckdb_connection_status_init_v1(&output)
            try applicationCall { error in
                potluckdb_connection_status_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbConnectionStatusV1>.size),
                    error
                )
            }
            return ConnectionStatus(
                transactionActive: output.transaction_active != 0,
                checkpoint: output.has_checkpoint != 0
                    ? checkpointStatus(output.checkpoint)
                    : nil,
                prefetch: output.has_prefetch != 0
                    ? prefetchStatus(output.prefetch)
                    : nil,
                closed: output.closed != 0
            )
        }
    }

    public func close() throws {
        try state.close()
    }
}

public final class Snapshot {
    fileprivate let state: HandleState

    fileprivate init(state: HandleState) {
        self.state = state
    }

    public func query(_ sql: String, bindings: Bindings = .none) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_snapshot_query_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &rows,
                            error
                        )
                    }
                    return try copiedRows(rows)
                }
            }
        }
    }

    public func status() throws -> SnapshotStatus {
        try state.withHandle { handle in
            var output = PotluckDbSnapshotStatusV1()
            potluckdb_snapshot_status_init_v1(&output)
            try applicationCall { error in
                potluckdb_snapshot_status_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbSnapshotStatusV1>.size),
                    error
                )
            }
            return SnapshotStatus(
                revision: Revision(raw: output.revision),
                localBytes: output.local_bytes,
                closed: output.closed != 0
            )
        }
    }

    public func close() throws {
        try state.close()
    }
}

public final class Database {
    fileprivate let state: HandleState

    fileprivate init(state: HandleState) {
        self.state = state
    }

    public func query(_ sql: String, bindings: Bindings = .none) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_database_query_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &rows,
                            error
                        )
                    }
                    return try copiedRows(rows)
                }
            }
        }
    }

    @discardableResult
    public func execute(
        _ sql: String,
        bindings: Bindings = .none
    ) throws -> ExecuteResult {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var output = PotluckDbExecuteResultV1()
                    potluckdb_execute_result_init_v1(&output)
                    try applicationCall { error in
                        potluckdb_database_execute_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            &output,
                            UInt32(MemoryLayout<PotluckDbExecuteResultV1>.size),
                            error
                        )
                    }
                    return executeResult(output)
                }
            }
        }
    }

    @discardableResult
    public func transaction<T>(
        _ mode: TransactionMode = .immediate,
        _ body: (Transaction) throws -> T
    ) throws -> T {
        try executeTransaction(
            owner: state,
            begin: potluckdb_database_transaction_begin_v1,
            mode: mode,
            body: body
        )
    }

    public func connect(_ options: ConnectionOptions = .defaults) throws -> Connection {
        var rawOptions = rawConnectionOptions(options)
        return try state.withHandle { handle in
            var output: PotluckDbConnectionHandleV1 = 0
            try applicationCall { error in
                potluckdb_database_connect_v1(handle, &rawOptions, &output, error)
            }
            return Connection(
                state: try HandleState(
                    handle: output,
                    close: potluckdb_connection_close_v1,
                    release: potluckdb_connection_release_v1,
                    retained: state
                )
            )
        }
    }

    public func sync() throws -> SyncResult {
        try state.withHandle { handle in
            var output = PotluckDbSyncResultV1()
            potluckdb_sync_result_init_v1(&output)
            try applicationCall { error in
                potluckdb_database_sync_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbSyncResultV1>.size),
                    error
                )
            }
            defer { _ = potluckdb_sync_result_release_v1(&output) }
            switch output.kind {
            case ABI.syncUpToDate:
                return .upToDate(
                    revision: output.has_revision != 0
                        ? Revision(raw: output.revision)
                        : nil
                )
            case ABI.syncPushed:
                return .pushed(revision: Revision(raw: output.revision))
            case ABI.syncPulled:
                return .pulled(
                    revision: Revision(raw: output.revision),
                    replayed: try strings(output.replayed),
                    quarantined: try strings(output.quarantined)
                )
            case ABI.syncConflict:
                return .conflict(
                    remoteRevision: output.has_revision != 0
                        ? Revision(raw: output.revision)
                        : nil,
                    reason: copyString(output.reason)
                )
            default:
                throw internalFailure(
                    "potluckdb returned an unknown synchronization result"
                )
            }
        }
    }

    public func resolveConflict() throws -> ConflictResolution {
        try state.withHandle { handle in
            var output = PotluckDbConflictResolutionV1()
            potluckdb_conflict_resolution_init_v1(&output)
            try applicationCall { error in
                potluckdb_database_resolve_conflict_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbConflictResolutionV1>.size),
                    error
                )
            }
            defer { _ = potluckdb_conflict_resolution_release_v1(&output) }
            return ConflictResolution(
                revision: Revision(raw: output.revision),
                alreadyPublished: try strings(output.already_published),
                replayed: try strings(output.replayed),
                quarantined: try strings(output.quarantined),
                pending: try strings(output.pending)
            )
        }
    }

    @discardableResult
    public func setSyncPolicy(_ policy: SyncPolicy) throws -> DatabaseStatus {
        var rawPolicy = rawSyncPolicy(policy)
        return try state.withHandle { handle in
            var output = PotluckDbDatabaseStatusV1()
            potluckdb_database_status_init_v1(&output)
            try applicationCall { error in
                potluckdb_database_set_sync_policy_v1(
                    handle,
                    &rawPolicy,
                    &output,
                    UInt32(MemoryLayout<PotluckDbDatabaseStatusV1>.size),
                    error
                )
            }
            return databaseStatus(output)
        }
    }

    @discardableResult
    public func clearQuarantineRecords() throws -> UInt64 {
        try state.withHandle { handle in
            var output: UInt64 = 0
            try applicationCall { error in
                potluckdb_database_clear_quarantine_records_v1(handle, &output, error)
            }
            return output
        }
    }

    public func status() throws -> DatabaseStatus {
        try state.withHandle { handle in
            var output = PotluckDbDatabaseStatusV1()
            potluckdb_database_status_init_v1(&output)
            try applicationCall { error in
                potluckdb_database_status_v1(
                    handle,
                    &output,
                    UInt32(MemoryLayout<PotluckDbDatabaseStatusV1>.size),
                    error
                )
            }
            return databaseStatus(output)
        }
    }

    public func close() throws {
        try state.close()
    }
}

public func open(_ path: String, options: OpenOptions = .defaults) throws -> Database {
    try withRawOpenOptions(options) { rawOptions in
        try withSlice(path) { pathSlice in
            var output: PotluckDbDatabaseHandleV1 = 0
            try applicationCall { error in
                potluckdb_open_v1(pathSlice, 0, rawOptions, &output, error)
            }
            return Database(
                state: try HandleState(
                    handle: output,
                    close: potluckdb_database_close_v1,
                    release: potluckdb_database_release_v1
                )
            )
        }
    }
}

public func open(
    _ path: String,
    remote: Remote,
    options: OpenOptions = .defaults
) throws -> Database {
    try withRawOpenOptions(options) { rawOptions in
        try withSlice(path) { pathSlice in
            try remote.state.withHandle { remoteHandle in
                var output: PotluckDbDatabaseHandleV1 = 0
                try applicationCall { error in
                    potluckdb_open_v1(
                        pathSlice,
                        remoteHandle,
                        rawOptions,
                        &output,
                        error
                    )
                }
                return Database(
                    state: try HandleState(
                        handle: output,
                        close: potluckdb_database_close_v1,
                        release: potluckdb_database_release_v1,
                        retained: remote.state
                    )
                )
            }
        }
    }
}

public func openRevision(
    _ path: String,
    revision: Revision,
    remote: Remote,
    options: OpenOptions = .defaults
) throws -> Snapshot {
    var rawRevision = revision.raw
    return try withRawOpenOptions(options) { rawOptions in
        try withSlice(path) { pathSlice in
            try remote.state.withHandle { remoteHandle in
                var output: PotluckDbSnapshotHandleV1 = 0
                try applicationCall { error in
                    potluckdb_open_revision_v1(
                        pathSlice,
                        &rawRevision,
                        remoteHandle,
                        rawOptions,
                        &output,
                        error
                    )
                }
                return Snapshot(
                    state: try HandleState(
                        handle: output,
                        close: potluckdb_snapshot_close_v1,
                        release: potluckdb_snapshot_release_v1,
                        retained: remote.state
                    )
                )
            }
        }
    }
}

public enum Admin {
    public static func reencrypt(
        source: Remote,
        target: Remote,
        newKey: Data,
        sourceKey: Data? = nil,
        revision: Revision? = nil
    ) throws -> KeyRotationReport {
        guard newKey.count == 32 else {
            throw PotluckDBError.invalidArgument(
                "encryption key must contain exactly 32 bytes",
                action: "Supply a 32-byte key and retry."
            )
        }
        guard sourceKey == nil || sourceKey?.count == 32 else {
            throw PotluckDBError.invalidArgument(
                "source encryption key must contain exactly 32 bytes",
                action: "Supply a 32-byte key and retry."
            )
        }
        var options = PotluckDbReencryptOptionsV1()
        potluckdb_reencrypt_options_init_v1(&options)
        _ = withUnsafeMutableBytes(of: &options.new_key) { destination in
            newKey.copyBytes(to: destination)
        }
        if let sourceKey {
            options.flags |= ABI.reencryptSourceKey
            _ = withUnsafeMutableBytes(of: &options.source_key) { destination in
                sourceKey.copyBytes(to: destination)
            }
        }
        if let revision {
            options.flags |= ABI.reencryptRevision
            options.revision = revision.raw
        }
        return try HandleState.withPair(
            source.state,
            target.state
        ) { sourceHandle, targetHandle in
            var output = PotluckDbKeyRotationReportV1()
            potluckdb_key_rotation_report_init_v1(&output)
            try applicationCall { error in
                potluckdb_admin_reencrypt_v1(
                    sourceHandle,
                    targetHandle,
                    &options,
                    &output,
                    UInt32(MemoryLayout<PotluckDbKeyRotationReportV1>.size),
                    error
                )
            }
            return KeyRotationReport(
                sourceRevision: Revision(raw: output.source_revision),
                targetRevision: Revision(raw: output.target_revision),
                sourceKeyID: output.has_source_key_id != 0
                    ? Revision(raw: output.source_key_id)
                    : nil,
                targetKeyID: Revision(raw: output.target_key_id),
                pieceCount: output.piece_count,
                published: output.published != 0
            )
        }
    }
}
