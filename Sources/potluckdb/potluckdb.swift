import Foundation
import PotluckDBRuntime
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@_silgen_name("potluckdb_internal_storage_callback_active_v1")
private func nativeStorageCallbackActive() -> UInt32

private enum ABI {
    static let ok: Int32 = 0
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
    static let syncFailed: UInt32 = 5
    static let openEncryptionKey: UInt32 = 1
    static let openClientID: UInt32 = 2
    static let openLicenseKey: UInt32 = 4
    static let openAnalyticalEngine: UInt32 = 8
    static let querySQLite: UInt32 = 0
    static let queryDuckDB: UInt32 = 1
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

public struct PotluckDBError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let category: ErrorCategory
    public let message: String
    public let action: String

    public init(code: String, category: ErrorCategory, message: String, action: String) {
        self.code = code
        self.category = category
        self.message = message
        self.action = action
    }

    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { action }

    fileprivate static func invalidArgument(_ message: String, action: String) -> Self {
        Self(
            code: "invalid_argument",
            category: .caller,
            message: message,
            action: action
        )
    }

    fileprivate static func storageUnavailable(_ message: String) -> Self {
        Self(
            code: "storage_library_unavailable",
            category: .permanent,
            message: message,
            action: "Ship libpotluckdb_storage beside the program, or set "
                + "POTLUCKDB_STORAGE_LIBRARY to one already on this machine."
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
        let code = copyString(error.code)
        let action = code == "analytical_engine_unavailable"
            ? "Download the platform DuckDB library from https://docs.potluckdb.com/install/swift/#analytics and set OpenOptions.analyticalEngine to its path."
            : copyString(error.action)
        let translated = PotluckDBError(
            code: code,
            category: errorCategory(error.category),
            message: copyString(error.message),
            action: action
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
    /// Keeps every revision until collect runs with a bounded policy.
    public static let unbounded = Self(keepLast: 0, collectAt: 0)
    public var isBounded: Bool { keepLast != 0 }

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
    public static let defaults = ConnectionOptions()

    public let timeoutMilliseconds: UInt64
    public let maximumRows: UInt64
    public let prefetch: PrefetchPolicy
    public let checkpoint: CheckpointPolicy

    public init(
        timeoutMilliseconds: UInt64 = 5_000,
        maximumRows: UInt64 = 1_000_000,
        prefetch: PrefetchPolicy = .automatic(),
        checkpoint: CheckpointPolicy = .automatic()
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumRows = maximumRows
        self.prefetch = prefetch
        self.checkpoint = checkpoint
    }

    func validate() throws {
        guard timeoutMilliseconds <= 86_400_000, maximumRows > 0 else {
            throw PotluckDBError.invalidArgument(
                "connection timeout or result limit is outside the supported bounds",
                action: "Use a timeout up to one day and a positive maximumRows."
            )
        }
    }
}

public struct OpenOptions: Equatable, Sendable {
    public static let defaults = OpenOptions()

    public let localBudgetBytes: UInt64
    public let minimumLocalBudgetBytes: UInt64
    public let localCompactionBytes: UInt64
    public let encryptionKey: Data?
    public let syncPolicy: SyncPolicy
    public let clientID: String?
    /// Supplies the license key described in contracts/licensing.md#requirements.
    public let licenseKey: String?
    public let analyticalEngine: String?
    public let connection: ConnectionOptions
    /// Receives the outcome of every automatic synchronization attempt of
    /// a `Database`: `.upToDate`, `.pushed`, `.pulled`, `.conflict` or
    /// `.failed` carrying the error. The hook is invoked on the
    /// synchronization thread. Do not call the database from inside it;
    /// transfer the outcome to the program's own thread. `Database.close()`
    /// returns after the last invocation. A `Snapshot` never synchronizes,
    /// so `openRevision` ignores it. Two option values compare equal when
    /// both carry a hook or neither does; the hooks themselves are not
    /// compared.
    public let onSync: (@Sendable (SyncResult) -> Void)?

    public init(
        localBudgetBytes: UInt64 = 1_024 * 1_024 * 1_024,
        minimumLocalBudgetBytes: UInt64 = 10 * 1_024 * 1_024,
        localCompactionBytes: UInt64 = 256 * 1_024 * 1_024,
        encryptionKey: Data? = nil,
        syncPolicy: SyncPolicy = .automatic(),
        clientID: String? = nil,
        licenseKey: String? = nil,
        analyticalEngine: String? = nil,
        connection: ConnectionOptions = .defaults,
        onSync: (@Sendable (SyncResult) -> Void)? = nil
    ) {
        self.localBudgetBytes = localBudgetBytes
        self.minimumLocalBudgetBytes = minimumLocalBudgetBytes
        self.localCompactionBytes = localCompactionBytes
        self.encryptionKey = encryptionKey
        self.syncPolicy = syncPolicy
        self.clientID = clientID
        self.licenseKey = licenseKey
        self.analyticalEngine = analyticalEngine
        self.connection = connection
        self.onSync = onSync
    }

    public static func == (left: OpenOptions, right: OpenOptions) -> Bool {
        left.localBudgetBytes == right.localBudgetBytes
            && left.minimumLocalBudgetBytes == right.minimumLocalBudgetBytes
            && left.localCompactionBytes == right.localCompactionBytes
            && left.encryptionKey == right.encryptionKey
            && left.syncPolicy == right.syncPolicy
            && left.clientID == right.clientID
            && left.licenseKey == right.licenseKey
            && left.analyticalEngine == right.analyticalEngine
            && left.connection == right.connection
            && (left.onSync == nil) == (right.onSync == nil)
    }

    /// Refuses a combination the runtime would refuse, before the call
    /// that would carry it. Construction itself cannot fail.
    func validate() throws {
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
        try connection.validate()
    }
}

public struct RemoteOptions: Equatable, Sendable {
    public static let defaults = RemoteOptions()

    public let readConcurrency: UInt32
    public let writeConcurrency: UInt32
    /// Bounded by default: keep the newest ten revisions, collect once twenty exist.
    public let retention: RetentionPolicy

    public init(
        readConcurrency: UInt32 = 32,
        writeConcurrency: UInt32 = 16,
        retention: RetentionPolicy = .defaults
    ) {
        self.readConcurrency = readConcurrency
        self.writeConcurrency = writeConcurrency
        self.retention = retention
    }

    func validate() throws {
        guard (1 ... 256).contains(readConcurrency), (1 ... 128).contains(writeConcurrency) else {
            throw PotluckDBError.invalidArgument(
                "remote concurrency is outside the supported bounds",
                action: "Use read concurrency 1 through 256 and write concurrency 1 through 128."
            )
        }
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

public enum QueryEngine: Sendable {
    case sqlite
    case duckdb

    fileprivate var abiSelector: UInt32 {
        switch self {
        case .sqlite: return ABI.querySQLite
        case .duckdb: return ABI.queryDuckDB
        }
    }
}

/// One result row, readable by position or by column name. A name that
/// appears twice answers its last position.
public struct Row: RandomAccessCollection, Equatable, Sendable {
    /// The column names in select-list order.
    public let columns: [String]
    /// The cells in select-list order.
    public let values: [SQLValue]

    public init(columns: [String], values: [SQLValue]) {
        self.columns = columns
        self.values = values
    }

    public var startIndex: Int { values.startIndex }
    public var endIndex: Int { values.endIndex }
    public subscript(position: Int) -> SQLValue { values[position] }

    /// The cell under the named column, or nil when the select list has no
    /// such column.
    public subscript(column: String) -> SQLValue? {
        guard let index = columns.lastIndex(where: { $0.utf8.elementsEqual(column.utf8) }) else { return nil }
        return values[index]
    }

    public static func == (left: Row, right: [SQLValue]) -> Bool { left.values == right }
    public static func != (left: Row, right: [SQLValue]) -> Bool { left.values != right }
}

/// A query result: the column names of the select list in order, then the
/// rows.
public struct Rows: RandomAccessCollection, Equatable, Sendable {
    /// The column names in select-list order; a name that appears twice is
    /// listed twice.
    public let columns: [String]
    /// The rows in result order.
    public let rows: [Row]

    public init(columns: [String], values: [[SQLValue]]) {
        self.columns = columns
        rows = values.map { Row(columns: columns, values: $0) }
    }

    public var startIndex: Int { rows.startIndex }
    public var endIndex: Int { rows.endIndex }
    public subscript(position: Int) -> Row { rows[position] }

    public static func == (left: Rows, right: [[SQLValue]]) -> Bool {
        left.rows.map(\.values) == right
    }
    public static func != (left: Rows, right: [[SQLValue]]) -> Bool { !(left == right) }
}

public struct ExecuteResult: Equatable, Sendable {
    public let rowsAffected: Int64
    public let lastInsertID: Int64?
}

public enum SyncResult: Equatable, Sendable {
    case upToDate(revision: Revision?)
    case pushed(revision: Revision)
    case pulled(revision: Revision, replayed: [String], quarantined: [String])
    case conflict(remoteRevision: Revision?, reason: String)
    /// An automatic attempt that failed, carrying the error `Database.sync()`
    /// would have thrown. Only `OpenOptions.onSync` delivers it: `sync()`
    /// throws the error itself.
    case failed(error: PotluckDBError)
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
    hook: SyncHook?,
    _ body: (UnsafePointer<PotluckDbOpenOptionsV1>) throws -> T
) throws -> T {
    try source.validate()
    func invoke(
        _ clientID: PotluckDbSliceV1?, _ licenseKey: PotluckDbSliceV1?,
        _ analyticalEngine: PotluckDbSliceV1?
    ) throws -> T {
        var value = PotluckDbOpenOptionsV1()
        potluckdb_open_options_init_v1(&value)
        value.local_budget_bytes = source.localBudgetBytes
        value.minimum_local_budget_bytes = source.minimumLocalBudgetBytes
        value.local_compaction_bytes = source.localCompactionBytes
        value.sync_policy = rawSyncPolicy(source.syncPolicy)
        value.connection = rawConnectionOptions(source.connection)
        if let hook {
            value.on_sync = deliverSync
            value.on_sync_context = hook.context
        }
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
        if let licenseKey {
            value.flags |= ABI.openLicenseKey
            value.license_key = licenseKey
        }
        if let analyticalEngine {
            value.flags |= ABI.openAnalyticalEngine
            value.analytical_engine = analyticalEngine
        }
        return try withUnsafePointer(to: &value, body)
    }

    func withAnalyticalEngine(
        _ clientID: PotluckDbSliceV1?, _ licenseKey: PotluckDbSliceV1?
    ) throws -> T {
        if let selection = source.analyticalEngine {
            return try withSlice(selection) { slice in try invoke(clientID, licenseKey, slice) }
        }
        return try invoke(clientID, licenseKey, nil)
    }

    func withLicenseKey(_ clientID: PotluckDbSliceV1?) throws -> T {
        if let licenseKey = source.licenseKey {
            return try withSlice(licenseKey) { slice in try withAnalyticalEngine(clientID, slice) }
        }
        return try withAnalyticalEngine(clientID, nil)
    }

    if let clientID = source.clientID {
        return try withSlice(clientID) { slice in try withLicenseKey(slice) }
    }
    return try withLicenseKey(nil)
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
    value.flags &= ~ABI.remoteRetention
    if source.retention.isBounded {
        value.flags |= ABI.remoteRetention
        value.retention = rawRetentionPolicy(source.retention)
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
        action: "Preserve the failure details and report this error."
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
    var nameCount: UInt64 = 0
    try applicationCall { error in
        potluckdb_rows_column_name_count_v1(handle, &nameCount, error)
    }
    var columns: [String] = []
    columns.reserveCapacity(Int(nameCount))
    for column in 0 ..< nameCount {
        var name = PotluckDbSliceV1()
        try applicationCall { error in
            potluckdb_rows_column_name_v1(handle, column, &name, error)
        }
        columns.append(
            String(
                decoding: UnsafeBufferPointer(start: name.data, count: Int(name.length)),
                as: UTF8.self
            )
        )
    }
    var rowCount: UInt64 = 0
    try applicationCall { error in
        potluckdb_rows_row_count_v1(handle, &rowCount, error)
    }
    var rows: [[SQLValue]] = []
    rows.reserveCapacity(Int(rowCount))
    for rowIndex in 0 ..< rowCount {
        var columnCount: UInt64 = 0
        try applicationCall { error in
            potluckdb_rows_column_count_v1(handle, rowIndex, &columnCount, error)
        }
        var row: [SQLValue] = []
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
    return Rows(columns: columns, values: rows)
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
    // afterClose runs only after a successful close or release. A storage-library adapter is given
    // back here: the runtime keeps the table's context for the life of
    // the exchange, so the adapter must not go back before close.
    fileprivate var afterClose: (() -> Void)?

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
        if !cleanup() { orphanBorrowers() }
    }

    fileprivate func cleanup() -> Bool {
        if nativeStorageCallbackActive() != 0 { return false }
        lock.lock()
        defer { lock.unlock() }
        if handle != 0 {
            if let closeFunction, !closed, closeFunction(handle, nil) != ABI.ok {
                return false
            }
            let result = releaseFunction(handle, nil)
            if result != ABI.ok && closeFunction != nil {
                return false
            }
            handle = 0
            retained = nil
        }
        runAfterCloseLocked()
        return true
    }

    private static let orphanLock = NSLock()
    private static var orphanedBorrowers: [(AnyObject?, (() -> Void)?)] = []

    private func orphanBorrowers() {
        Self.orphanLock.lock()
        defer { Self.orphanLock.unlock() }
        Self.orphanedBorrowers.append((retained, afterClose))
    }

    func withHandle<T>(_ body: (UInt64) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0 else {
            throw PotluckDBError(
                code: "invalid_state",
                category: .caller,
                message: "potluckdb owner is released",
                action: "Open a new owner and retry."
            )
        }
        return try body(handle)
    }

    func close() throws {
        if nativeStorageCallbackActive() != 0 {
            throw PotluckDBError(code: "invalid_state", category: .caller,
                                message: "recursive close from a storage callback is refused",
                                action: "Close the owner after the callback returns.")
        }
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0, !closed else { return }
        guard let closeFunction else {
            throw internalFailure("this potluckdb capability has no close operation")
        }
        try applicationCall { error in closeFunction(handle, error) }
        closed = true
        runAfterCloseLocked()
    }

    fileprivate func runAfterCloseLocked() {
        let action = afterClose
        afterClose = nil
        action?()
    }

    func release() throws {
        lock.lock()
        defer { lock.unlock() }
        guard handle != 0 else { return }
        var consumed = false
        defer {
            if consumed || closeFunction == nil {
                handle = 0
                retained = nil
                runAfterCloseLocked()
            }
        }
        try applicationCall { error in releaseFunction(handle, error) }
        consumed = true
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
                action: "Open new Remote values and retry."
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
        try options.validate()
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
        try options.validate()
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
    public func collect(_ retention: RetentionPolicy) throws -> CollectionReport {
        guard retention.isBounded else {
            throw PotluckDBError.invalidArgument(
                "collect needs a bounded retention policy",
                action: "Pass RetentionPolicy.bounded()."
            )
        }
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

    public func query(
        _ sql: String,
        _ bindings: Bindings = .none,
        engine: QueryEngine = .sqlite
    ) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_transaction_query_with_engine_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            engine.abiSelector,
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
        _ bindings: Bindings = .none
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

    public func query(
        _ sql: String,
        _ bindings: Bindings = .none,
        engine: QueryEngine = .sqlite
    ) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_connection_query_with_engine_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            engine.abiSelector,
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
        _ bindings: Bindings = .none
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

    public func query(
        _ sql: String,
        _ bindings: Bindings = .none,
        engine: QueryEngine = .sqlite
    ) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_snapshot_query_with_engine_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            engine.abiSelector,
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

    public func query(
        _ sql: String,
        _ bindings: Bindings = .none,
        engine: QueryEngine = .sqlite
    ) throws -> Rows {
        let rawBindings = RawBindings(bindings)
        return try state.withHandle { handle in
            try withSlice(sql) { sqlSlice in
                try rawBindings.withPointer { bindingsPointer in
                    var rows: PotluckDbRowsHandleV1 = 0
                    try applicationCall { error in
                        potluckdb_database_query_with_engine_v1(
                            handle,
                            sqlSlice,
                            bindingsPointer,
                            engine.abiSelector,
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
        _ bindings: Bindings = .none
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
        try options.validate()
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
            return try syncResult(output)
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

/// The facade's reading of one raw synchronization outcome. The raw value
/// stays with its owner; the caller releases it.
private func syncResult(_ output: PotluckDbSyncResultV1) throws -> SyncResult {
    switch output.kind {
    case ABI.syncUpToDate:
        return .upToDate(
            revision: output.has_revision != 0 ? Revision(raw: output.revision) : nil
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
            remoteRevision: output.has_revision != 0 ? Revision(raw: output.revision) : nil,
            reason: copyString(output.reason)
        )
    case ABI.syncFailed:
        return .failed(
            error: PotluckDBError(
                code: copyString(output.error.code),
                category: errorCategory(output.error.category),
                message: copyString(output.error.message),
                action: copyString(output.error.action)
            )
        )
    default:
        throw internalFailure("potluckdb returned an unknown synchronization result")
    }
}

/// The registered `OpenOptions.onSync`. The database that registered it
/// keeps it alive until its handle is released; the runtime returns from
/// close only after the hook's last invocation.
private final class SyncHook {
    let hook: @Sendable (SyncResult) -> Void

    init(_ hook: @escaping @Sendable (SyncResult) -> Void) {
        self.hook = hook
    }

    static func from(_ options: OpenOptions) -> SyncHook? {
        options.onSync.map { SyncHook($0) }
    }

    var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

/// What a database opened against a remote keeps alive: the remote's
/// handle state and the hook it registered, if any.
private final class DatabaseRetention {
    let remote: HandleState
    let hook: SyncHook?

    init(remote: HandleState, hook: SyncHook?) {
        self.remote = remote
        self.hook = hook
    }
}

/// `PotluckDbOnSyncV1`. An outcome the facade cannot read is delivered as
/// `.failed` carrying the facade's error.
private func deliverSync(
    _ context: UnsafeMutableRawPointer?, _ outcome: PotluckDbSyncResultV1
) {
    var raw = outcome
    let result: SyncResult
    do {
        result = try syncResult(raw)
    } catch let error as PotluckDBError {
        result = .failed(error: error)
    } catch {
        result = .failed(error: internalFailure("\(error)"))
    }
    _ = potluckdb_sync_result_release_v1(&raw)
    guard let context else { return }
    Unmanaged<SyncHook>.fromOpaque(context).takeUnretainedValue().hook(result)
}

public func open(_ path: String, options: OpenOptions = .defaults) throws -> Database {
    let hook = SyncHook.from(options)
    return try withRawOpenOptions(options, hook: hook) { rawOptions in
        try withSlice(path) { pathSlice in
            var output: PotluckDbDatabaseHandleV1 = 0
            try applicationCall { error in
                potluckdb_open_v1(pathSlice, 0, rawOptions, &output, error)
            }
            return Database(
                state: try HandleState(
                    handle: output,
                    close: potluckdb_database_close_v1,
                    release: potluckdb_database_release_v1,
                    retained: hook
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
    let hook = SyncHook.from(options)
    return try withRawOpenOptions(options, hook: hook) { rawOptions in
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
                        retained: DatabaseRetention(remote: remote.state, hook: hook)
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
    return try withRawOpenOptions(options, hook: nil) { rawOptions in
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

// MARK: - The Seam-4 bucket bridge
//
// Remote.fromStorage used to take a pointer to a native
// PotluckDbRuntimeBucketAdapterV1 that nothing in this SDK could build.
// What follows fills one in from a BucketStorage, so an application
// implements the protocol and hands that over instead.

/// An observational Seam-4 adapter-counter snapshot.
///
/// B12 separates the logical operations the seam names from the provider
/// API calls they cause. No counter measures physical object versions or
/// reclaimed storage bytes.
public struct BucketCounterSnapshot: Equatable, Sendable {
    public var gets: UInt64
    public var puts: UInt64
    public var idempotentPuts: UInt64
    public var exists: UInt64
    public var lists: UInt64
    public var deletes: UInt64
    public var cellGets: UInt64
    public var cellSwaps: UInt64
    public var cellSwapWins: UInt64
    public var transportGets: UInt64
    public var transportPuts: UInt64
    public var transportHeads: UInt64
    public var transportLists: UInt64
    public var transportDeletes: UInt64
    public var transportBytesReceived: UInt64
    public var transportBytesSubmitted: UInt64

    public init(
        gets: UInt64 = 0,
        puts: UInt64 = 0,
        idempotentPuts: UInt64 = 0,
        exists: UInt64 = 0,
        lists: UInt64 = 0,
        deletes: UInt64 = 0,
        cellGets: UInt64 = 0,
        cellSwaps: UInt64 = 0,
        cellSwapWins: UInt64 = 0,
        transportGets: UInt64 = 0,
        transportPuts: UInt64 = 0,
        transportHeads: UInt64 = 0,
        transportLists: UInt64 = 0,
        transportDeletes: UInt64 = 0,
        transportBytesReceived: UInt64 = 0,
        transportBytesSubmitted: UInt64 = 0
    ) {
        self.gets = gets
        self.puts = puts
        self.idempotentPuts = idempotentPuts
        self.exists = exists
        self.lists = lists
        self.deletes = deletes
        self.cellGets = cellGets
        self.cellSwaps = cellSwaps
        self.cellSwapWins = cellSwapWins
        self.transportGets = transportGets
        self.transportPuts = transportPuts
        self.transportHeads = transportHeads
        self.transportLists = transportLists
        self.transportDeletes = transportDeletes
        self.transportBytesReceived = transportBytesReceived
        self.transportBytesSubmitted = transportBytesSubmitted
    }
}

/// One head-and-floor observation, as Seam 4 B13 defines it. A nil value
/// is an absent cell. The two reads overlap but are still two reads: the
/// pair is a finite concurrent observation, never an atomic snapshot.
public struct CellPair: Equatable, Sendable {
    public var head: [UInt8]?
    public var floor: [UInt8]?

    public init(head: [UInt8]?, floor: [UInt8]?) {
        self.head = head
        self.floor = floor
    }
}

/// One Seam-4 bucket: immutable objects plus the head and floor
/// compare-and-swap cells.
///
/// Threading. B10 and B11 let immutable `get` and `put` calls overlap on
/// one instance, so every member must be safe for concurrent use. Mutable
/// cell calls stay on the exchange caller, and a callback may arrive on
/// any runtime worker thread.
///
/// Failures. Throw `PotluckDBError` carrying one of the seam's codes --
/// `missing`, `conflict`, `unavailable`, or `contract_violation` -- and
/// the runtime receives that classification with the message intact. Any
/// other error becomes `internal_failure`: guessing `unavailable` would
/// read as a transport problem the caller could retry, and guessing
/// `missing` would read as a satisfied absence.
///
/// Lifetime. The runtime copies the callback table but never owns the
/// implementor. It stays referenced by the `Remote` that borrowed it, and
/// callbacks may arrive until that Remote is released.
public protocol BucketStorage: AnyObject {
    /// Read an immutable object; absent is `missing`.
    func get(_ key: String) throws -> [UInt8]
    /// Create an object, or verify that it already agrees.
    func put(_ key: String, data: [UInt8]) throws
    /// Whether an immutable object exists.
    func exists(_ key: String) throws -> Bool
    /// Matching logical object keys, in lexical order.
    func list(_ prefix: String) throws -> [String]
    /// Make an object logically absent; an already absent object succeeds.
    func delete(_ key: String) throws
    /// Read the head cell; absent is `missing`.
    func headGet() throws -> [UInt8]
    /// Replace the head only when it equals `expected`; nil is absence.
    func headSwap(expected: [UInt8]?, value: [UInt8]) throws -> Bool
    /// Read the retention-floor cell; absent is `missing`.
    func floorGet() throws -> [UInt8]
    /// Replace the floor only when it equals `expected`; nil is absence.
    func floorSwap(expected: [UInt8]?, value: [UInt8]) throws -> Bool
    /// An observational Seam-4 counter snapshot.
    func counters() -> BucketCounterSnapshot
}

/// The optional B13 capability: head and floor as one finite concurrent
/// observation. Conforming declares it; a bucket that does not conform
/// gets the serial `headGet` then `floorGet` fallback.
public protocol CellPairBucketStorage: BucketStorage {
    func cellPairGet() throws -> CellPair
}

private enum Seam {
    static let ok: Int32 = 0
    static let internalFailure: Int32 = 1
    static let contractViolation: Int32 = 18
    static let abiVersion: UInt32 = 1

    /// The Runtime Interface error codes, by the name the runtime gives
    /// them. B5 names four: `missing`, `conflict`, `unavailable`, and
    /// `contract_violation` for a bucket answering outside its interface.
    static let codes: [String: Int32] = [
        "internal_failure": 1,
        "missing": 2,
        "storage_full": 3,
        "storage_unavailable": 4,
        "integrity_error": 5,
        "conflict": 6,
        "unavailable": 7,
        "format_version_unsupported": 8,
        "key_required": 9,
        "wrong_key_or_corrupt": 10,
        "remote_read_required": 11,
        "read_only_revision": 12,
        "history_retired": 13,
        "sync_deferred": 14,
        "write_capacity_exceeded": 15,
        "budget_refused": 16,
        "identity_refused": 17,
        "contract_violation": 18,
        "identity_collision": 19,
        "sqlite_error": 20,
        "execution_engine_error": 21,
        "storage_unsupported": 23,
        "bucket_not_found": 24,
    ]
}

/// The managed half of the bridge: one implementor and its retained
/// host-error messages.
private final class BucketBridge {
    let storage: BucketStorage
    let pair: CellPairBucketStorage?

    /// How many distinct host-error messages one adapter retains. The
    /// Application ABI requires a message to stay immutable through the
    /// enclosing ABI call, and callbacks that overlap have no earlier
    /// reclamation point than the adapter itself.
    private static let messageLimit = 4_096
    private static let messageOverflow =
        "bucket adapter error message retention limit reached"

    private let lock = NSLock()
    private var messages: [[UInt8]: (pointer: UnsafeMutableRawPointer, length: Int)] = [:]

    init(storage: BucketStorage) {
        self.storage = storage
        pair = storage as? CellPairBucketStorage
    }

    /// One retained copy, reused when the same message returns.
    func retain(_ message: String) -> (pointer: UnsafeMutableRawPointer, length: Int) {
        lock.lock()
        defer { lock.unlock() }
        var bytes = Array(message.utf8)
        if messages[bytes] == nil, messages.count >= Self.messageLimit {
            bytes = Array(Self.messageOverflow.utf8)
        }
        if let held = messages[bytes] { return held }
        let copy = UnsafeMutableRawPointer.allocate(
            byteCount: max(bytes.count, 1),
            alignment: 1
        )
        bytes.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                copy.copyMemory(from: base, byteCount: buffer.count)
            }
        }
        let held = (pointer: copy, length: bytes.count)
        messages[bytes] = held
        return held
    }

    func releaseMessages() {
        lock.lock()
        defer { lock.unlock() }
        for held in messages.values { held.pointer.deallocate() }
        messages.removeAll()
    }
}

/// The adapter table and everything it points at.
///
/// A `Remote` retains this; the handle's `deinit` closes and releases the
/// native exchange before its retained values are dropped, so the table is
/// freed only once nothing can call back through it.
private final class BucketAdapterOwner {
    let bridge: BucketBridge
    let table: UnsafeMutablePointer<PotluckDbRuntimeBucketAdapterV1>

    init(storage: BucketStorage) {
        let bridge = BucketBridge(storage: storage)
        self.bridge = bridge
        table = UnsafeMutablePointer<PotluckDbRuntimeBucketAdapterV1>.allocate(capacity: 1)
        table.initialize(to: PotluckDbRuntimeBucketAdapterV1())
        // Filled in rather than initialized through the Runtime Interface:
        // an application SDK calls the Application ABI and nothing below it.
        table.pointee.struct_size = UInt32(
            MemoryLayout<PotluckDbRuntimeBucketAdapterV1>.size
        )
        table.pointee.abi_version = Seam.abiVersion
        table.pointee.context = Unmanaged.passUnretained(bridge).toOpaque()
        table.pointee.get = bucketGet
        table.pointee.put = bucketPut
        table.pointee.exists = bucketExists
        table.pointee.list = bucketList
        table.pointee.delete_value = bucketDelete
        table.pointee.head_get = bucketHeadGet
        table.pointee.head_swap = bucketHeadSwap
        table.pointee.floor_get = bucketFloorGet
        table.pointee.floor_swap = bucketFloorSwap
        table.pointee.cell_pair_get = bridge.pair == nil ? nil : bucketCellPairGet
        table.pointee.counters = bucketCounters
    }

    deinit {
        bridge.releaseMessages()
        table.deinitialize(count: 1)
        table.deallocate()
    }
}

private func bucketBridge(_ context: UnsafeMutableRawPointer?) -> BucketBridge? {
    guard let context else { return nil }
    return Unmanaged<BucketBridge>.fromOpaque(context).takeUnretainedValue()
}

private func resetHostError(_ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?) {
    guard let error else { return }
    error.pointee.struct_size = UInt32(MemoryLayout<PotluckDbRuntimeHostErrorV1>.size)
    error.pointee.abi_version = Seam.abiVersion
    error.pointee.sqlite_primary_code = 0
    error.pointee.sqlite_extended_code = 0
    error.pointee.message = PotluckDbRuntimeSliceV1()
}

private func bucketFail(
    _ bridge: BucketBridge,
    _ code: Int32,
    _ message: String,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    let held = bridge.retain(message)
    if let error {
        error.pointee.struct_size = UInt32(MemoryLayout<PotluckDbRuntimeHostErrorV1>.size)
        error.pointee.abi_version = Seam.abiVersion
        error.pointee.sqlite_primary_code = 0
        error.pointee.sqlite_extended_code = 0
        var slice = PotluckDbRuntimeSliceV1()
        slice.data = UnsafePointer(held.pointer.assumingMemoryBound(to: UInt8.self))
        slice.length = UInt64(held.length)
        error.pointee.message = slice
    }
    return code
}

private func bucketFail(
    _ bridge: BucketBridge,
    _ failure: Error,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    if let typed = failure as? PotluckDBError {
        let code = Seam.codes[typed.code] ?? Seam.internalFailure
        return bucketFail(bridge, code, typed.message, error)
    }
    return bucketFail(bridge, Seam.internalFailure, "\(failure)", error)
}

private func bucketBytes(_ slice: PotluckDbRuntimeSliceV1) -> [UInt8] {
    guard slice.length > 0, let data = slice.data else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(slice.length)))
}

private func bucketText(_ slice: PotluckDbRuntimeSliceV1) -> String {
    String(decoding: bucketBytes(slice), as: UTF8.self)
}

private func bucketEmit(
    _ emit: PotluckDbRuntimeEmitBytesV1?,
    _ context: UnsafeMutableRawPointer?,
    _ value: [UInt8]
) -> Int32 {
    guard let emit else { return Seam.contractViolation }
    var slice = PotluckDbRuntimeSliceV1()
    guard !value.isEmpty else { return emit(context, slice) }
    return value.withUnsafeBufferPointer { buffer in
        slice.data = buffer.baseAddress
        slice.length = UInt64(buffer.count)
        return emit(context, slice)
    }
}

private func bucketGet(
    _ context: UnsafeMutableRawPointer?,
    _ key: PotluckDbRuntimeSliceV1,
    _ emit: PotluckDbRuntimeEmitBytesV1?,
    _ emitContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    do {
        return bucketEmit(emit, emitContext, try bridge.storage.get(bucketText(key)))
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketPut(
    _ context: UnsafeMutableRawPointer?,
    _ key: PotluckDbRuntimeSliceV1,
    _ data: PotluckDbRuntimeSliceV1,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    do {
        try bridge.storage.put(bucketText(key), data: bucketBytes(data))
        return Seam.ok
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketExists(
    _ context: UnsafeMutableRawPointer?,
    _ key: PotluckDbRuntimeSliceV1,
    _ outExists: UnsafeMutablePointer<UInt32>?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    guard let outExists else {
        return bucketFail(
            bridge, Seam.contractViolation, "bucket exists output is null", error
        )
    }
    do {
        outExists.pointee = try bridge.storage.exists(bucketText(key)) ? 1 : 0
        return Seam.ok
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketList(
    _ context: UnsafeMutableRawPointer?,
    _ prefix: PotluckDbRuntimeSliceV1,
    _ emit: PotluckDbRuntimeEmitBytesV1?,
    _ emitContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    do {
        for key in try bridge.storage.list(bucketText(prefix)) {
            let code = bucketEmit(emit, emitContext, Array(key.utf8))
            if code != Seam.ok { return code }
        }
        return Seam.ok
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketDelete(
    _ context: UnsafeMutableRawPointer?,
    _ key: PotluckDbRuntimeSliceV1,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    do {
        try bridge.storage.delete(bucketText(key))
        return Seam.ok
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketCell(
    _ context: UnsafeMutableRawPointer?,
    _ head: Bool,
    _ emit: PotluckDbRuntimeEmitBytesV1?,
    _ emitContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    do {
        let value = head
            ? try bridge.storage.headGet()
            : try bridge.storage.floorGet()
        return bucketEmit(emit, emitContext, value)
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketHeadGet(
    _ context: UnsafeMutableRawPointer?,
    _ emit: PotluckDbRuntimeEmitBytesV1?,
    _ emitContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    bucketCell(context, true, emit, emitContext, error)
}

private func bucketFloorGet(
    _ context: UnsafeMutableRawPointer?,
    _ emit: PotluckDbRuntimeEmitBytesV1?,
    _ emitContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    bucketCell(context, false, emit, emitContext, error)
}

private func bucketSwap(
    _ context: UnsafeMutableRawPointer?,
    _ head: Bool,
    _ expectedPresent: UInt32,
    _ expected: PotluckDbRuntimeSliceV1,
    _ replacement: PotluckDbRuntimeSliceV1,
    _ outSwapped: UnsafeMutablePointer<UInt32>?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    guard let outSwapped else {
        return bucketFail(
            bridge, Seam.contractViolation, "bucket cell-swap output is null", error
        )
    }
    guard expectedPresent <= 1 else {
        return bucketFail(
            bridge,
            Seam.contractViolation,
            "bucket expected-present flag is not Boolean",
            error
        )
    }
    guard expectedPresent != 0 || expected.length == 0 else {
        return bucketFail(
            bridge,
            Seam.contractViolation,
            "bucket absent expected cell contains bytes",
            error
        )
    }
    do {
        // A nil expected compares against absence; an empty array compares
        // against the empty value, and B2 tells the two apart.
        let previous: [UInt8]? = expectedPresent == 0 ? nil : bucketBytes(expected)
        let value = bucketBytes(replacement)
        let swapped = head
            ? try bridge.storage.headSwap(expected: previous, value: value)
            : try bridge.storage.floorSwap(expected: previous, value: value)
        outSwapped.pointee = swapped ? 1 : 0
        return Seam.ok
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketHeadSwap(
    _ context: UnsafeMutableRawPointer?,
    _ expectedPresent: UInt32,
    _ expected: PotluckDbRuntimeSliceV1,
    _ replacement: PotluckDbRuntimeSliceV1,
    _ outSwapped: UnsafeMutablePointer<UInt32>?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    bucketSwap(context, true, expectedPresent, expected, replacement, outSwapped, error)
}

private func bucketFloorSwap(
    _ context: UnsafeMutableRawPointer?,
    _ expectedPresent: UInt32,
    _ expected: PotluckDbRuntimeSliceV1,
    _ replacement: PotluckDbRuntimeSliceV1,
    _ outSwapped: UnsafeMutablePointer<UInt32>?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    bucketSwap(context, false, expectedPresent, expected, replacement, outSwapped, error)
}

private func bucketCellPairGet(
    _ context: UnsafeMutableRawPointer?,
    _ emitHead: PotluckDbRuntimeEmitBytesV1?,
    _ headContext: UnsafeMutableRawPointer?,
    _ emitFloor: PotluckDbRuntimeEmitBytesV1?,
    _ floorContext: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<PotluckDbRuntimeHostErrorV1>?
) -> Int32 {
    resetHostError(error)
    guard let bridge = bucketBridge(context) else { return Seam.contractViolation }
    guard let pair = bridge.pair else {
        return bucketFail(
            bridge,
            Seam.contractViolation,
            "bucket declared no cell-pair capability",
            error
        )
    }
    do {
        let observed = try pair.cellPairGet()
        // An absent cell is no emission at all, which is how the seam says
        // None; an empty array is a present cell holding no bytes.
        if let head = observed.head {
            let code = bucketEmit(emitHead, headContext, head)
            if code != Seam.ok { return code }
        }
        if let floor = observed.floor {
            let code = bucketEmit(emitFloor, floorContext, floor)
            if code != Seam.ok { return code }
        }
        return Seam.ok
    } catch let failure {
        return bucketFail(bridge, failure, error)
    }
}

private func bucketCounters(
    _ context: UnsafeMutableRawPointer?,
    _ outCounters: UnsafeMutablePointer<PotluckDbRuntimeBucketCounterSnapshotV1>?
) {
    guard let outCounters, let bridge = bucketBridge(context) else { return }
    let value = bridge.storage.counters()
    outCounters.pointee.struct_size = UInt32(
        MemoryLayout<PotluckDbRuntimeBucketCounterSnapshotV1>.size
    )
    outCounters.pointee.abi_version = Seam.abiVersion
    outCounters.pointee.gets = value.gets
    outCounters.pointee.puts = value.puts
    outCounters.pointee.idempotent_puts = value.idempotentPuts
    outCounters.pointee.exists = value.exists
    outCounters.pointee.lists = value.lists
    outCounters.pointee.deletes = value.deletes
    outCounters.pointee.cell_gets = value.cellGets
    outCounters.pointee.cell_swaps = value.cellSwaps
    outCounters.pointee.cell_swap_wins = value.cellSwapWins
    outCounters.pointee.transport_gets = value.transportGets
    outCounters.pointee.transport_puts = value.transportPuts
    outCounters.pointee.transport_heads = value.transportHeads
    outCounters.pointee.transport_lists = value.transportLists
    outCounters.pointee.transport_deletes = value.transportDeletes
    outCounters.pointee.transport_bytes_received = value.transportBytesReceived
    outCounters.pointee.transport_bytes_submitted = value.transportBytesSubmitted
}

extension Remote {
    /// A Remote over a Swift bucket, with no native table for the caller to
    /// build.
    ///
    /// The same canonical `Remote.from_storage` intent as the overload on
    /// the type, taking this language's own Seam-4 protocol rather than a
    /// pointer to a table nothing in this SDK fills in. The adapter table
    /// is released with the Remote's handle, after its exchange is gone.
    public static func fromStorage(
        _ storage: BucketStorage,
        options: RemoteOptions = .defaults
    ) throws -> Remote {
        let owner = BucketAdapterOwner(storage: storage)
        try options.validate()
        var rawOptions = rawRemoteOptions(options)
        var handle: PotluckDbRemoteHandleV1 = 0
        try applicationCall { error in
            potluckdb_remote_from_storage_v1(owner.table, &rawOptions, &handle, error)
        }
        return try Remote(
            state: HandleState(
                handle: handle,
                close: potluckdb_remote_close_v1,
                release: potluckdb_remote_release_v1,
                retained: owner
            )
        )
    }
}

// MARK: - Shared storage library

/// Which S3-compatible bucket, and how to reach it.
///
/// Built as a type rather than a pile of arguments so adding a field
/// later is not a change to every call site -- the shape this crosses
/// the ABI as is JSON for the same reason.
public struct S3Options: Sendable {
    public var bucket: String
    public var namespace: String
    public var region: String?
    public var endpoint: String?
    public var forcePathStyle: Bool
    public var accessKeyId: String?
    public var secretAccessKey: String?
    public var sessionToken: String?
    public var remote: RemoteOptions

    public init(
        bucket: String,
        namespace: String,
        region: String? = nil,
        endpoint: String? = nil,
        forcePathStyle: Bool = false,
        accessKeyId: String? = nil,
        secretAccessKey: String? = nil,
        sessionToken: String? = nil,
        remote: RemoteOptions = .defaults
    ) {
        self.bucket = bucket
        self.namespace = namespace
        self.region = Self.absent(region)
        self.endpoint = Self.absent(endpoint)
        self.forcePathStyle = forcePathStyle
        self.accessKeyId = Self.absent(accessKeyId)
        self.secretAccessKey = Self.absent(secretAccessKey)
        self.sessionToken = Self.absent(sessionToken)
        self.remote = remote
    }

    /// Null and empty are the same absence, as they are in the Go facade.
    static func absent(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// Which Google Cloud Storage bucket, and how to reach it.
///
/// Built as a type rather than a pile of arguments so adding a field
/// later is not a change to every call site -- the shape this crosses
/// the ABI as is JSON for the same reason.
public struct GcsOptions: Sendable {
    public var bucket: String
    public var namespace: String
    public var endpoint: String?
    /// The JSON key Google issues, as the text of it. `nil` uses
    /// Application Default Credentials.
    public var serviceAccount: String?
    public var remote: RemoteOptions

    public init(
        bucket: String,
        namespace: String,
        endpoint: String? = nil,
        serviceAccount: String? = nil,
        remote: RemoteOptions = .defaults
    ) {
        self.bucket = bucket
        self.namespace = namespace
        self.endpoint = S3Options.absent(endpoint)
        self.serviceAccount = S3Options.absent(serviceAccount)
        self.remote = remote
    }
}

/// Which Azure Blob Storage container, and how to reach it.
///
/// Built as a type rather than a pile of arguments so adding a field
/// later is not a change to every call site -- the shape this crosses
/// the ABI as is JSON for the same reason.
public struct AzureOptions: Sendable {
    public var account: String
    public var container: String
    public var namespace: String
    /// The endpoint, for a store that is not Azure's own. Reaches the
    /// native library as `endpoint_url`; Azurite is one account under one
    /// port, so its endpoint carries the account as a path segment.
    public var endpoint: String?
    /// An explicit account key. `nil` uses the Azure credential chain.
    public var accountKey: String?
    public var remote: RemoteOptions

    public init(
        account: String,
        container: String,
        namespace: String,
        endpoint: String? = nil,
        accountKey: String? = nil,
        remote: RemoteOptions = .defaults
    ) {
        self.account = account
        self.container = container
        self.namespace = namespace
        self.endpoint = S3Options.absent(endpoint)
        self.accountKey = S3Options.absent(accountKey)
        self.remote = remote
    }
}

private typealias StorageAbiVersionFn = @convention(c) () -> UInt32
private typealias StorageErrorSizeFn = @convention(c) () -> UInt32
private typealias StorageErrorReleaseFn = @convention(c) (
    UnsafeMutablePointer<PotluckDbStorageErrorV1>
) -> Int32
private typealias StorageCreateFn = @convention(c) (
    PotluckDbStorageSliceV1,
    UnsafeMutablePointer<UnsafePointer<PotluckDbRuntimeBucketAdapterV1>?>,
    UnsafeMutablePointer<PotluckDbStorageErrorV1>
) -> Int32
private typealias StorageReleaseFn = @convention(c) (
    UnsafePointer<PotluckDbRuntimeBucketAdapterV1>?
) -> Int32

/// Process-wide load of libpotluckdb_storage. Never unloaded: every
/// table it handed out points into its code.
private final class StorageLibraryState: @unchecked Sendable {
    let lock = NSLock()
    var loaded = false
    var loadError: PotluckDBError?
    var handle: UnsafeMutableRawPointer?
    var creates: [String: StorageCreateFn] = [:]
    var release: StorageReleaseFn?
    var errorRelease: StorageErrorReleaseFn?
}

private let storageLibrary = StorageLibraryState()
private let storageAbiVersion: UInt32 = 1
private let storageOk: Int32 = 0

/// Which function in the library builds which provider's adapter.
///
/// Closed on purpose, and consulted before a library is looked for: it
/// is this SDK's own knowledge of what the library it was built against
/// exports, so a provider that is not in it is answered from here rather
/// than by asking `dlsym` for a name nobody chose.
///
/// Internal rather than private: the conformance program compiles into
/// this module and holds it against the names the library exports.
let storageProviderEntryPoints: [String: String] = [
    "s3": "potluckdb_storage_s3_create_v1",
    "gcs": "potluckdb_storage_gcs_create_v1",
    "azure": "potluckdb_storage_azure_create_v1",
]

/// A provider this SDK has no entry point for.
///
/// Answered before the library is looked for: a caller who mistyped a
/// provider should read that back rather than a complaint about an
/// absent install.
func storageUnknownProvider(_ provider: String) -> PotluckDBError {
    PotluckDBError(
        code: "storage_library_unavailable",
        category: .permanent,
        message: "provider \"\(provider)\" is not one this SDK can load. "
            + "The storage library provides \"s3\", \"gcs\", and \"azure\".",
        action: "Correct the provider name and retry."
    )
}

/// A provider this SDK knows, absent from the library it loaded.
///
/// The ordinary cause is an older storage library on the machine than
/// the one this SDK was built against -- the provider was added after it
/// was built -- so the remedy is the library, not the call.
func storageMissingEntryPoint(_ provider: String, symbol: String) -> PotluckDBError {
    PotluckDBError(
        code: "storage_library_unavailable",
        category: .permanent,
        message: "the storage library does not export \"\(symbol)\". "
            + "It may predate provider \"\(provider)\"; "
            + "update the potluckdb storage library.",
        action: "Ship a libpotluckdb_storage matching this SDK's version."
    )
}

private func storageLoad() throws {
    storageLibrary.lock.lock()
    defer { storageLibrary.lock.unlock() }
    if storageLibrary.loaded { return }
    if let loadError = storageLibrary.loadError { throw loadError }
    do {
        try storageOpen()
        storageLibrary.loaded = true
    } catch let error as PotluckDBError {
        storageLibrary.loadError = error
        throw error
    }
}

private func storageDefaultName() -> String {
    #if os(Windows)
    return "potluckdb_storage.dll"
    #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    return "libpotluckdb_storage.dylib"
    #else
    return "libpotluckdb_storage.so"
    #endif
}

/// Where the storage library is for this process.
///
/// `POTLUCKDB_STORAGE_LIBRARY` first, because someone who named a library
/// meant that one. Then beside the running executable, where a program's
/// libraries sit, and in the `Frameworks` directory of the bundle the
/// executable is in, where an application's ship. Otherwise the
/// platform's own name, which lets the loader search wherever it
/// searches. A package build links the storage binary target and copies
/// its library beside the product, which is the first of those places.
private func storageLibraryPath() -> String {
    let configured = ProcessInfo.processInfo.environment["POTLUCKDB_STORAGE_LIBRARY"]
    if let configured, !configured.isEmpty {
        return configured
    }
    let name = storageDefaultName()
    var candidates: [String] = []
    if let executable = Bundle.main.executableURL {
        candidates.append(
            executable.deletingLastPathComponent().appendingPathComponent(name).path
        )
    }
    if let frameworks = Bundle.main.privateFrameworksURL {
        candidates.append(frameworks.appendingPathComponent(
            "PotluckDBStorage.framework/PotluckDBStorage"
        ).path)
        candidates.append(frameworks.appendingPathComponent(name).path)
    }
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
        return candidate
    }
    return name
}

private func storageOpen() throws {
    let path = storageLibraryPath()
    _ = dlerror()
    guard let handle = dlopen(path, RTLD_NOW) else {
        let reason = dlerror().map { String(cString: $0) } ?? "no reason was reported"
        throw PotluckDBError.storageUnavailable(reason)
    }
    func symbol<T>(_ name: String) throws -> T {
        _ = dlerror()
        guard let pointer = dlsym(handle, name) else {
            throw PotluckDBError.storageUnavailable(
                "the storage library does not export the v1 entry points"
            )
        }
        return unsafeBitCast(pointer, to: T.self)
    }
    // Only the four every provider shares. The per-provider create is
    // resolved by storageEntryPoint when a provider is asked for, so a
    // library built before one provider existed stays usable for the
    // others.
    let abiVersion: StorageAbiVersionFn = try symbol("potluckdb_storage_abi_version_v1")
    let errorSize: StorageErrorSizeFn = try symbol("potluckdb_storage_error_size_v1")
    storageLibrary.errorRelease = try symbol("potluckdb_storage_error_release_v1")
    storageLibrary.release = try symbol("potluckdb_storage_release_v1")
    storageLibrary.handle = handle
    if abiVersion() != storageAbiVersion {
        throw PotluckDBError.storageUnavailable(
            "the storage library speaks a different ABI"
        )
    }
    if errorSize() != UInt32(MemoryLayout<PotluckDbStorageErrorV1>.size) {
        throw PotluckDBError.storageUnavailable(
            "the storage library declares a different error structure"
        )
    }
}

/// One provider's create function, resolved the first time that
/// provider is asked for.
private func storageEntryPoint(
    _ provider: String, symbol: String
) throws -> StorageCreateFn {
    storageLibrary.lock.lock()
    defer { storageLibrary.lock.unlock() }
    if let known = storageLibrary.creates[symbol] { return known }
    guard let handle = storageLibrary.handle else {
        throw PotluckDBError.storageUnavailable(
            "the storage library does not export the v1 entry points"
        )
    }
    _ = dlerror()
    guard let address = dlsym(handle, symbol) else {
        throw storageMissingEntryPoint(provider, symbol: symbol)
    }
    let resolved = unsafeBitCast(address, to: StorageCreateFn.self)
    storageLibrary.creates[symbol] = resolved
    return resolved
}

private func storageCreate(_ provider: String, document: String) throws
    -> UnsafePointer<PotluckDbRuntimeBucketAdapterV1>
{
    guard let symbol = storageProviderEntryPoints[provider] else {
        throw storageUnknownProvider(provider)
    }
    try storageLoad()
    let create = try storageEntryPoint(provider, symbol: symbol)
    guard let errorRelease = storageLibrary.errorRelease else {
        throw PotluckDBError.storageUnavailable(
            "the storage library does not export the v1 entry points"
        )
    }
    let encoded = Array(document.utf8)
    return try encoded.withUnsafeBufferPointer { buffer in
        let slice = PotluckDbStorageSliceV1(
            data: buffer.baseAddress,
            length: UInt64(buffer.count)
        )
        var adapter: UnsafePointer<PotluckDbRuntimeBucketAdapterV1>?
        var reported = PotluckDbStorageErrorV1()
        reported.struct_size = UInt32(MemoryLayout<PotluckDbStorageErrorV1>.size)
        reported.abi_version = storageAbiVersion
        let code = create(slice, &adapter, &reported)
        if code == storageOk {
            guard let adapter else {
                throw PotluckDBError.storageUnavailable(
                    "the storage library refused the configuration"
                )
            }
            return adapter
        }
        var message = "the storage library refused the configuration"
        if let data = reported.message.data, reported.message.length > 0 {
            message = String(
                decoding: UnsafeBufferPointer(
                    start: data, count: Int(reported.message.length)
                ),
                as: UTF8.self
            )
        }
        _ = errorRelease(&reported)
        if code == 24 {
            throw PotluckDBError(code: "bucket_not_found", category: .permanent,
                message: message, action: "Create the bucket or container, or correct the name the remote was configured with.")
        }
        throw PotluckDBError.invalidArgument(
            message,
            action: "Correct the storage configuration and retry."
        )
    }
}

private func storageRelease(
    _ adapter: UnsafePointer<PotluckDbRuntimeBucketAdapterV1>
) {
    _ = storageLibrary.release?(adapter)
}

/// Remotes over object storage, from the shared native storage library.
///
/// `Remote.fromStorage` takes a bucket a caller implements. This takes
/// one nobody implements: the Seam-4 semantics, the HTTP and the AWS
/// credential chain all live in `potluckdb-storage`, one native library
/// that every SDK loads. A separate type rather than a `Remote`
/// constructor because Remote's member set is fixed by
/// `contracts/sdk-surface-v1.json`.
public enum Storage {
    /// A remote over an S3-compatible bucket, through the shared library.
    ///
    /// Credentials come from the AWS chain -- environment, shared
    /// configuration and credentials files, SSO, web identity, container
    /// and instance metadata -- unless `accessKeyId` and `secretAccessKey`
    /// name a pair. Pass keys for a store that is not AWS: Cloudflare R2
    /// issues a pair with an account `endpoint` and wants `region` "auto".
    /// MinIO and most self-hosted gateways want `forcePathStyle`, which
    /// addresses the bucket as a path segment rather than as a subdomain.
    public static func fromS3(_ options: S3Options) throws -> Remote {
        if options.bucket.isEmpty || options.namespace.isEmpty {
            throw PotluckDBError.invalidArgument(
                "an S3 remote needs a bucket and a namespace",
                action: "Name both: one bucket holds many databases, one per namespace."
            )
        }
        if (options.accessKeyId == nil) != (options.secretAccessKey == nil) {
            // Half a credential is not a credential and is not an absent
            // one either: taken as absent, the chain would answer with
            // somebody else's keys and the failure would name a permission.
            throw PotluckDBError.invalidArgument(
                "accessKeyId and secretAccessKey are given together or not at all",
                action: "Pass both to use explicit credentials, or neither for the AWS chain."
            )
        }
        return try fromProvider("s3", document: document(options), options: options.remote)
    }

    /// A remote over a Google Cloud Storage bucket, through the shared
    /// library.
    ///
    /// Credentials come from Application Default Credentials --
    /// `GOOGLE_APPLICATION_CREDENTIALS`, the gcloud user credentials
    /// file, then the metadata server -- unless `serviceAccount` names a
    /// key. Pass the JSON key Google issues for a process that has no
    /// such chain to consult.
    public static func fromGcs(_ options: GcsOptions) throws -> Remote {
        if options.bucket.isEmpty || options.namespace.isEmpty {
            throw PotluckDBError.invalidArgument(
                "a GCS remote needs a bucket and a namespace",
                action: "Name both: one bucket holds many databases, one per namespace."
            )
        }
        return try fromProvider(
            "gcs", document: document(options), options: options.remote
        )
    }

    /// A remote over an Azure Blob Storage container, through the shared
    /// library.
    ///
    /// Credentials come from the Azure chain -- environment, workload
    /// identity, managed identity, the Azure CLI and the developer tools
    /// -- unless `accountKey` names a key. Azurite issues the well-known
    /// `devstoreaccount1` pair and wants an `endpoint` that carries the
    /// account.
    public static func fromAzure(_ options: AzureOptions) throws -> Remote {
        if options.account.isEmpty || options.container.isEmpty
            || options.namespace.isEmpty
        {
            throw PotluckDBError.invalidArgument(
                "an Azure remote needs an account, a container and a namespace",
                action: "Name all three: one container holds many databases, "
                    + "one per namespace."
            )
        }
        return try fromProvider(
            "azure", document: document(options), options: options.remote
        )
    }

    /// A remote over whichever provider's adapter the library builds.
    ///
    /// The one place this facade crosses into the loader. Everything
    /// that is not the provider -- the entry point lookup, the adapter's
    /// ownership, the remote options -- is the same for all three, so it
    /// is written once here and each facade supplies only its own
    /// document.
    ///
    /// Internal rather than public: naming a provider and hand-building
    /// its document is not the surface callers get, `fromS3`, `fromGcs`
    /// and `fromAzure` are.
    static func fromProvider(
        _ provider: String, document: String, options: RemoteOptions
    ) throws -> Remote {
        let adapter = try storageCreate(provider, document: document)
        let storage = Integrator.StorageAdapter.borrowed(adapter.pointee)
        let remote: Remote
        do {
            remote = try Remote.fromStorage(storage, options: options)
        } catch {
            storageRelease(adapter)
            throw error
        }
        let held = adapter
        remote.state.afterClose = { storageRelease(held) }
        return remote
    }

    /// One JSON string, escaped.
    ///
    /// Hand-written because this SDK carries no JSON encoder for this
    /// document and the document it builds is four fields deep.
    public static func quoted(_ value: String) -> String {
        var output = "\""
        for character in value {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                let scalar = character.unicodeScalars.first!
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.append(character)
                }
            }
        }
        output += "\""
        return output
    }

    public static func document(_ options: S3Options) -> String {
        var body = "{\"provider\":\"s3\",\"bucket\":"
        body += quoted(options.bucket)
        body += ",\"namespace\":"
        body += quoted(options.namespace)
        body += ",\"force_path_style\":"
        body += options.forcePathStyle ? "true" : "false"
        if let region = options.region {
            body += ",\"region\":"
            body += quoted(region)
        }
        if let endpoint = options.endpoint {
            body += ",\"endpoint\":"
            body += quoted(endpoint)
        }
        body += ",\"credentials\":"
        if let key = options.accessKeyId, let secret = options.secretAccessKey {
            body += "{\"mode\":\"explicit\",\"access_key_id\":"
            body += quoted(key)
            body += ",\"secret_access_key\":"
            body += quoted(secret)
            if let token = options.sessionToken {
                body += ",\"session_token\":"
                body += quoted(token)
            }
            body += "}"
        } else {
            body += "{\"mode\":\"ambient\"}"
        }
        body += "}"
        return body
    }

    public static func document(_ options: GcsOptions) -> String {
        var body = "{\"provider\":\"gcs\",\"bucket\":"
        body += quoted(options.bucket)
        body += ",\"namespace\":"
        body += quoted(options.namespace)
        if let endpoint = options.endpoint {
            body += ",\"endpoint\":"
            body += quoted(endpoint)
        }
        body += ",\"credentials\":"
        if let serviceAccount = options.serviceAccount {
            // The key crosses as the text it already is. Parsing it here
            // to re-emit it would be this facade inventing a shape, and
            // the library reads either form.
            body += "{\"mode\":\"explicit\",\"service_account\":"
            body += quoted(serviceAccount)
            body += "}"
        } else {
            body += "{\"mode\":\"ambient\"}"
        }
        body += "}"
        return body
    }

    public static func document(_ options: AzureOptions) -> String {
        var body = "{\"provider\":\"azure\",\"account\":"
        body += quoted(options.account)
        body += ",\"container\":"
        body += quoted(options.container)
        body += ",\"namespace\":"
        body += quoted(options.namespace)
        if let endpoint = options.endpoint {
            // endpoint_url, not endpoint: the rename happens here so that
            // one spelling reaches callers across all three providers.
            body += ",\"endpoint_url\":"
            body += quoted(endpoint)
        }
        body += ",\"credentials\":"
        if let accountKey = options.accountKey {
            body += "{\"mode\":\"explicit\",\"account_key\":"
            body += quoted(accountKey)
            body += "}"
        } else {
            body += "{\"mode\":\"ambient\"}"
        }
        body += "}"
        return body
    }
}
