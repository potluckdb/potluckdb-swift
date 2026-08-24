// Objective-C facade over the potluckdb Native Application ABI: the
// canonical 22-intent API with validated policies, NSError-based structured
// errors, and ARC-guarded owner lifecycle.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const PLKErrorDomain;
FOUNDATION_EXPORT NSErrorUserInfoKey const PLKErrorCodeKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const PLKErrorActionKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const PLKErrorRetryAfterMillisecondsKey;

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

/// Bounds retained revisions during collection.
@interface PLKRetentionPolicy : NSObject

+ (nullable instancetype)boundedWithKeepLast:(uint64_t)keepLast
                                   collectAt:(uint64_t)collectAt
                                       error:(NSError **)error;
+ (instancetype)boundedPolicy;

@end

/// Tunes one connection.
@interface PLKConnectionOptions : NSObject

@property(nonatomic) uint64_t timeoutMilliseconds;
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
@property(nonatomic, strong) PLKConnectionOptions *connection;

@end

/// Tunes one Remote.
@interface PLKRemoteOptions : NSObject

@property(nonatomic) uint32_t readConcurrency;
@property(nonatomic) uint32_t writeConcurrency;
@property(nonatomic, strong, nullable) PLKRetentionPolicy *retention;

@end

/// SQL parameter bindings. Values must be NSNull, NSNumber, NSString, or
/// NSData.
@interface PLKBindings : NSObject

+ (instancetype)positional:(NSArray *)values;
+ (instancetype)named:(NSDictionary<NSString *, id> *)values;
+ (instancetype)none;

@end

/// Reports one write statement's effect.
@interface PLKExecuteResult : NSObject

@property(nonatomic, readonly) int64_t rowsAffected;
@property(nonatomic, readonly, nullable) NSNumber *lastInsertID;

@end

typedef NS_ENUM(NSInteger, PLKSyncOutcome) {
    PLKSyncOutcomeUpToDate = 1,
    PLKSyncOutcomePushed = 2,
    PLKSyncOutcomePulled = 3,
    PLKSyncOutcomeConflict = 4,
};

/// One synchronization cycle's outcome.
@interface PLKSyncResult : NSObject

@property(nonatomic, readonly) PLKSyncOutcome outcome;
@property(nonatomic, readonly, nullable) PLKRevision *revision;
@property(nonatomic, readonly, nullable) NSArray<NSString *> *replayed;
@property(nonatomic, readonly, nullable) NSArray<NSString *> *quarantined;
@property(nonatomic, readonly, nullable) NSString *conflictReason;

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
+ (nullable instancetype)remoteFromStorage:(PLKStorageAdapter *)storage
                                   options:(nullable PLKRemoteOptions *)options
                                     error:(NSError **)error;

- (nullable PLKRemoteStatus *)statusWithError:(NSError **)error;
- (nullable PLKCollectionReport *)collect:(nullable PLKRetentionPolicy *)retention
                                    error:(NSError **)error;
- (nullable PLKCollectionReport *)recoverAbandonedCollectionWithError:
    (NSError **)error;
- (BOOL)closeWithError:(NSError **)error;

@end

/// Owns one explicit transaction inside its block.
@interface PLKTransaction : NSObject

- (nullable NSArray<NSArray *> *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;
- (nullable PLKExecuteResult *)execute:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
                                 error:(NSError **)error;

@end

/// One explicit connection to a Database.
@interface PLKConnection : NSObject

- (nullable NSArray<NSArray *> *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
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

- (nullable NSArray<NSArray *> *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
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

- (nullable NSArray<NSArray *> *)query:(NSString *)sql
                              bindings:(nullable PLKBindings *)bindings
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

NS_ASSUME_NONNULL_END
