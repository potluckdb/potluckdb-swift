// Objective-C facade over the potluckdb Native Application ABI: the
// canonical 22-intent API with validated policies, NSError-based structured
// errors, and ARC-guarded owner lifecycle.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class PLKSyncResult;

FOUNDATION_EXPORT NSErrorDomain const PLKErrorDomain;
FOUNDATION_EXPORT NSErrorUserInfoKey const PLKErrorCodeKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const PLKErrorActionKey;

typedef NS_ENUM(NSInteger, PLKErrorCategory) {
    PLKErrorCategoryCaller = 1,
    PLKErrorCategoryTemporary = 2,
    PLKErrorCategoryPermanent = 3,
    PLKErrorCategoryInternal = 4,
};

typedef NS_ENUM(NSInteger, PLKTransactionMode) {
    PLKTransactionModeDeferred = 1,
    PLKTransactionModeImmediate = 2,
    PLKTransactionModeExclusive = 3,
};

/// Which engine answers a read.
///
/// `contracts/sdk-surface-v1.json` fixes this language's spelling, down
/// to the capitals in `PLKQueryEngineDuckDB`, so ten SDKs agree on how a
/// caller writes it.
typedef NS_ENUM(NSInteger, PLKQueryEngine) {
    PLKQueryEngineSqlite = 1,
    PLKQueryEngineDuckDB = 2,
};

/// Identifies one published database state.
@interface PLKRevision : NSObject

+ (nullable instancetype)revisionWithData:(NSData *)data
                                    error:(NSError **)error;
+ (nullable instancetype)parse:(NSString *)text error:(NSError **)error;

@property(nonatomic, readonly) NSData *data;

- (nullable NSString *)formattedWithError:(NSError **)error;

@end

/// Tunes the shared automatic synchronization driver.
@interface PLKAutomaticSyncOptions : NSObject

@property(nonatomic) uint64_t outboundDebounceMilliseconds;
@property(nonatomic) uint64_t activePullIntervalMilliseconds;
@property(nonatomic) uint64_t idlePullIntervalMilliseconds;
@property(nonatomic) uint64_t retryInitialMilliseconds;
@property(nonatomic) uint64_t retryMaximumMilliseconds;

@end

/// Selects automatic or manual synchronization.
@interface PLKSyncPolicy : NSObject

+ (instancetype)automaticPolicy;
+ (nullable instancetype)automaticPolicyWithOptions:
                             (PLKAutomaticSyncOptions *)options
                                              error:(NSError **)error;
+ (instancetype)manualPolicy;

@end

/// Tunes read-ahead for connections.
@interface PLKPrefetchPolicy : NSObject

+ (instancetype)automaticPolicy;
+ (nullable instancetype)automaticPolicyWithBackgroundTargetBytes:
                             (uint64_t)backgroundTargetBytes
                                                memoryBudgetBytes:
                                                    (uint64_t)memoryBudgetBytes
                                                            error:
                                                                (NSError **)error;
+ (instancetype)disabledPolicy;

@end

/// Tunes WAL checkpointing for connections.
@interface PLKCheckpointPolicy : NSObject

+ (instancetype)automaticPolicy;
+ (nullable instancetype)automaticPolicyWithSoftLimitBytes:
                             (uint64_t)softLimitBytes
                                          forcedLimitBytes:
                                              (uint64_t)forcedLimitBytes
                                                     error:(NSError **)error;
+ (instancetype)disabledPolicy;

@end

/// Selects bounded or unbounded revision retention.
@interface PLKRetentionPolicy : NSObject

+ (nullable instancetype)boundedWithKeepLast:(uint64_t)keepLast
                                   collectAt:(uint64_t)collectAt
                                       error:(NSError **)error;
+ (instancetype)boundedPolicy;
/// Keeps every revision until collect runs with a bounded policy.
+ (instancetype)unboundedPolicy;
@property(nonatomic, readonly) BOOL bounded;

@end

/// Tunes one connection.
@interface PLKConnectionOptions : NSObject

@property(nonatomic) uint64_t timeoutMilliseconds;
/// Maximum rows per query; defaults to 1000000.
@property(nonatomic) uint64_t maximumRows;
@property(nonatomic, strong) PLKPrefetchPolicy *prefetch;
@property(nonatomic, strong) PLKCheckpointPolicy *checkpoint;

@end

/// Tunes one Database or Snapshot session.
@interface PLKOpenOptions : NSObject

@property(nonatomic) uint64_t localBudgetBytes;
@property(nonatomic) uint64_t minimumLocalBudgetBytes;
@property(nonatomic) uint64_t localCompactionBytes;
@property(nonatomic, strong, nullable) NSData *encryptionKey;
@property(nonatomic, strong) PLKSyncPolicy *syncPolicy;
@property(nonatomic, copy, nullable) NSString *clientID;
/// Supplies the license key described in contracts/licensing.md#requirements.
@property(nonatomic, copy, nullable) NSString *licenseKey;
@property(nonatomic, copy, nullable) NSString *analyticalEngine;
@property(nonatomic, strong) PLKConnectionOptions *connection;
/// Receives the outcome of every automatic synchronization attempt of
/// a database: a `PLKSyncResult` whose `outcome` is `UpToDate`,
/// `Pushed`, `Pulled`, `Conflict` or `Failed` with the `error`. The hook
/// is invoked on the synchronization thread. Do not call the database
/// from inside it; transfer the outcome to the program's own thread.
/// `closeWithError:` returns after the last invocation. A snapshot never
/// synchronizes, so `openRevisionAtPath:revision:remote:options:error:`
/// ignores it. An exception the block raises is not caught and
/// terminates the program.
@property(nonatomic, copy, nullable) void (^onSync)(PLKSyncResult *outcome);

@end

/// Tunes one Remote.
@interface PLKRemoteOptions : NSObject

@property(nonatomic) uint32_t readConcurrency;
@property(nonatomic) uint32_t writeConcurrency;
/// Bounded by default: keep the newest ten revisions, collect once twenty exist.
/// Setting nil restores the default.
@property(nonatomic, strong, null_resettable) PLKRetentionPolicy *retention;

@end

/// SQL parameter bindings. Values must be NSNull, NSNumber, NSString, or
/// NSData. An NSNumber binds by its objCType, so an NSDecimalNumber binds as
/// REAL through doubleValue; bind an integer NSNumber for an exact integer.
@interface PLKBindings : NSObject

+ (instancetype)positional:(NSArray *)values;
+ (instancetype)named:(NSDictionary<NSString *, id> *)values;
+ (instancetype)none;

@end

/// Reports one write statement's effect.
/// One result row, readable by position or by column name. A name that
/// appears twice answers its last position.
@interface PLKRow : NSObject <NSFastEnumeration>
/// The column names in select-list order.
@property(nonatomic, readonly) NSArray<NSString *> *columns;
/// The cells in select-list order; SQL NULL is `NSNull`.
@property(nonatomic, readonly) NSArray *values;
/// The number of cells.
@property(nonatomic, readonly) NSUInteger count;
/// The cell at a select-list position, for `row[0]`.
- (id)objectAtIndexedSubscript:(NSUInteger)index;
/// The cell under a column name, for `row[@"body"]`; nil when the select
/// list has no such column.
- (nullable id)objectForKeyedSubscript:(NSString *)column;
@end

/// A query result: the column names of the select list in order, then the
/// rows.
@interface PLKRows : NSObject <NSFastEnumeration>
/// The column names in select-list order; a name that appears twice is
/// listed twice.
@property(nonatomic, readonly) NSArray<NSString *> *columns;
/// The rows in result order.
@property(nonatomic, readonly) NSArray<PLKRow *> *rows;
/// The number of rows.
@property(nonatomic, readonly) NSUInteger count;
/// The row at a position, for `rows[0]`.
- (PLKRow *)objectAtIndexedSubscript:(NSUInteger)index;
@end

@interface PLKExecuteResult : NSObject

@property(nonatomic, readonly) int64_t rowsAffected;
@property(nonatomic, readonly, nullable) NSNumber *lastInsertID;

@end

typedef NS_ENUM(NSInteger, PLKSyncOutcome) {
    PLKSyncOutcomeUpToDate = 1,
    PLKSyncOutcomePushed = 2,
    PLKSyncOutcomePulled = 3,
    PLKSyncOutcomeConflict = 4,
    /// An automatic attempt that failed, carrying the error
    /// `syncWithError:` would have reported. Only `PLKOpenOptions.onSync`
    /// delivers it: `syncWithError:` reports the error itself.
    PLKSyncOutcomeFailed = 5,
};

/// One synchronization cycle's outcome.
@interface PLKSyncResult : NSObject

@property(nonatomic, readonly) PLKSyncOutcome outcome;
@property(nonatomic, readonly, nullable) PLKRevision *revision;
@property(nonatomic, readonly, nullable) NSArray<NSString *> *replayed;
@property(nonatomic, readonly, nullable) NSArray<NSString *> *quarantined;
@property(nonatomic, readonly, nullable) NSString *conflictReason;
/// The error of a `PLKSyncOutcomeFailed` outcome; nil for every other.
@property(nonatomic, readonly, nullable) NSError *error;

@end

/// Reports the outcome of resolving a conflict.
@interface PLKConflictResolution : NSObject

@property(nonatomic, readonly) PLKRevision *revision;
@property(nonatomic, readonly) NSArray<NSString *> *alreadyPublished;
@property(nonatomic, readonly) NSArray<NSString *> *replayed;
@property(nonatomic, readonly) NSArray<NSString *> *quarantined;
@property(nonatomic, readonly) NSArray<NSString *> *pending;

@end

/// Summarizes one retention collection pass.
@interface PLKCollectionReport : NSObject

@property(nonatomic, readonly, nullable) PLKRevision *floorBefore;
@property(nonatomic, readonly, nullable) PLKRevision *floorAfter;
@property(nonatomic, readonly) uint64_t epoch;
@property(nonatomic, readonly) uint64_t marked;
@property(nonatomic, readonly) uint64_t swept;
@property(nonatomic, readonly) BOOL aborted;

@end

/// The Database observational status.
@interface PLKDatabaseStatus : NSObject

@property(nonatomic, readonly, nullable) PLKRevision *revision;
@property(nonatomic, readonly) uint64_t pendingWrites;
@property(nonatomic, readonly) uint64_t localBytes;
@property(nonatomic, readonly) uint64_t localBudgetBytes;
@property(nonatomic, readonly) uint64_t connectionCount;
@property(nonatomic, readonly) NSString *syncState;
@property(nonatomic, readonly, nullable) NSNumber *nextSyncInMilliseconds;
@property(nonatomic, readonly, nullable) PLKRevision *conflictRemoteRevision;
@property(nonatomic, readonly) BOOL closed;

@end

/// One connection's checkpoint view.
@interface PLKCheckpointStatus : NSObject

@property(nonatomic, readonly) uint64_t softLimitBytes;
@property(nonatomic, readonly) uint64_t forcedLimitBytes;
@property(nonatomic, readonly) uint64_t walBytes;
@property(nonatomic, readonly) BOOL due;
@property(nonatomic, readonly) BOOL scheduled;
@property(nonatomic, readonly) uint64_t completed;
@property(nonatomic, readonly) uint64_t failures;

@end

/// One connection's prefetch view.
@interface PLKPrefetchStatus : NSObject

@property(nonatomic, readonly) NSString *backgroundState;
@property(nonatomic, readonly) uint64_t limit;
@property(nonatomic, readonly) uint64_t active;
@property(nonatomic, readonly) uint64_t queued;
@property(nonatomic, readonly) uint64_t readyPages;
@property(nonatomic, readonly) uint64_t readyBytes;
@property(nonatomic, readonly) uint64_t policyFailures;

@end

/// The Connection observational status.
@interface PLKConnectionStatus : NSObject

@property(nonatomic, readonly) BOOL transactionActive;
@property(nonatomic, readonly, nullable) PLKCheckpointStatus *checkpoint;
@property(nonatomic, readonly, nullable) PLKPrefetchStatus *prefetch;
@property(nonatomic, readonly) BOOL closed;

@end

/// The Snapshot observational status.
@interface PLKSnapshotStatus : NSObject

@property(nonatomic, readonly) PLKRevision *revision;
@property(nonatomic, readonly) uint64_t localBytes;
@property(nonatomic, readonly) BOOL closed;

@end

/// The Remote observational status.
@interface PLKRemoteStatus : NSObject

@property(nonatomic, readonly, nullable) NSNumber *retainedRevisions;
@property(nonatomic, readonly) BOOL maintenancePending;
@property(nonatomic, readonly) uint64_t policyFailures;
@property(nonatomic, readonly) BOOL closed;

@end

/// Reports one manual checkpoint.
@interface PLKCheckpointResult : NSObject

@property(nonatomic, readonly) int32_t logFrames;
@property(nonatomic, readonly) int32_t checkpointedFrames;

@end

/// Reports one re-encryption between remotes.
@interface PLKKeyRotationReport : NSObject

@property(nonatomic, readonly) PLKRevision *sourceRevision;
@property(nonatomic, readonly) PLKRevision *targetRevision;
@property(nonatomic, readonly, nullable) PLKRevision *sourceKeyID;
@property(nonatomic, readonly) PLKRevision *targetKeyID;
@property(nonatomic, readonly) uint64_t pieceCount;
@property(nonatomic, readonly) BOOL published;

@end

/// Low-level escape hatch: wraps a caller-owned native
/// PotluckDbRuntimeBucketAdapterV1 whose callbacks and context must stay
/// valid until the borrowing Remote is closed.
@interface PLKStorageAdapter : NSObject

+ (nullable instancetype)adapterRetainingPointer:(void *)adapterPointer
                                           owner:(nullable id)owner
                                           error:(NSError **)error;
+ (nullable instancetype)borrowedAdapterWithPointer:(void *)adapterPointer
                                              error:(NSError **)error;

@end

@class PLKTransaction;

/// One storage location holding published database states.
@interface PLKRemote : NSObject

+ (nullable instancetype)remoteFromDirectory:(NSString *)path
                                     options:(nullable PLKRemoteOptions *)options
                                       error:(NSError **)error;
/// A Remote over a caller-built native bucket adapter table.
///
/// Objective-C takes only this native adapter pointer here: it declares
/// no `BucketStorage` interface yet, so unlike its siblings it cannot
/// build the table over an application-written bucket. The interface
/// A22 describes is owed, and this exemption lapses when it is declared.
+ (nullable instancetype)remoteFromStorage:(PLKStorageAdapter *)storage
                                   options:(nullable PLKRemoteOptions *)options
                                     error:(NSError **)error;

- (nullable PLKRemoteStatus *)statusWithError:(NSError **)error;
/// The policy is required: nil and an unbounded policy are refused.
- (nullable PLKCollectionReport *)collect:(nonnull PLKRetentionPolicy *)retention
                                    error:(NSError **)error;
- (nullable PLKCollectionReport *)recoverAbandonedCollectionWithError:
    (NSError **)error;
- (BOOL)closeWithError:(NSError **)error;

@end

/// Owns one explicit transaction inside its block.
@interface PLKTransaction : NSObject

/// One read on the default engine, which is `PLKQueryEngineSqlite`.
///
/// Objective-C has no default arguments, so the engine is a fourth
/// segment rather than an optional one, and this three-segment selector
/// stays exactly what it was: every caller written before the parameter
/// existed keeps compiling and keeps reading the same rows.
- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
/// One read, on the engine asked for.
///
- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                engine:(PLKQueryEngine)engine
                                 error:(NSError **)error;
- (nullable PLKExecuteResult *)execute:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;

@end

/// One explicit connection to a Database.
@interface PLKConnection : NSObject

- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
/// One read, on the engine asked for. See `PLKTransaction`.
- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                engine:(PLKQueryEngine)engine
                                 error:(NSError **)error;
- (nullable PLKExecuteResult *)execute:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
- (BOOL)transactionWithMode:(PLKTransactionMode)mode
                      error:(NSError **)error
                      block:(BOOL (^)(PLKTransaction *transaction,
                                      NSError **blockError))block;
- (nullable PLKCheckpointResult *)checkpointWithError:(NSError **)error;
- (nullable PLKConnectionStatus *)statusWithError:(NSError **)error;
- (BOOL)closeWithError:(NSError **)error;

@end

/// One pinned read-only revision session.
@interface PLKSnapshot : NSObject

- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
/// One read, on the engine asked for. See `PLKTransaction`.
- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                engine:(PLKQueryEngine)engine
                                 error:(NSError **)error;
- (nullable PLKSnapshotStatus *)statusWithError:(NSError **)error;
- (BOOL)closeWithError:(NSError **)error;

@end

/// One writable session.
@interface PLKDatabase : NSObject

+ (nullable instancetype)openAtPath:(NSString *)path
                             remote:(nullable PLKRemote *)remote
                            options:(nullable PLKOpenOptions *)options
                              error:(NSError **)error;
+ (nullable PLKSnapshot *)openRevisionAtPath:(NSString *)path
                                    revision:(PLKRevision *)revision
                                      remote:(PLKRemote *)remote
                                     options:(nullable PLKOpenOptions *)options
                                       error:(NSError **)error;

- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
/// One read, on the engine asked for. See `PLKTransaction`.
- (nullable PLKRows *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                engine:(PLKQueryEngine)engine
                                 error:(NSError **)error;
- (nullable PLKExecuteResult *)execute:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
- (BOOL)transactionWithMode:(PLKTransactionMode)mode
                      error:(NSError **)error
                      block:(BOOL (^)(PLKTransaction *transaction,
                                      NSError **blockError))block;
- (nullable PLKConnection *)connect:(nullable PLKConnectionOptions *)options
                              error:(NSError **)error;
- (nullable PLKSyncResult *)syncWithError:(NSError **)error;
- (nullable PLKConflictResolution *)resolveConflictWithError:(NSError **)error;
- (nullable PLKDatabaseStatus *)setSyncPolicy:(PLKSyncPolicy *)policy
                                        error:(NSError **)error;
- (nullable NSNumber *)clearQuarantineRecordsWithError:(NSError **)error;
- (nullable PLKDatabaseStatus *)statusWithError:(NSError **)error;
- (BOOL)closeWithError:(NSError **)error;

@end

/// Administrative re-encryption between two distinct remotes.
@interface PLKAdmin : NSObject

+ (nullable PLKKeyRotationReport *)reencryptFromRemote:(PLKRemote *)source
                                              toRemote:(PLKRemote *)target
                                                newKey:(NSData *)newKey
                                             sourceKey:(nullable NSData *)sourceKey
                                              revision:
                                                  (nullable PLKRevision *)revision
                                                 error:(NSError **)error;

@end

/// Remotes over object storage, from the shared native storage library.
///
/// `PLKRemote remoteFromStorage:` takes a native adapter table the caller
/// builds. These build none: the semantics, the HTTP and every provider's
/// credential chain live in `potluckdb-storage`, one native library that
/// every SDK loads, and all this class does is find it, hand it a JSON
/// configuration, and give the function table it answers with to
/// `remoteFromStorage:`.
///
/// Its own class rather than three more `PLKRemote` constructors:
/// `Remote`'s member set is fixed for the SDKs that speak the runtime
/// interface, and this one keeps the same shape beside it. Each of these
/// returns an ordinary `PLKRemote`.
@interface PLKStorage : NSObject

/// A remote over an S3-compatible bucket.
///
/// `bucket` holds the objects; the namespace is the prefix this database
/// lives under, so one bucket can hold many. Credentials come from the
/// AWS chain unless `accessKeyID` and `secretAccessKey` are both given.
///
/// `endpoint` addresses a store that is not AWS's own: Cloudflare R2
/// issues a pair with an account endpoint and wants `region` "auto", and
/// MinIO and most self-hosted gateways want `forcePathStyle`, which
/// addresses the bucket as a path segment rather than as a subdomain.
+ (nullable PLKRemote *)remoteFromS3Bucket:(NSString *)bucket
                               inNamespace:(NSString *)databaseNamespace
                                    region:(nullable NSString *)region
                                  endpoint:(nullable NSString *)endpoint
                            forcePathStyle:(BOOL)forcePathStyle
                               accessKeyID:(nullable NSString *)accessKeyID
                           secretAccessKey:
                               (nullable NSString *)secretAccessKey
                              sessionToken:(nullable NSString *)sessionToken
                                   options:(nullable PLKRemoteOptions *)options
                                     error:(NSError **)error;

/// A remote over a Google Cloud Storage bucket.
///
/// Credentials come from Application Default Credentials unless
/// `serviceAccount` is given, which is the JSON key Google issues as its
/// own text.
+ (nullable PLKRemote *)remoteFromGCSBucket:(NSString *)bucket
                                inNamespace:(NSString *)databaseNamespace
                                   endpoint:(nullable NSString *)endpoint
                             serviceAccount:
                                 (nullable NSString *)serviceAccount
                                    options:(nullable PLKRemoteOptions *)options
                                      error:(NSError **)error;

/// A remote over an Azure Blob Storage container.
///
/// Credentials come from the Azure chain unless `accountKey` is given.
/// `endpoint` addresses a store that is not Azure's own; Azurite is one
/// account under one port, so its endpoint carries the account as a path
/// segment.
+ (nullable PLKRemote *)remoteFromAzureAccount:(NSString *)account
                                     container:(NSString *)container
                                   inNamespace:
                                       (NSString *)databaseNamespace
                                      endpoint:(nullable NSString *)endpoint
                                    accountKey:(nullable NSString *)accountKey
                                       options:
                                           (nullable PLKRemoteOptions *)options
                                         error:(NSError **)error;

/// Where the storage library is for this process.
///
/// `POTLUCKDB_STORAGE_LIBRARY` if it is set, otherwise the platform's own
/// library name, which lets the loader search wherever it searches.
+ (NSString *)libraryPath;

@end

NS_ASSUME_NONNULL_END
