// Implementation of the Objective-C facade. Every method performs exactly
// one canonical Application ABI call sequence; input buffers are borrowed
// for one call only and owner handles are released by ARC deallocation.

#import "PotluckDBObjC.h"

#include "potluckdb.h"

// The storage doors at the end of this file find their library while the
// program is running rather than at link time, which is the one thing
// neither C nor Foundation offers. Nothing above them needs any of this,
// and a program that never opens a remote over object storage never
// calls into it.
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern uint32_t potluckdb_internal_storage_callback_active_v1(void);

NSErrorDomain const PLKErrorDomain = @"dev.potluckdb.PotluckDB";
NSErrorUserInfoKey const PLKErrorCodeKey = @"PLKErrorCode";
NSErrorUserInfoKey const PLKErrorActionKey = @"PLKErrorAction";

static NSString *PLKBufferString(PotluckDbBufferV1 buffer) {
    if (buffer.data == NULL || buffer.length == 0) {
        return @"";
    }
    NSString *decoded =
        [[NSString alloc] initWithBytes:buffer.data
                                 length:(NSUInteger)buffer.length
                               encoding:NSUTF8StringEncoding];
    return decoded != nil ? decoded : @"";
}

// Decodes an SQL value or column name. Foundation's UTF-8 decoding drops a
// leading U+FEFF as an encoding signature, but in SQL text it is part of the
// value, so leading ones are decoded here and the rest by Foundation (review
// round 25 CM-04). Returns nil for bytes that are not UTF-8.
static NSString *PLKSQLText(const uint8_t *bytes, NSUInteger length) {
    if (bytes == NULL || length == 0) {
        return @"";
    }
    NSUInteger start = 0;
    while (start + 3 <= length && bytes[start] == 0xEF &&
           bytes[start + 1] == 0xBB && bytes[start + 2] == 0xBF) {
        start += 3;
    }
    NSString *rest = [[NSString alloc] initWithBytes:bytes + start
                                              length:length - start
                                            encoding:NSUTF8StringEncoding];
    if (rest == nil || start == 0) {
        return rest;
    }
    NSMutableString *text =
        [NSMutableString stringWithCapacity:start / 3 + rest.length];
    for (NSUInteger index = 0; index < start / 3; index += 1) {
        [text appendFormat:@"%C", (unichar)0xFEFF];
    }
    [text appendString:rest];
    return [text copy];
}

static NSError *PLKMakeError(NSString *code,
                             PLKErrorCategory category,
                             NSString *message,
                             NSString *action) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[PLKErrorCodeKey] = code;
    info[NSLocalizedDescriptionKey] = message;
    info[PLKErrorActionKey] = action;
    return [NSError errorWithDomain:PLKErrorDomain code:category userInfo:info];
}

static NSError *PLKInvalidArgument(NSString *message, NSString *action) {
    return PLKMakeError(@"invalid_argument", PLKErrorCategoryCaller, message,
                        action);
}

static NSError *PLKInternalFailure(NSString *message) {
    return PLKMakeError(@"internal_failure", PLKErrorCategoryInternal, message,
                        @"Preserve the failure details and report this error.");
}

static NSError *_Nullable PLKEngineSelector(PLKQueryEngine engine, uint32_t *selector) {
    switch (engine) {
        case PLKQueryEngineSqlite:
            *selector = POTLUCKDB_QUERY_SQLITE_V1;
            return nil;
        case PLKQueryEngineDuckDB:
            *selector = POTLUCKDB_QUERY_DUCKDB_V1;
            return nil;
        default:
            return PLKInvalidArgument(
                [NSString stringWithFormat:@"unknown query engine %ld", (long)engine],
                @"Use 'sqlite' or 'duckdb'.");
    }
}

static BOOL PLKFail(NSError **error, NSError *failure) {
    if (error != NULL) {
        *error = failure;
    }
    return NO;
}

/// The NSError an ABI error describes. Its buffers stay with their owner.
static NSError *PLKErrorFromRaw(const PotluckDbErrorV1 *raw) {
    PLKErrorCategory category = (PLKErrorCategory)raw->category;
    if (category < PLKErrorCategoryCaller ||
        category > PLKErrorCategoryInternal) {
        category = PLKErrorCategoryInternal;
    }
    NSString *code = PLKBufferString(raw->code);
    NSString *action = [code isEqualToString:@"analytical_engine_unavailable"]
        ? @"Download the platform DuckDB library from https://docs.potluckdb.com/install/objc/#analytics and set PLKOpenOptions.analyticalEngine to its path."
        : PLKBufferString(raw->action);
    return PLKMakeError(code, category, PLKBufferString(raw->message), action);
}

static BOOL PLKCheck(int32_t result,
                     PotluckDbErrorV1 *raw,
                     NSError **error) {
    if (result == 0) {
        (void)potluckdb_error_release_v1(raw);
        return YES;
    }
    NSError *failure = PLKErrorFromRaw(raw);
    (void)potluckdb_error_release_v1(raw);
    return PLKFail(error, failure);
}

static PotluckDbSliceV1 PLKSliceFromData(NSData *_Nullable data) {
    PotluckDbSliceV1 slice = {0};
    if (data != nil && data.length > 0) {
        slice.data = data.bytes;
        slice.length = data.length;
    }
    return slice;
}

static NSData *_Nullable PLKUtf8(NSString *value) {
    return [value dataUsingEncoding:NSUTF8StringEncoding];
}

static NSError *PLKUnencodableText(void) {
    return PLKInvalidArgument(
        @"text contains an unpaired surrogate",
        @"Remove unpaired surrogates and retry.");
}

typedef NS_ENUM(NSInteger, PLKOwnerKind) {
    PLKOwnerKindRemote = 1,
    PLKOwnerKindDatabase = 2,
    PLKOwnerKindConnection = 3,
    PLKOwnerKindSnapshot = 4,
    PLKOwnerKindTransaction = 5,
};

@interface PLKHandleState : NSObject {
  @public
    NSLock *_lock;
    uint64_t _handle;
    PLKOwnerKind _kind;
    BOOL _closable;
    BOOL _closed;
    id _Nullable _retained;
}

- (instancetype)initWithKind:(PLKOwnerKind)kind
                      handle:(uint64_t)handle
                    closable:(BOOL)closable
                    retained:(id _Nullable)retained;

- (BOOL)withHandle:(BOOL (^)(uint64_t handle, NSError **error))body
             error:(NSError **)error;
- (BOOL)withPair:(PLKHandleState *)other
            body:(BOOL (^)(uint64_t left, uint64_t right, NSError **error))body
           error:(NSError **)error;

@end

@implementation PLKHandleState

- (instancetype)initWithKind:(PLKOwnerKind)kind
                      handle:(uint64_t)handle
                    closable:(BOOL)closable
                    retained:(id)retained {
    self = [super init];
    if (self != nil) {
        _lock = [[NSLock alloc] init];
        _kind = kind;
        _handle = handle;
        _closable = closable;
        _retained = retained;
    }
    return self;
}

- (void)orphanBorrowers {
    if (_retained != nil) {
        // A refused destructor leaves native registrations borrowing this owner.
        (void)CFBridgingRetain(_retained);
    }
}

- (BOOL)cleanup {
    if (potluckdb_internal_storage_callback_active_v1() != 0) { return NO; }
    if (_handle == 0) {
        return YES;
    }
    BOOL needsClose = _closable && !_closed;
    switch (_kind) {
        case PLKOwnerKindRemote:
            if (needsClose) {
                if (potluckdb_remote_close_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                    return NO;
                }
            }
            if (potluckdb_remote_release_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                return NO;
            }
            break;
        case PLKOwnerKindDatabase:
            if (needsClose) {
                if (potluckdb_database_close_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                    return NO;
                }
            }
            if (potluckdb_database_release_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                return NO;
            }
            break;
        case PLKOwnerKindConnection:
            if (needsClose) {
                if (potluckdb_connection_close_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                    return NO;
                }
            }
            if (potluckdb_connection_release_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                return NO;
            }
            break;
        case PLKOwnerKindSnapshot:
            if (needsClose) {
                if (potluckdb_snapshot_close_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                    return NO;
                }
            }
            if (potluckdb_snapshot_release_v1(_handle, NULL) != POTLUCKDB_APPLICATION_OK_V1) {
                return NO;
            }
            break;
        case PLKOwnerKindTransaction:
            (void)potluckdb_transaction_release_v1(_handle, NULL);
            break;
    }
    _handle = 0;
    _retained = nil;
    return YES;
}

- (void)dealloc {
    if (![self cleanup]) { [self orphanBorrowers]; }
}

- (BOOL)withHandle:(BOOL (^)(uint64_t handle, NSError **error))body
             error:(NSError **)error {
    [_lock lock];
    BOOL live = _handle != 0;
    uint64_t handle = _handle;
    if (!live) {
        [_lock unlock];
        return PLKFail(
            error,
            PLKMakeError(@"invalid_state", PLKErrorCategoryCaller,
                         @"potluckdb owner is released",
                         @"Open a new owner and retry."));
    }
    BOOL outcome = body(handle, error);
    [_lock unlock];
    return outcome;
}

- (BOOL)withPair:(PLKHandleState *)other
            body:(BOOL (^)(uint64_t left, uint64_t right, NSError **error))body
           error:(NSError **)error {
    PLKHandleState *first = (uintptr_t)self < (uintptr_t)other ? self : other;
    PLKHandleState *second = first == self ? other : self;
    [first->_lock lock];
    [second->_lock lock];
    BOOL outcome;
    if (self->_handle == 0 || other->_handle == 0) {
        outcome = PLKFail(
            error,
            PLKMakeError(@"invalid_state", PLKErrorCategoryCaller,
                         @"potluckdb Remote is released",
                         @"Open new Remote values and retry."));
    } else {
        outcome = body(self->_handle, other->_handle, error);
    }
    [second->_lock unlock];
    [first->_lock unlock];
    return outcome;
}

- (BOOL)closeUsing:(int32_t (*)(uint64_t, PotluckDbErrorV1 *))call
             error:(NSError **)error {
    if (potluckdb_internal_storage_callback_active_v1() != 0) {
        return PLKFail(error, PLKMakeError(@"invalid_state", PLKErrorCategoryCaller,
            @"recursive close from a storage callback is refused",
            @"Close the owner after the callback returns."));
    }
    [_lock lock];
    if (_handle == 0 || _closed) {
        [_lock unlock];
        return YES;
    }
    PotluckDbErrorV1 raw;
    potluckdb_error_init_v1(&raw);
    BOOL outcome = PLKCheck(call(_handle, &raw), &raw, error);
    if (outcome) {
        _closed = YES;
    }
    [_lock unlock];
    return outcome;
}

- (BOOL)releaseUsing:(int32_t (*)(uint64_t, PotluckDbErrorV1 *))call
               error:(NSError **)error {
    [_lock lock];
    if (_handle == 0) {
        [_lock unlock];
        return YES;
    }
    PotluckDbErrorV1 raw;
    potluckdb_error_init_v1(&raw);
    BOOL outcome = PLKCheck(call(_handle, &raw), &raw, error);
    if (outcome || _kind == PLKOwnerKindTransaction) {
        _handle = 0;
        _retained = nil;
    }
    [_lock unlock];
    return outcome;
}

@end

@implementation PLKRevision {
    NSData *_data;
}

+ (instancetype)revisionWithData:(NSData *)data error:(NSError **)error {
    if (data.length != 32) {
        PLKFail(error,
                PLKInvalidArgument(@"revision must contain exactly 32 bytes",
                                   @"Supply a 32-byte revision and retry."));
        return nil;
    }
    PLKRevision *revision = [[PLKRevision alloc] init];
    revision->_data = [data copy];
    return revision;
}

+ (instancetype)revisionWithRaw:(PotluckDbRevisionV1)raw {
    PLKRevision *revision = [[PLKRevision alloc] init];
    revision->_data = [NSData dataWithBytes:raw.bytes length:32];
    return revision;
}

+ (instancetype)parse:(NSString *)text error:(NSError **)error {
    NSData *encoded = PLKUtf8(text);
    if (encoded == nil) {
        PLKFail(error, PLKUnencodableText());
        return nil;
    }
    PotluckDbRevisionV1 raw;
    memset(&raw, 0, sizeof(raw));
    PotluckDbErrorV1 failure;
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(
            potluckdb_revision_parse_v1(PLKSliceFromData(encoded), &raw,
                                        &failure),
            &failure, error)) {
        return nil;
    }
    return [PLKRevision revisionWithRaw:raw];
}

- (NSData *)data {
    return _data;
}

- (PotluckDbRevisionV1)raw {
    PotluckDbRevisionV1 value;
    memset(&value, 0, sizeof(value));
    [_data getBytes:value.bytes length:32];
    return value;
}

- (NSString *)formattedWithError:(NSError **)error {
    PotluckDbRevisionV1 raw = [self raw];
    PotluckDbBufferV1 text = {0};
    PotluckDbErrorV1 failure;
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_revision_format_v1(&raw, &text, &failure), &failure,
                  error)) {
        return nil;
    }
    NSString *value = PLKBufferString(text);
    (void)potluckdb_buffer_release_v1(&text);
    return value;
}

- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:[PLKRevision class]] &&
           [((PLKRevision *)object)->_data isEqualToData:_data];
}

- (NSUInteger)hash {
    return _data.hash;
}

- (NSString *)description {
    NSMutableString *text = [NSMutableString stringWithCapacity:64];
    const uint8_t *bytes = _data.bytes;
    for (NSUInteger index = 0; index < _data.length; index += 1) {
        [text appendFormat:@"%02x", bytes[index]];
    }
    return text;
}

@end

@implementation PLKAutomaticSyncOptions

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _outboundDebounceMilliseconds = 30;
        _activePullIntervalMilliseconds = 200;
        _idlePullIntervalMilliseconds = 1000;
        _retryInitialMilliseconds = 250;
        _retryMaximumMilliseconds = 30000;
    }
    return self;
}

@end

@implementation PLKSyncPolicy {
  @public
    BOOL _automatic;
    PLKAutomaticSyncOptions *_options;
}

+ (instancetype)automaticPolicy {
    PLKSyncPolicy *policy = [[PLKSyncPolicy alloc] init];
    policy->_automatic = YES;
    policy->_options = [[PLKAutomaticSyncOptions alloc] init];
    return policy;
}

+ (instancetype)automaticPolicyWithOptions:(PLKAutomaticSyncOptions *)options
                                     error:(NSError **)error {
    uint64_t timers[] = {
        options.outboundDebounceMilliseconds,
        options.activePullIntervalMilliseconds,
        options.idlePullIntervalMilliseconds,
        options.retryInitialMilliseconds,
        options.retryMaximumMilliseconds,
    };
    for (size_t index = 0; index < 5; index += 1) {
        if (timers[index] < 1 || timers[index] > 86400000) {
            PLKFail(error,
                    PLKInvalidArgument(
                        @"sync timers must be from 1 through 86400000 milliseconds",
                        @"Correct the timer values and retry."));
            return nil;
        }
    }
    if (options.idlePullIntervalMilliseconds <
        options.activePullIntervalMilliseconds) {
        PLKFail(error,
                PLKInvalidArgument(
                    @"idle pull interval must be at least the active pull interval",
                    @"Correct the pull intervals and retry."));
        return nil;
    }
    if (options.retryMaximumMilliseconds < options.retryInitialMilliseconds) {
        PLKFail(error,
                PLKInvalidArgument(
                    @"maximum retry delay must be at least the initial retry delay",
                    @"Correct the retry delays and retry."));
        return nil;
    }
    PLKSyncPolicy *policy = [[PLKSyncPolicy alloc] init];
    policy->_automatic = YES;
    policy->_options = options;
    return policy;
}

+ (instancetype)manualPolicy {
    PLKSyncPolicy *policy = [[PLKSyncPolicy alloc] init];
    policy->_automatic = NO;
    policy->_options = [[PLKAutomaticSyncOptions alloc] init];
    return policy;
}

- (void)fill:(PotluckDbSyncPolicyV1 *)raw {
    potluckdb_sync_policy_init_v1(raw);
    raw->mode = _automatic ? POTLUCKDB_SYNC_AUTOMATIC_V1
                           : POTLUCKDB_SYNC_MANUAL_V1;
    raw->outbound_debounce_ms = _options.outboundDebounceMilliseconds;
    raw->active_pull_interval_ms = _options.activePullIntervalMilliseconds;
    raw->idle_pull_interval_ms = _options.idlePullIntervalMilliseconds;
    raw->retry_initial_ms = _options.retryInitialMilliseconds;
    raw->retry_max_ms = _options.retryMaximumMilliseconds;
}

@end

@implementation PLKPrefetchPolicy {
  @public
    BOOL _enabled;
    uint64_t _backgroundTargetBytes;
    uint64_t _memoryBudgetBytes;
}

+ (instancetype)automaticPolicy {
    PLKPrefetchPolicy *policy = [[PLKPrefetchPolicy alloc] init];
    policy->_enabled = YES;
    policy->_memoryBudgetBytes = 64ull * 1024 * 1024;
    return policy;
}

+ (instancetype)automaticPolicyWithBackgroundTargetBytes:
                    (uint64_t)backgroundTargetBytes
                                       memoryBudgetBytes:
                                           (uint64_t)memoryBudgetBytes
                                                   error:(NSError **)error {
    if (memoryBudgetBytes == 0) {
        PLKFail(error, PLKInvalidArgument(
                           @"prefetch memory budget must be positive",
                           @"Raise the prefetch memory budget and retry."));
        return nil;
    }
    PLKPrefetchPolicy *policy = [[PLKPrefetchPolicy alloc] init];
    policy->_enabled = YES;
    policy->_backgroundTargetBytes = backgroundTargetBytes;
    policy->_memoryBudgetBytes = memoryBudgetBytes;
    return policy;
}

+ (instancetype)disabledPolicy {
    return [[PLKPrefetchPolicy alloc] init];
}

@end

@implementation PLKCheckpointPolicy {
  @public
    BOOL _enabled;
    uint64_t _softLimitBytes;
    uint64_t _forcedLimitBytes;
}

+ (instancetype)automaticPolicy {
    PLKCheckpointPolicy *policy = [[PLKCheckpointPolicy alloc] init];
    policy->_enabled = YES;
    policy->_softLimitBytes = 64ull * 1024 * 1024;
    policy->_forcedLimitBytes = 128ull * 1024 * 1024;
    return policy;
}

+ (instancetype)automaticPolicyWithSoftLimitBytes:(uint64_t)softLimitBytes
                                 forcedLimitBytes:(uint64_t)forcedLimitBytes
                                            error:(NSError **)error {
    if (softLimitBytes == 0 || forcedLimitBytes < softLimitBytes) {
        PLKFail(
            error,
            PLKInvalidArgument(
                @"checkpoint limits must be positive and forced must not be below soft",
                @"Correct the checkpoint limits and retry."));
        return nil;
    }
    PLKCheckpointPolicy *policy = [[PLKCheckpointPolicy alloc] init];
    policy->_enabled = YES;
    policy->_softLimitBytes = softLimitBytes;
    policy->_forcedLimitBytes = forcedLimitBytes;
    return policy;
}

+ (instancetype)disabledPolicy {
    return [[PLKCheckpointPolicy alloc] init];
}

@end

@implementation PLKRetentionPolicy {
  @public
    uint64_t _keepLast;
    uint64_t _collectAt;
    BOOL _unbounded;
}

+ (instancetype)boundedWithKeepLast:(uint64_t)keepLast
                          collectAt:(uint64_t)collectAt
                              error:(NSError **)error {
    if (keepLast == 0 || collectAt <= keepLast) {
        PLKFail(error,
                PLKInvalidArgument(
                    @"retention keepLast must be positive and collectAt must be greater",
                    @"Correct the retention bounds and retry."));
        return nil;
    }
    PLKRetentionPolicy *policy = [[PLKRetentionPolicy alloc] init];
    policy->_keepLast = keepLast;
    policy->_collectAt = collectAt;
    return policy;
}

+ (instancetype)unboundedPolicy {
    PLKRetentionPolicy *policy = [[PLKRetentionPolicy alloc] init];
    policy->_unbounded = YES;
    return policy;
}

- (BOOL)bounded {
    return !_unbounded;
}

+ (instancetype)boundedPolicy {
    return [PLKRetentionPolicy boundedWithKeepLast:10 collectAt:20 error:NULL];
}

- (void)fill:(PotluckDbRetentionPolicyV1 *)raw {
    potluckdb_retention_policy_init_v1(raw);
    raw->keep_last = _keepLast;
    raw->collect_at = _collectAt;
}

@end

@implementation PLKConnectionOptions

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _timeoutMilliseconds = 5000;
        _maximumRows = 1000000;
        _prefetch = [PLKPrefetchPolicy automaticPolicy];
        _checkpoint = [PLKCheckpointPolicy automaticPolicy];
    }
    return self;
}

- (BOOL)fill:(PotluckDbConnectionOptionsV1 *)raw error:(NSError **)error {
    if (_prefetch == nil || _checkpoint == nil) {
        return PLKFail(error,
                       PLKInvalidArgument(
                           @"prefetch and checkpoint policies must not be nil",
                           @"Set both policies and retry."));
    }
    if (_timeoutMilliseconds > 86400000 || _maximumRows == 0) {
        return PLKFail(
            error,
            PLKInvalidArgument(
                @"connection timeout or result limit is outside the supported bounds",
                @"Use a timeout up to one day and a positive maximumRows."));
    }
    potluckdb_connection_options_init_v1(raw);
    raw->timeout_ms = _timeoutMilliseconds;
    raw->maximum_rows = _maximumRows;
    raw->prefetch_mode = _prefetch->_enabled ? POTLUCKDB_PREFETCH_AUTOMATIC_V1
                                             : POTLUCKDB_PREFETCH_DISABLED_V1;
    raw->prefetch_background_target_bytes = _prefetch->_backgroundTargetBytes;
    raw->prefetch_memory_budget_bytes = _prefetch->_memoryBudgetBytes;
    raw->checkpoint_mode = _checkpoint->_enabled
                               ? POTLUCKDB_CHECKPOINT_AUTOMATIC_V1
                               : POTLUCKDB_CHECKPOINT_DISABLED_V1;
    raw->checkpoint_soft_limit_bytes = _checkpoint->_softLimitBytes;
    raw->checkpoint_forced_limit_bytes = _checkpoint->_forcedLimitBytes;
    return YES;
}

@end

@implementation PLKOpenOptions

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _localBudgetBytes = 1024ull * 1024 * 1024;
        _minimumLocalBudgetBytes = 10ull * 1024 * 1024;
        _localCompactionBytes = 256ull * 1024 * 1024;
        _syncPolicy = [PLKSyncPolicy automaticPolicy];
        _connection = [[PLKConnectionOptions alloc] init];
    }
    return self;
}

- (BOOL)fill:(PotluckDbOpenOptionsV1 *)raw
    clientIdentity:(NSData *_Nullable *_Nonnull)clientIdentity
        licenseKey:(NSData *_Nullable *_Nonnull)licenseKey
  analyticalEngine:(NSData *_Nullable *_Nonnull)analyticalEngine
             error:(NSError **)error {
    if (_connection == nil) {
        return PLKFail(error,
                       PLKInvalidArgument(@"connection options must not be nil",
                                          @"Set connection options and retry."));
    }
    if (_localBudgetBytes < _minimumLocalBudgetBytes) {
        return PLKFail(
            error,
            PLKInvalidArgument(
                @"local budget must be at least the minimum local budget",
                @"Raise the local budget or lower the minimum and retry."));
    }
    if (_localCompactionBytes == 0) {
        return PLKFail(error,
                       PLKInvalidArgument(
                           @"local compaction threshold must be positive",
                           @"Raise the compaction threshold and retry."));
    }
    if (_encryptionKey != nil && _encryptionKey.length != 32) {
        return PLKFail(error,
                       PLKInvalidArgument(
                           @"encryption key must contain exactly 32 bytes",
                           @"Supply a 32-byte key and retry."));
    }
    if (_clientID != nil) {
        NSRegularExpression *shape = [NSRegularExpression
            regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"
                                 options:0
                                   error:NULL];
        NSRange range = NSMakeRange(0, _clientID.length);
        if ([shape numberOfMatchesInString:_clientID options:0 range:range] !=
            1) {
            return PLKFail(
                error,
                PLKInvalidArgument(
                    @"clientID must be a portable identity of 1 through 128 characters",
                    @"Correct the client identity and retry."));
        }
    }
    potluckdb_open_options_init_v1(raw);
    raw->local_budget_bytes = _localBudgetBytes;
    raw->minimum_local_budget_bytes = _minimumLocalBudgetBytes;
    raw->local_compaction_bytes = _localCompactionBytes;
    [_syncPolicy fill:&raw->sync_policy];
    if (![_connection fill:&raw->connection error:error]) {
        return NO;
    }
    if (_encryptionKey != nil) {
        raw->flags |= POTLUCKDB_OPEN_ENCRYPTION_KEY_V1;
        [_encryptionKey getBytes:raw->encryption_key length:32];
    }
    if (_clientID != nil) {
        *clientIdentity = PLKUtf8(_clientID);
        if (*clientIdentity == nil) {
            PLKFail(error, PLKUnencodableText());
            return NO;
        }
        raw->flags |= POTLUCKDB_OPEN_CLIENT_ID_V1;
        raw->client_id = PLKSliceFromData(*clientIdentity);
    }
    if (_licenseKey != nil) {
        *licenseKey = PLKUtf8(_licenseKey);
        if (*licenseKey == nil) {
            PLKFail(error, PLKUnencodableText());
            return NO;
        }
        raw->flags |= POTLUCKDB_OPEN_LICENSE_KEY_V1;
        raw->license_key = PLKSliceFromData(*licenseKey);
    }
    if (_analyticalEngine != nil) {
        *analyticalEngine = PLKUtf8(_analyticalEngine);
        if (*analyticalEngine == nil) {
            PLKFail(error, PLKUnencodableText());
            return NO;
        }
        raw->flags |= POTLUCKDB_OPEN_ANALYTICAL_ENGINE_V1;
        raw->analytical_engine = PLKSliceFromData(*analyticalEngine);
    }
    return YES;
}

@end

@implementation PLKRemoteOptions

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _readConcurrency = 32;
        _writeConcurrency = 16;
        _retention = [PLKRetentionPolicy boundedPolicy];
    }
    return self;
}

- (void)setRetention:(PLKRetentionPolicy *)retention {
    _retention = retention != nil ? retention : [PLKRetentionPolicy boundedPolicy];
}

- (BOOL)fill:(PotluckDbRemoteOptionsV1 *)raw error:(NSError **)error {
    if (_readConcurrency < 1 || _readConcurrency > 256 ||
        _writeConcurrency < 1 || _writeConcurrency > 128) {
        return PLKFail(
            error,
            PLKInvalidArgument(
                @"remote concurrency is outside the supported bounds",
                @"Use read concurrency 1 through 256 and write concurrency 1 through 128."));
    }
    potluckdb_remote_options_init_v1(raw);
    raw->read_concurrency = _readConcurrency;
    raw->write_concurrency = _writeConcurrency;
    raw->flags &= ~POTLUCKDB_REMOTE_RETENTION_V1;
    if (_retention.bounded) {
        raw->flags |= POTLUCKDB_REMOTE_RETENTION_V1;
        [_retention fill:&raw->retention];
    }
    return YES;
}

@end

@implementation PLKBindings {
  @public
    uint32_t _kind;
    NSArray<NSString *> *_Nullable _names;
    NSArray *_values;
}

+ (instancetype)positional:(NSArray *)values {
    PLKBindings *bindings = [[PLKBindings alloc] init];
    bindings->_kind = POTLUCKDB_BINDINGS_POSITIONAL_V1;
    bindings->_values = [values copy];
    return bindings;
}

+ (instancetype)named:(NSDictionary<NSString *, id> *)values {
    NSArray<NSString *> *names =
        [values.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
        [ordered addObject:values[name]];
    }
    PLKBindings *bindings = [[PLKBindings alloc] init];
    bindings->_kind = POTLUCKDB_BINDINGS_NAMED_V1;
    bindings->_names = names;
    bindings->_values = ordered;
    return bindings;
}

+ (instancetype)none {
    return [PLKBindings positional:@[]];
}

- (BOOL)withRaw:(BOOL (^)(const PotluckDbBindingsV1 *bindings,
                          NSError **bodyError))body
          error:(NSError **)error {
    PotluckDbBindingsV1 raw;
    potluckdb_bindings_init_v1(&raw);
    raw.kind = _kind;
    NSUInteger count = _values.count;
    if (count == 0) {
        return body(&raw, error);
    }
    PotluckDbBindingV1 *items = calloc(count, sizeof(PotluckDbBindingV1));
    if (items == NULL) {
        return PLKFail(error,
                       PLKInternalFailure(@"binding allocation failed"));
    }
    // Encoded strings stay reachable here so borrowed slices survive the call.
    NSMutableArray<NSData *> *buffers = [NSMutableArray array];
    BOOL prepared = YES;
    for (NSUInteger index = 0; index < count && prepared; index += 1) {
        potluckdb_binding_init_v1(&items[index]);
        if (_names != nil) {
            NSData *name = PLKUtf8(_names[index]);
            if (name == nil) {
                PLKFail(error, PLKUnencodableText());
                prepared = NO;
                continue;
            }
            [buffers addObject:name];
            items[index].name = PLKSliceFromData(name);
        }
        potluckdb_value_init_v1(&items[index].value);
        id value = _values[index];
        if (value == [NSNull null]) {
            items[index].value.kind = POTLUCKDB_VALUE_NULL_V1;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            NSNumber *number = value;
            if (CFGetTypeID((__bridge CFTypeRef)number) ==
                CFBooleanGetTypeID()) {
                items[index].value.kind = POTLUCKDB_VALUE_BOOLEAN_V1;
                items[index].value.boolean_value = number.boolValue ? 1 : 0;
            } else if (strcmp(number.objCType, @encode(double)) == 0 ||
                       strcmp(number.objCType, @encode(float)) == 0) {
                items[index].value.kind = POTLUCKDB_VALUE_REAL_V1;
                items[index].value.real_value = number.doubleValue;
            } else {
                const char *type = number.objCType;
                if ((strcmp(type, @encode(unsigned char)) == 0 ||
                     strcmp(type, @encode(unsigned short)) == 0 ||
                     strcmp(type, @encode(unsigned int)) == 0 ||
                     strcmp(type, @encode(unsigned long)) == 0 ||
                     strcmp(type, @encode(unsigned long long)) == 0) &&
                    number.unsignedLongLongValue >
                        (unsigned long long)INT64_MAX) {
                    PLKFail(
                        error,
                        PLKInvalidArgument(
                            @"integer bindings must fit in a signed 64-bit value",
                            @"Bind a value between -9223372036854775808 and "
                            @"9223372036854775807 and retry."));
                    prepared = NO;
                } else {
                    items[index].value.kind = POTLUCKDB_VALUE_INTEGER_V1;
                    items[index].value.integer_value = number.longLongValue;
                }
            }
        } else if ([value isKindOfClass:[NSString class]]) {
            NSData *text = PLKUtf8(value);
            if (text == nil) {
                PLKFail(error, PLKUnencodableText());
                prepared = NO;
                continue;
            }
            [buffers addObject:text];
            items[index].value.kind = POTLUCKDB_VALUE_TEXT_V1;
            items[index].value.bytes = PLKSliceFromData(text);
        } else if ([value isKindOfClass:[NSData class]]) {
            items[index].value.kind = POTLUCKDB_VALUE_BLOB_V1;
            items[index].value.bytes = PLKSliceFromData(value);
        } else {
            PLKFail(
                error,
                PLKInvalidArgument(
                    @"binding values must be NSNull, NSNumber, NSString, or NSData",
                    @"Convert the value to a supported SQL type and retry."));
            prepared = NO;
        }
    }
    BOOL outcome = NO;
    if (prepared) {
        raw.items = items;
        raw.count = count;
        outcome = body(&raw, error);
    }
    free(items);
    (void)buffers;
    return outcome;
}

@end

@implementation PLKRow {
    NSArray<NSString *> *_columns;
    NSArray *_values;
}

- (instancetype)initWithColumns:(NSArray<NSString *> *)columns
                         values:(NSArray *)values {
    self = [super init];
    if (self != nil) {
        _columns = columns;
        _values = values;
    }
    return self;
}

- (NSArray<NSString *> *)columns {
    return _columns;
}

- (NSArray *)values {
    return _values;
}

- (NSUInteger)count {
    return _values.count;
}

- (id)objectAtIndexedSubscript:(NSUInteger)index {
    return _values[index];
}

- (id)objectForKeyedSubscript:(NSString *)column {
    for (NSUInteger index = _columns.count; index > 0; index -= 1) {
        if ([_columns[index - 1] isEqualToString:column]) {
            return _values[index - 1];
        }
    }
    return nil;
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:[PLKRow class]]) {
        return NO;
    }
    PLKRow *other = object;
    return [_columns isEqualToArray:other->_columns] &&
           [_values isEqualToArray:other->_values];
}

- (NSUInteger)hash {
    return _columns.hash ^ _values.hash;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained _Nonnull[])buffer
                                    count:(NSUInteger)length {
    return [_values countByEnumeratingWithState:state
                                        objects:buffer
                                          count:length];
}

@end

@implementation PLKRows {
    NSArray<NSString *> *_columns;
    NSArray<PLKRow *> *_rows;
}

- (instancetype)initWithColumns:(NSArray<NSString *> *)columns
                           rows:(NSArray<PLKRow *> *)rows {
    self = [super init];
    if (self != nil) {
        _columns = columns;
        _rows = rows;
    }
    return self;
}

- (NSArray<NSString *> *)columns {
    return _columns;
}

- (NSArray<PLKRow *> *)rows {
    return _rows;
}

- (NSUInteger)count {
    return _rows.count;
}

- (PLKRow *)objectAtIndexedSubscript:(NSUInteger)index {
    return _rows[index];
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    if (![object isKindOfClass:[PLKRows class]]) {
        return NO;
    }
    PLKRows *other = object;
    return [_columns isEqualToArray:other->_columns] &&
           [_rows isEqualToArray:other->_rows];
}

- (NSUInteger)hash {
    return _columns.hash ^ _rows.hash;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained _Nonnull[])buffer
                                    count:(NSUInteger)length {
    return [_rows countByEnumeratingWithState:state
                                      objects:buffer
                                        count:length];
}

@end

@implementation PLKExecuteResult {
  @public
    int64_t _rowsAffected;
    NSNumber *_Nullable _lastInsertID;
}

- (int64_t)rowsAffected {
    return _rowsAffected;
}

- (NSNumber *)lastInsertID {
    return _lastInsertID;
}

@end

static PLKRows *_Nullable PLKCopyRows(PotluckDbRowsHandleV1 handle,
                                      NSError **error) {
    NSMutableArray *rows = nil;
    uint64_t rowCount = 0;
    PotluckDbErrorV1 failure;
    potluckdb_error_init_v1(&failure);
    uint64_t nameCount = 0;
    if (!PLKCheck(potluckdb_rows_column_name_count_v1(handle, &nameCount,
                                                      &failure),
                  &failure, error)) {
        (void)potluckdb_rows_release_v1(handle, NULL);
        return nil;
    }
    NSMutableArray<NSString *> *columns =
        [NSMutableArray arrayWithCapacity:(NSUInteger)nameCount];
    for (uint64_t column = 0; column < nameCount; column += 1) {
        PotluckDbSliceV1 name = {0};
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_rows_column_name_v1(handle, column, &name,
                                                    &failure),
                      &failure, error)) {
            (void)potluckdb_rows_release_v1(handle, NULL);
            return nil;
        }
        NSString *text =
            PLKSQLText((const uint8_t *)name.data, (NSUInteger)name.length);
        [columns addObject:text != nil ? text : @""];
    }
    NSArray<NSString *> *names = [columns copy];
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_rows_row_count_v1(handle, &rowCount, &failure),
                  &failure, error)) {
        (void)potluckdb_rows_release_v1(handle, NULL);
        return nil;
    }
    rows = [NSMutableArray arrayWithCapacity:(NSUInteger)rowCount];
    for (uint64_t row = 0; row < rowCount; row += 1) {
        uint64_t columnCount = 0;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_rows_column_count_v1(handle, row, &columnCount,
                                                     &failure),
                      &failure, error)) {
            (void)potluckdb_rows_release_v1(handle, NULL);
            return nil;
        }
        NSMutableArray *values =
            [NSMutableArray arrayWithCapacity:(NSUInteger)columnCount];
        for (uint64_t column = 0; column < columnCount; column += 1) {
            PotluckDbValueV1 value;
            potluckdb_value_init_v1(&value);
            potluckdb_error_init_v1(&failure);
            if (!PLKCheck(potluckdb_rows_value_v1(handle, row, column, &value,
                                                  (uint32_t)sizeof(value),
                                                  &failure),
                          &failure, error)) {
                (void)potluckdb_rows_release_v1(handle, NULL);
                return nil;
            }
            switch (value.kind) {
                case POTLUCKDB_VALUE_NULL_V1:
                    [values addObject:[NSNull null]];
                    break;
                case POTLUCKDB_VALUE_BOOLEAN_V1:
                    [values addObject:value.boolean_value ? @YES : @NO];
                    break;
                case POTLUCKDB_VALUE_INTEGER_V1:
                    [values addObject:@(value.integer_value)];
                    break;
                case POTLUCKDB_VALUE_REAL_V1:
                    [values addObject:@(value.real_value)];
                    break;
                case POTLUCKDB_VALUE_TEXT_V1: {
                    NSString *text = PLKSQLText(
                        (const uint8_t *)value.bytes.data,
                        (NSUInteger)value.bytes.length);
                    if (text == nil) {
                        (void)potluckdb_rows_release_v1(handle, NULL);
                        PLKFail(error,
                                PLKInternalFailure(
                                    @"potluckdb returned text that is not UTF-8"));
                        return nil;
                    }
                    [values addObject:text];
                    break;
                }
                case POTLUCKDB_VALUE_BLOB_V1:
                    [values
                        addObject:[NSData dataWithBytes:value.bytes.data
                                                 length:(NSUInteger)
                                                            value.bytes.length]];
                    break;
                default:
                    (void)potluckdb_rows_release_v1(handle, NULL);
                    PLKFail(error,
                            PLKInternalFailure(
                                @"potluckdb returned an unknown SQL value kind"));
                    return nil;
            }
        }
        [rows addObject:[[PLKRow alloc] initWithColumns:names values:values]];
    }
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_rows_release_v1(handle, &failure), &failure,
                  error)) {
        return nil;
    }
    return [[PLKRows alloc] initWithColumns:names rows:[rows copy]];
}

static NSArray<NSString *> *_Nullable PLKCopyStrings(
    PotluckDbStringListHandleV1 handle, NSError **error) {
    uint64_t count = 0;
    PotluckDbErrorV1 failure;
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_string_list_count_v1(handle, &count, &failure),
                  &failure, error)) {
        return nil;
    }
    NSMutableArray<NSString *> *values =
        [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (uint64_t index = 0; index < count; index += 1) {
        PotluckDbSliceV1 slice = {0};
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(
                potluckdb_string_list_get_v1(handle, index, &slice, &failure),
                &failure, error)) {
            return nil;
        }
        NSString *text =
            [[NSString alloc] initWithBytes:slice.data
                                     length:(NSUInteger)slice.length
                                   encoding:NSUTF8StringEncoding];
        [values addObject:text != nil ? text : @""];
    }
    return values;
}

static NSString *PLKSyncStateName(uint32_t value) {
    switch (value) {
        case 1:
            return @"manual";
        case 2:
            return @"unbound";
        case 3:
            return @"scheduled";
        case 4:
            return @"synchronizing";
        case 5:
            return @"idle";
        case 6:
            return @"backoff";
        case 7:
            return @"conflict";
        case 8:
            return @"failed";
        case 9:
            return @"closed";
        default:
            return @"unknown";
    }
}

static NSString *PLKBackgroundStateName(uint32_t value) {
    switch (value) {
        case 0:
            return @"disabled";
        case 1:
            return @"idle";
        case 2:
            return @"fetching";
        case 3:
            return @"installing";
        case 4:
            return @"paused";
        case 5:
            return @"complete";
        case 6:
            return @"saturated";
        case 7:
            return @"failed";
        case 8:
            return @"closed";
        default:
            return @"unknown";
    }
}

@implementation PLKSyncResult {
  @public
    PLKSyncOutcome _outcome;
    PLKRevision *_Nullable _revision;
    NSArray<NSString *> *_Nullable _replayed;
    NSArray<NSString *> *_Nullable _quarantined;
    NSString *_Nullable _conflictReason;
    NSError *_Nullable _error;
}

- (PLKSyncOutcome)outcome {
    return _outcome;
}

- (PLKRevision *)revision {
    return _revision;
}

- (NSArray<NSString *> *)replayed {
    return _replayed;
}

- (NSArray<NSString *> *)quarantined {
    return _quarantined;
}

- (NSString *)conflictReason {
    return _conflictReason;
}

- (NSError *)error {
    return _error;
}

@end

/// The facade's reading of one raw synchronization outcome. The raw value
/// stays with its owner; the caller releases it.
static PLKSyncResult *_Nullable PLKSyncResultFromRaw(
    const PotluckDbSyncResultV1 *output, NSError **error) {
    PLKSyncResult *result = [[PLKSyncResult alloc] init];
    result->_outcome = (PLKSyncOutcome)output->kind;
    switch (output->kind) {
        case POTLUCKDB_SYNC_UP_TO_DATE_V1:
        case POTLUCKDB_SYNC_CONFLICT_V1:
            if (output->has_revision != 0) {
                result->_revision = [PLKRevision revisionWithRaw:output->revision];
            }
            if (output->kind == POTLUCKDB_SYNC_CONFLICT_V1) {
                result->_conflictReason = PLKBufferString(output->reason);
            }
            return result;
        case POTLUCKDB_SYNC_PUSHED_V1:
            result->_revision = [PLKRevision revisionWithRaw:output->revision];
            return result;
        case POTLUCKDB_SYNC_PULLED_V1:
            result->_revision = [PLKRevision revisionWithRaw:output->revision];
            result->_replayed = PLKCopyStrings(output->replayed, error);
            if (result->_replayed == nil) {
                return nil;
            }
            result->_quarantined = PLKCopyStrings(output->quarantined, error);
            return result->_quarantined == nil ? nil : result;
        case POTLUCKDB_SYNC_FAILED_V1:
            result->_error = PLKErrorFromRaw(&output->error);
            return result;
        default:
            PLKFail(error,
                    PLKInternalFailure(
                        @"potluckdb returned an unknown synchronization result"));
            return nil;
    }
}

/// The registered `PLKOpenOptions.onSync`. The database that registered
/// it retains it until its handle is released; the runtime returns from
/// close only after the hook's last invocation.
@interface PLKSyncHook : NSObject {
  @public
    void (^_block)(PLKSyncResult *outcome);
}
@end

@implementation PLKSyncHook
@end

/// `PotluckDbOnSyncV1`. An outcome the facade cannot read is delivered as
/// a Failed result carrying the facade's error. The pool is this thread's
/// only one: the runtime's thread brings none.
static void PLKDeliverSync(void *context, PotluckDbSyncResultV1 outcome) {
    @autoreleasepool {
        NSError *failure = nil;
        PLKSyncResult *result = PLKSyncResultFromRaw(&outcome, &failure);
        (void)potluckdb_sync_result_release_v1(&outcome);
        if (result == nil) {
            result = [[PLKSyncResult alloc] init];
            result->_outcome = PLKSyncOutcomeFailed;
            result->_error =
                failure != nil
                    ? failure
                    : PLKInternalFailure(
                          @"potluckdb returned an unreadable synchronization result");
        }
        PLKSyncHook *hook = (__bridge PLKSyncHook *)context;
        hook->_block(result);
    }
}

@implementation PLKConflictResolution {
  @public
    PLKRevision *_revision;
    NSArray<NSString *> *_alreadyPublished;
    NSArray<NSString *> *_replayed;
    NSArray<NSString *> *_quarantined;
    NSArray<NSString *> *_pending;
}

- (PLKRevision *)revision {
    return _revision;
}

- (NSArray<NSString *> *)alreadyPublished {
    return _alreadyPublished;
}

- (NSArray<NSString *> *)replayed {
    return _replayed;
}

- (NSArray<NSString *> *)quarantined {
    return _quarantined;
}

- (NSArray<NSString *> *)pending {
    return _pending;
}

@end

@implementation PLKCollectionReport {
  @public
    PLKRevision *_Nullable _floorBefore;
    PLKRevision *_Nullable _floorAfter;
    uint64_t _epoch;
    uint64_t _marked;
    uint64_t _swept;
    BOOL _aborted;
}

- (PLKRevision *)floorBefore {
    return _floorBefore;
}

- (PLKRevision *)floorAfter {
    return _floorAfter;
}

- (uint64_t)epoch {
    return _epoch;
}

- (uint64_t)marked {
    return _marked;
}

- (uint64_t)swept {
    return _swept;
}

- (BOOL)aborted {
    return _aborted;
}

+ (instancetype)reportWithRaw:(const PotluckDbCollectionReportV1 *)raw {
    PLKCollectionReport *report = [[PLKCollectionReport alloc] init];
    if (raw->has_floor_before != 0) {
        report->_floorBefore = [PLKRevision revisionWithRaw:raw->floor_before];
    }
    if (raw->has_floor_after != 0) {
        report->_floorAfter = [PLKRevision revisionWithRaw:raw->floor_after];
    }
    report->_epoch = raw->epoch;
    report->_marked = raw->marked;
    report->_swept = raw->swept;
    report->_aborted = raw->aborted != 0;
    return report;
}

@end

@implementation PLKDatabaseStatus {
  @public
    PLKRevision *_Nullable _revision;
    uint64_t _pendingWrites;
    uint64_t _localBytes;
    uint64_t _localBudgetBytes;
    uint64_t _connectionCount;
    NSString *_syncState;
    NSNumber *_Nullable _nextSyncInMilliseconds;
    PLKRevision *_Nullable _conflictRemoteRevision;
    BOOL _closed;
}

- (PLKRevision *)revision {
    return _revision;
}

- (uint64_t)pendingWrites {
    return _pendingWrites;
}

- (uint64_t)localBytes {
    return _localBytes;
}

- (uint64_t)localBudgetBytes {
    return _localBudgetBytes;
}

- (uint64_t)connectionCount {
    return _connectionCount;
}

- (NSString *)syncState {
    return _syncState;
}

- (NSNumber *)nextSyncInMilliseconds {
    return _nextSyncInMilliseconds;
}

- (PLKRevision *)conflictRemoteRevision {
    return _conflictRemoteRevision;
}

- (BOOL)closed {
    return _closed;
}

+ (instancetype)statusWithRaw:(const PotluckDbDatabaseStatusV1 *)raw {
    PLKDatabaseStatus *status = [[PLKDatabaseStatus alloc] init];
    if (raw->has_revision != 0) {
        status->_revision = [PLKRevision revisionWithRaw:raw->revision];
    }
    status->_pendingWrites = raw->pending_writes;
    status->_localBytes = raw->local_bytes;
    status->_localBudgetBytes = raw->local_budget_bytes;
    status->_connectionCount = raw->connection_count;
    status->_syncState = PLKSyncStateName(raw->sync_state);
    if (raw->has_next_sync != 0) {
        status->_nextSyncInMilliseconds = @(raw->next_sync_in_ms);
    }
    if (raw->has_conflict_revision != 0) {
        status->_conflictRemoteRevision =
            [PLKRevision revisionWithRaw:raw->conflict_revision];
    }
    status->_closed = raw->closed != 0;
    return status;
}

@end

@implementation PLKCheckpointStatus {
  @public
    uint64_t _softLimitBytes;
    uint64_t _forcedLimitBytes;
    uint64_t _walBytes;
    BOOL _due;
    BOOL _scheduled;
    uint64_t _completed;
    uint64_t _failures;
}

- (uint64_t)softLimitBytes {
    return _softLimitBytes;
}

- (uint64_t)forcedLimitBytes {
    return _forcedLimitBytes;
}

- (uint64_t)walBytes {
    return _walBytes;
}

- (BOOL)due {
    return _due;
}

- (BOOL)scheduled {
    return _scheduled;
}

- (uint64_t)completed {
    return _completed;
}

- (uint64_t)failures {
    return _failures;
}

@end

@implementation PLKPrefetchStatus {
  @public
    NSString *_backgroundState;
    uint64_t _limit;
    uint64_t _active;
    uint64_t _queued;
    uint64_t _readyPages;
    uint64_t _readyBytes;
    uint64_t _policyFailures;
}

- (NSString *)backgroundState {
    return _backgroundState;
}

- (uint64_t)limit {
    return _limit;
}

- (uint64_t)active {
    return _active;
}

- (uint64_t)queued {
    return _queued;
}

- (uint64_t)readyPages {
    return _readyPages;
}

- (uint64_t)readyBytes {
    return _readyBytes;
}

- (uint64_t)policyFailures {
    return _policyFailures;
}

@end

@implementation PLKConnectionStatus {
  @public
    BOOL _transactionActive;
    PLKCheckpointStatus *_Nullable _checkpoint;
    PLKPrefetchStatus *_Nullable _prefetch;
    BOOL _closed;
}

- (BOOL)transactionActive {
    return _transactionActive;
}

- (PLKCheckpointStatus *)checkpoint {
    return _checkpoint;
}

- (PLKPrefetchStatus *)prefetch {
    return _prefetch;
}

- (BOOL)closed {
    return _closed;
}

@end

@implementation PLKSnapshotStatus {
  @public
    PLKRevision *_revision;
    uint64_t _localBytes;
    BOOL _closed;
}

- (PLKRevision *)revision {
    return _revision;
}

- (uint64_t)localBytes {
    return _localBytes;
}

- (BOOL)closed {
    return _closed;
}

@end

@implementation PLKRemoteStatus {
  @public
    NSNumber *_Nullable _retainedRevisions;
    BOOL _maintenancePending;
    uint64_t _policyFailures;
    BOOL _closed;
}

- (NSNumber *)retainedRevisions {
    return _retainedRevisions;
}

- (BOOL)maintenancePending {
    return _maintenancePending;
}

- (uint64_t)policyFailures {
    return _policyFailures;
}

- (BOOL)closed {
    return _closed;
}

@end

@implementation PLKCheckpointResult {
  @public
    int32_t _logFrames;
    int32_t _checkpointedFrames;
}

- (int32_t)logFrames {
    return _logFrames;
}

- (int32_t)checkpointedFrames {
    return _checkpointedFrames;
}

@end

@implementation PLKKeyRotationReport {
  @public
    PLKRevision *_sourceRevision;
    PLKRevision *_targetRevision;
    PLKRevision *_Nullable _sourceKeyID;
    PLKRevision *_targetKeyID;
    uint64_t _pieceCount;
    BOOL _published;
}

- (PLKRevision *)sourceRevision {
    return _sourceRevision;
}

- (PLKRevision *)targetRevision {
    return _targetRevision;
}

- (PLKRevision *)sourceKeyID {
    return _sourceKeyID;
}

- (PLKRevision *)targetKeyID {
    return _targetKeyID;
}

- (uint64_t)pieceCount {
    return _pieceCount;
}

- (BOOL)published {
    return _published;
}

@end

@implementation PLKStorageAdapter {
  @public
    void *_pointer;
    id _Nullable _owner;
}

+ (instancetype)adapterRetainingPointer:(void *)adapterPointer
                                  owner:(id)owner
                                  error:(NSError **)error {
    if (adapterPointer == NULL) {
        PLKFail(error,
                PLKInvalidArgument(
                    @"storage adapter pointer must not be null",
                    @"Supply a live native bucket adapter and retry."));
        return nil;
    }
    PLKStorageAdapter *adapter = [[PLKStorageAdapter alloc] init];
    adapter->_pointer = adapterPointer;
    adapter->_owner = owner;
    return adapter;
}

+ (instancetype)borrowedAdapterWithPointer:(void *)adapterPointer
                                     error:(NSError **)error {
    return [PLKStorageAdapter adapterRetainingPointer:adapterPointer
                                                owner:nil
                                                error:error];
}

@end

typedef int32_t (*PLKQueryFunction)(uint64_t, PotluckDbSliceV1,
                                    const PotluckDbBindingsV1 *, uint32_t,
                                    PotluckDbRowsHandleV1 *,
                                    PotluckDbErrorV1 *);
typedef int32_t (*PLKExecuteFunction)(uint64_t, PotluckDbSliceV1,
                                      const PotluckDbBindingsV1 *,
                                      PotluckDbExecuteResultV1 *, uint32_t,
                                      PotluckDbErrorV1 *);

static PLKRows *_Nullable PLKRunQuery(PLKHandleState *state,
                                      PLKQueryFunction function,
                                      NSString *sql,
                                      PLKBindings *_Nullable bindings,
                                      PLKQueryEngine engine,
                                      NSError **error);
static PLKExecuteResult *_Nullable PLKRunExecute(
    PLKHandleState *state, PLKExecuteFunction function, NSString *sql,
    PLKBindings *_Nullable bindings, NSError **error);

@implementation PLKTransaction {
  @public
    PLKHandleState *_state;
}

+ (instancetype)transactionWithHandle:(uint64_t)handle
                                owner:(PLKHandleState *)owner {
    PLKTransaction *transaction = [[PLKTransaction alloc] init];
    transaction->_state =
        [[PLKHandleState alloc] initWithKind:PLKOwnerKindTransaction
                                      handle:handle
                                    closable:NO
                                    retained:owner];
    return transaction;
}

// The three-segment selector is the four-segment one with the default
// engine. Written this way rather than as two calls into PLKRunQuery so
// there is one place per owner where the engine can be lost.
- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return [self query:sql
              bindings:bindings
                engine:PLKQueryEngineSqlite
                 error:error];
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                       engine:(PLKQueryEngine)engine
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_transaction_query_with_engine_v1, sql, bindings,
                       engine, error);
}

- (PLKExecuteResult *)execute:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunExecute(_state, potluckdb_transaction_execute_v1, sql,
                         bindings, error);
}

- (BOOL)commitWithError:(NSError **)error {
    BOOL committed = [_state withHandle:^BOOL(uint64_t handle,
                                              NSError **bodyError) {
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        return PLKCheck(potluckdb_transaction_commit_v1(handle, &failure),
                        &failure, bodyError);
    }
                                  error:error];
    if (!committed) {
        return NO;
    }
    return [_state releaseUsing:potluckdb_transaction_release_v1 error:error];
}

- (void)rollbackQuietly {
    // Rollback failures must not mask the original transaction failure.
    (void)[_state withHandle:^BOOL(uint64_t handle, NSError **bodyError) {
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        return PLKCheck(potluckdb_transaction_rollback_v1(handle, &failure),
                        &failure, bodyError);
    }
                       error:NULL];
    (void)[_state releaseUsing:potluckdb_transaction_release_v1 error:NULL];
}

@end

static PLKRows *_Nullable PLKRunQuery(PLKHandleState *state,
                                      PLKQueryFunction function,
                                      NSString *sql,
                                      PLKBindings *_Nullable bindings,
                                      PLKQueryEngine engine,
                                      NSError **error) {
    // Before the handle, so all four readers refuse identically and a
    // refusal does not depend on the session being open.
    uint32_t selector = POTLUCKDB_QUERY_SQLITE_V1;
    NSError *refused = PLKEngineSelector(engine, &selector);
    if (refused != nil) {
        (void)PLKFail(error, refused);
        return nil;
    }
    PLKBindings *selected = bindings != nil ? bindings : [PLKBindings none];
    NSData *encoded = PLKUtf8(sql);
    if (encoded == nil) {
        PLKFail(error, PLKUnencodableText());
        return nil;
    }
    __block PLKRows *rows = nil;
    BOOL outcome = [state withHandle:^BOOL(uint64_t handle,
                                           NSError **bodyError) {
        return [selected withRaw:^BOOL(const PotluckDbBindingsV1 *raw,
                                       NSError **innerError) {
            PotluckDbRowsHandleV1 output = 0;
            PotluckDbErrorV1 failure;
            potluckdb_error_init_v1(&failure);
            if (!PLKCheck(function(handle, PLKSliceFromData(encoded), raw, selector,
                                   &output, &failure),
                          &failure, innerError)) {
                return NO;
            }
            rows = PLKCopyRows(output, innerError);
            return rows != nil;
        }
                            error:bodyError];
    }
                              error:error];
    return outcome ? rows : nil;
}

static PLKExecuteResult *_Nullable PLKRunExecute(
    PLKHandleState *state, PLKExecuteFunction function, NSString *sql,
    PLKBindings *_Nullable bindings, NSError **error) {
    PLKBindings *selected = bindings != nil ? bindings : [PLKBindings none];
    NSData *encoded = PLKUtf8(sql);
    if (encoded == nil) {
        PLKFail(error, PLKUnencodableText());
        return nil;
    }
    __block PLKExecuteResult *result = nil;
    BOOL outcome = [state withHandle:^BOOL(uint64_t handle,
                                           NSError **bodyError) {
        return [selected withRaw:^BOOL(const PotluckDbBindingsV1 *raw,
                                       NSError **innerError) {
            PotluckDbExecuteResultV1 output;
            potluckdb_execute_result_init_v1(&output);
            PotluckDbErrorV1 failure;
            potluckdb_error_init_v1(&failure);
            if (!PLKCheck(function(handle, PLKSliceFromData(encoded), raw,
                                   &output, (uint32_t)sizeof(output), &failure),
                          &failure, innerError)) {
                return NO;
            }
            result = [[PLKExecuteResult alloc] init];
            result->_rowsAffected = output.rows_affected;
            if (output.has_last_insert_id != 0) {
                result->_lastInsertID = @(output.last_insert_id);
            }
            return YES;
        }
                            error:bodyError];
    }
                              error:error];
    return outcome ? result : nil;
}

typedef int32_t (*PLKTransactionBeginFunction)(uint64_t, uint32_t, uint64_t *,
                                               PotluckDbErrorV1 *);

static BOOL PLKRunTransaction(PLKHandleState *owner,
                              PLKTransactionBeginFunction begin,
                              PLKTransactionMode mode,
                              NSError **error,
                              BOOL (^block)(PLKTransaction *transaction,
                                            NSError **blockError)) {
    if (mode != PLKTransactionModeDeferred && mode != PLKTransactionModeImmediate &&
        mode != PLKTransactionModeExclusive) {
        return PLKFail(error, PLKInvalidArgument(@"transaction mode is invalid",
            @"Use deferred, immediate, or exclusive transaction mode."));
    }
    __block uint64_t transactionHandle = 0;
    BOOL began = [owner withHandle:^BOOL(uint64_t handle, NSError **bodyError) {
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        return PLKCheck(
            begin(handle, (uint32_t)mode, &transactionHandle, &failure),
            &failure, bodyError);
    }
                             error:error];
    if (!began) {
        return NO;
    }
    PLKTransaction *transaction =
        [PLKTransaction transactionWithHandle:transactionHandle owner:owner];
    NSError *blockFailure = nil;
    BOOL blockSuccess = NO;
    @try {
        blockSuccess = block(transaction, &blockFailure);
    } @catch (NSException *exception) {
        [transaction rollbackQuietly];
        @throw;
    }
    if (!blockSuccess) {
        [transaction rollbackQuietly];
        NSError *reported =
            blockFailure != nil
                ? blockFailure
                : PLKInternalFailure(
                      @"the transaction block failed without an error");
        return PLKFail(error, reported);
    }
    if (![transaction commitWithError:error]) {
        [transaction rollbackQuietly];
        return NO;
    }
    return YES;
}

@implementation PLKConnection {
  @public
    PLKHandleState *_state;
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return [self query:sql
              bindings:bindings
                engine:PLKQueryEngineSqlite
                 error:error];
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                       engine:(PLKQueryEngine)engine
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_connection_query_with_engine_v1, sql, bindings,
                       engine, error);
}

- (PLKExecuteResult *)execute:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunExecute(_state, potluckdb_connection_execute_v1, sql, bindings,
                         error);
}

- (BOOL)transactionWithMode:(PLKTransactionMode)mode
                      error:(NSError **)error
                      block:(BOOL (^)(PLKTransaction *, NSError **))block {
    return PLKRunTransaction(_state, potluckdb_connection_transaction_begin_v1,
                             mode, error, block);
}

- (PLKCheckpointResult *)checkpointWithError:(NSError **)error {
    __block PLKCheckpointResult *result = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbCheckpointResultV1 output;
        potluckdb_checkpoint_result_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_connection_checkpoint_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        result = [[PLKCheckpointResult alloc] init];
        result->_logFrames = output.log_frames;
        result->_checkpointedFrames = output.checkpointed_frames;
        return YES;
    }
                                error:error];
    return outcome ? result : nil;
}

- (PLKConnectionStatus *)statusWithError:(NSError **)error {
    __block PLKConnectionStatus *status = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbConnectionStatusV1 output;
        potluckdb_connection_status_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_connection_status_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        status = [[PLKConnectionStatus alloc] init];
        status->_transactionActive = output.transaction_active != 0;
        status->_closed = output.closed != 0;
        if (output.has_checkpoint != 0) {
            PLKCheckpointStatus *checkpoint =
                [[PLKCheckpointStatus alloc] init];
            checkpoint->_softLimitBytes = output.checkpoint.soft_limit_bytes;
            checkpoint->_forcedLimitBytes =
                output.checkpoint.forced_checkpoint_threshold_bytes;
            checkpoint->_walBytes = output.checkpoint.wal_bytes;
            checkpoint->_due = output.checkpoint.due != 0;
            checkpoint->_scheduled = output.checkpoint.scheduled != 0;
            checkpoint->_completed = output.checkpoint.completed;
            checkpoint->_failures = output.checkpoint.failures;
            status->_checkpoint = checkpoint;
        }
        if (output.has_prefetch != 0) {
            PLKPrefetchStatus *prefetch = [[PLKPrefetchStatus alloc] init];
            prefetch->_backgroundState =
                PLKBackgroundStateName(output.prefetch.background_state);
            prefetch->_limit = output.prefetch.limit;
            prefetch->_active = output.prefetch.active;
            prefetch->_queued = output.prefetch.queued;
            prefetch->_readyPages = output.prefetch.ready_pages;
            prefetch->_readyBytes = output.prefetch.ready_bytes;
            prefetch->_policyFailures = output.prefetch.policy_failures;
            status->_prefetch = prefetch;
        }
        return YES;
    }
                                error:error];
    return outcome ? status : nil;
}

- (BOOL)closeWithError:(NSError **)error {
    return [_state closeUsing:potluckdb_connection_close_v1 error:error];
}

@end

@implementation PLKSnapshot {
  @public
    PLKHandleState *_state;
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return [self query:sql
              bindings:bindings
                engine:PLKQueryEngineSqlite
                 error:error];
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                       engine:(PLKQueryEngine)engine
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_snapshot_query_with_engine_v1, sql, bindings,
                       engine, error);
}

- (PLKSnapshotStatus *)statusWithError:(NSError **)error {
    __block PLKSnapshotStatus *status = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbSnapshotStatusV1 output;
        potluckdb_snapshot_status_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_snapshot_status_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        status = [[PLKSnapshotStatus alloc] init];
        status->_revision = [PLKRevision revisionWithRaw:output.revision];
        status->_localBytes = output.local_bytes;
        status->_closed = output.closed != 0;
        return YES;
    }
                                error:error];
    return outcome ? status : nil;
}

- (BOOL)closeWithError:(NSError **)error {
    return [_state closeUsing:potluckdb_snapshot_close_v1 error:error];
}

@end

@implementation PLKRemote {
  @public
    PLKHandleState *_state;
}

+ (instancetype)remoteFromDirectory:(NSString *)path
                            options:(PLKRemoteOptions *)options
                              error:(NSError **)error {
    PLKRemoteOptions *selected =
        options != nil ? options : [[PLKRemoteOptions alloc] init];
    PotluckDbRemoteOptionsV1 raw;
    if (![selected fill:&raw error:error]) {
        return nil;
    }
    NSData *encoded = PLKUtf8(path);
    if (encoded == nil) {
        PLKFail(error, PLKUnencodableText());
        return nil;
    }
    PotluckDbRemoteHandleV1 handle = 0;
    PotluckDbErrorV1 failure;
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_remote_from_directory_v1(PLKSliceFromData(encoded),
                                                     &raw, &handle, &failure),
                  &failure, error)) {
        return nil;
    }
    PLKRemote *remote = [[PLKRemote alloc] init];
    remote->_state = [[PLKHandleState alloc] initWithKind:PLKOwnerKindRemote
                                                   handle:handle
                                                 closable:YES
                                                 retained:nil];
    return remote;
}

+ (instancetype)remoteFromStorage:(PLKStorageAdapter *)storage
                          options:(PLKRemoteOptions *)options
                            error:(NSError **)error {
    if (storage == nil || storage->_pointer == NULL) {
        PLKFail(error,
                PLKInvalidArgument(@"storage must not be nil",
                                   @"Supply a storage adapter and retry."));
        return nil;
    }
    PLKRemoteOptions *selected =
        options != nil ? options : [[PLKRemoteOptions alloc] init];
    PotluckDbRemoteOptionsV1 raw;
    if (![selected fill:&raw error:error]) {
        return nil;
    }
    PotluckDbRemoteHandleV1 handle = 0;
    PotluckDbErrorV1 failure;
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_remote_from_storage_v1(
                      (const PotluckDbRuntimeBucketAdapterV1 *)storage->_pointer,
                      &raw, &handle, &failure),
                  &failure, error)) {
        return nil;
    }
    PLKRemote *remote = [[PLKRemote alloc] init];
    remote->_state = [[PLKHandleState alloc] initWithKind:PLKOwnerKindRemote
                                                   handle:handle
                                                 closable:YES
                                                 retained:storage];
    return remote;
}

- (PLKRemoteStatus *)statusWithError:(NSError **)error {
    __block PLKRemoteStatus *status = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbRemoteStatusV1 output;
        potluckdb_remote_status_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_remote_status_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        status = [[PLKRemoteStatus alloc] init];
        if (output.has_retained_revisions != 0) {
            status->_retainedRevisions = @(output.retained_revisions);
        }
        status->_maintenancePending = output.maintenance_pending != 0;
        status->_policyFailures = output.policy_failures;
        status->_closed = output.closed != 0;
        return YES;
    }
                                error:error];
    return outcome ? status : nil;
}

- (PLKCollectionReport *)collect:(PLKRetentionPolicy *)retention
                           error:(NSError **)error {
    if (retention == nil) {
        PLKFail(error, PLKInvalidArgument(
            @"collect needs an explicit retention policy",
            @"Pass [PLKRetentionPolicy boundedPolicy]."));
        return nil;
    }
    PLKRetentionPolicy *selected = retention;
    if (!selected.bounded) {
        PLKFail(error, PLKInvalidArgument(
            @"collect needs a bounded retention policy",
            @"Pass [PLKRetentionPolicy boundedPolicy]."));
        return nil;
    }
    __block PLKCollectionReport *report = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbRetentionPolicyV1 raw;
        [selected fill:&raw];
        PotluckDbCollectionReportV1 output;
        potluckdb_collection_report_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_remote_collect_v1(handle, &raw, &output,
                                                  (uint32_t)sizeof(output),
                                                  &failure),
                      &failure, bodyError)) {
            return NO;
        }
        report = [PLKCollectionReport reportWithRaw:&output];
        return YES;
    }
                                error:error];
    return outcome ? report : nil;
}

- (PLKCollectionReport *)recoverAbandonedCollectionWithError:(NSError **)error {
    __block PLKCollectionReport *report = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbCollectionReportV1 output;
        potluckdb_collection_report_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_remote_recover_abandoned_collection_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        report = [PLKCollectionReport reportWithRaw:&output];
        return YES;
    }
                                error:error];
    return outcome ? report : nil;
}

- (BOOL)closeWithError:(NSError **)error {
    return [_state closeUsing:potluckdb_remote_close_v1 error:error];
}

@end

// Review round 19 BN-03: a Remote this library did not open, nil or
// [[PLKRemote alloc] init], has no handle, and reaching through it would end
// the process; it is refused as a caller error instead.
static BOOL PLKRequireOpenedRemote(PLKRemote *_Nullable remote,
                                   NSError **error) {
    if (remote != nil && remote->_state != nil) {
        return YES;
    }
    return PLKFail(error,
                   PLKInvalidArgument(
                       @"remote was not opened by this library",
                       @"Open the remote with remoteFromDirectory, "
                       @"remoteFromStorage or a storage factory and retry."));
}

@implementation PLKDatabase {
  @public
    PLKHandleState *_state;
}

+ (instancetype)openAtPath:(NSString *)path
                    remote:(PLKRemote *)remote
                   options:(PLKOpenOptions *)options
                     error:(NSError **)error {
    if (remote != nil && !PLKRequireOpenedRemote(remote, error)) {
        return nil;
    }
    PLKOpenOptions *selected =
        options != nil ? options : [[PLKOpenOptions alloc] init];
    PotluckDbOpenOptionsV1 raw;
    __attribute__((objc_precise_lifetime)) NSData *clientIdentity = nil;
    __attribute__((objc_precise_lifetime)) NSData *licenseKey = nil;
    __attribute__((objc_precise_lifetime)) NSData *analyticalEngine = nil;
    if (![selected fill:&raw clientIdentity:&clientIdentity
            licenseKey:&licenseKey analyticalEngine:&analyticalEngine error:error]) {
        return nil;
    }
    NSData *encoded = PLKUtf8(path);
    if (encoded == nil) {
        PLKFail(error, PLKUnencodableText());
        return nil;
    }
    PLKSyncHook *hook = nil;
    if (selected.onSync != nil) {
        hook = [[PLKSyncHook alloc] init];
        hook->_block = selected.onSync;
        raw.on_sync = PLKDeliverSync;
        raw.on_sync_context = (__bridge void *)hook;
    }
    __block PotluckDbDatabaseHandleV1 handle = 0;
    BOOL (^open)(uint64_t, NSError **) = ^BOOL(uint64_t remoteHandle,
                                               NSError **bodyError) {
        PotluckDbOpenOptionsV1 callOptions = raw;
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        return PLKCheck(potluckdb_open_v1(PLKSliceFromData(encoded),
                                          remoteHandle, &callOptions, &handle,
                                          &failure),
                        &failure, bodyError);
    };
    BOOL opened;
    id retained = hook;
    if (remote == nil) {
        opened = open(0, error);
    } else {
        retained = hook == nil ? remote->_state : @[ remote->_state, hook ];
        opened = [remote->_state withHandle:open error:error];
    }
    (void)clientIdentity;
    if (!opened) {
        return nil;
    }
    PLKDatabase *database = [[PLKDatabase alloc] init];
    database->_state = [[PLKHandleState alloc] initWithKind:PLKOwnerKindDatabase
                                                     handle:handle
                                                   closable:YES
                                                   retained:retained];
    return database;
}

+ (PLKSnapshot *)openRevisionAtPath:(NSString *)path
                           revision:(PLKRevision *)revision
                             remote:(PLKRemote *)remote
                            options:(PLKOpenOptions *)options
                              error:(NSError **)error {
    if (revision == nil) {
        PLKFail(error, PLKInvalidArgument(@"revision must not be nil",
                                          @"Supply a revision and retry."));
        return nil;
    }
    if (!PLKRequireOpenedRemote(remote, error)) {
        return nil;
    }
    PLKOpenOptions *selected =
        options != nil ? options : [[PLKOpenOptions alloc] init];
    PotluckDbOpenOptionsV1 raw;
    __attribute__((objc_precise_lifetime)) NSData *clientIdentity = nil;
    __attribute__((objc_precise_lifetime)) NSData *licenseKey = nil;
    __attribute__((objc_precise_lifetime)) NSData *analyticalEngine = nil;
    if (![selected fill:&raw clientIdentity:&clientIdentity
            licenseKey:&licenseKey analyticalEngine:&analyticalEngine error:error]) {
        return nil;
    }
    NSData *encoded = PLKUtf8(path);
    if (encoded == nil) {
        PLKFail(error, PLKUnencodableText());
        return nil;
    }
    PotluckDbRevisionV1 rawRevision = [revision raw];
    __block PotluckDbSnapshotHandleV1 handle = 0;
    BOOL opened = [remote->_state withHandle:^BOOL(uint64_t remoteHandle,
                                                   NSError **bodyError) {
        PotluckDbOpenOptionsV1 callOptions = raw;
        PotluckDbRevisionV1 callRevision = rawRevision;
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        return PLKCheck(
            potluckdb_open_revision_v1(PLKSliceFromData(encoded), &callRevision,
                                       remoteHandle, &callOptions, &handle,
                                       &failure),
            &failure, bodyError);
    }
                                       error:error];
    (void)clientIdentity;
    if (!opened) {
        return nil;
    }
    PLKSnapshot *snapshot = [[PLKSnapshot alloc] init];
    snapshot->_state = [[PLKHandleState alloc] initWithKind:PLKOwnerKindSnapshot
                                                     handle:handle
                                                   closable:YES
                                                   retained:remote->_state];
    return snapshot;
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return [self query:sql
              bindings:bindings
                engine:PLKQueryEngineSqlite
                 error:error];
}

- (PLKRows *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                       engine:(PLKQueryEngine)engine
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_database_query_with_engine_v1, sql, bindings,
                       engine, error);
}

- (PLKExecuteResult *)execute:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunExecute(_state, potluckdb_database_execute_v1, sql, bindings,
                         error);
}

- (BOOL)transactionWithMode:(PLKTransactionMode)mode
                      error:(NSError **)error
                      block:(BOOL (^)(PLKTransaction *, NSError **))block {
    return PLKRunTransaction(_state, potluckdb_database_transaction_begin_v1,
                             mode, error, block);
}

- (PLKConnection *)connect:(PLKConnectionOptions *)options
                     error:(NSError **)error {
    PLKConnectionOptions *selected =
        options != nil ? options : [[PLKConnectionOptions alloc] init];
    PotluckDbConnectionOptionsV1 raw;
    if (![selected fill:&raw error:error]) {
        return nil;
    }
    __block PotluckDbConnectionHandleV1 handle = 0;
    BOOL opened = [_state withHandle:^BOOL(uint64_t databaseHandle,
                                           NSError **bodyError) {
        PotluckDbConnectionOptionsV1 callOptions = raw;
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        return PLKCheck(potluckdb_database_connect_v1(databaseHandle,
                                                      &callOptions, &handle,
                                                      &failure),
                        &failure, bodyError);
    }
                               error:error];
    if (!opened) {
        return nil;
    }
    PLKConnection *connection = [[PLKConnection alloc] init];
    connection->_state =
        [[PLKHandleState alloc] initWithKind:PLKOwnerKindConnection
                                      handle:handle
                                    closable:YES
                                    retained:_state];
    return connection;
}

- (PLKSyncResult *)syncWithError:(NSError **)error {
    __block PLKSyncResult *result = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbSyncResultV1 output;
        potluckdb_sync_result_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_database_sync_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        result = PLKSyncResultFromRaw(&output, bodyError);
        (void)potluckdb_sync_result_release_v1(&output);
        return result != nil;
    }
                                error:error];
    return outcome ? result : nil;
}

- (PLKConflictResolution *)resolveConflictWithError:(NSError **)error {
    __block PLKConflictResolution *resolution = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbConflictResolutionV1 output;
        potluckdb_conflict_resolution_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_database_resolve_conflict_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        resolution = [[PLKConflictResolution alloc] init];
        resolution->_revision = [PLKRevision revisionWithRaw:output.revision];
        resolution->_alreadyPublished =
            PLKCopyStrings(output.already_published, bodyError);
        resolution->_replayed =
            resolution->_alreadyPublished == nil
                ? nil
                : PLKCopyStrings(output.replayed, bodyError);
        resolution->_quarantined =
            resolution->_replayed == nil
                ? nil
                : PLKCopyStrings(output.quarantined, bodyError);
        resolution->_pending = resolution->_quarantined == nil
                                   ? nil
                                   : PLKCopyStrings(output.pending, bodyError);
        BOOL converted = resolution->_pending != nil;
        (void)potluckdb_conflict_resolution_release_v1(&output);
        return converted;
    }
                                error:error];
    return outcome ? resolution : nil;
}

- (PLKDatabaseStatus *)setSyncPolicy:(PLKSyncPolicy *)policy
                               error:(NSError **)error {
    __block PLKDatabaseStatus *status = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbSyncPolicyV1 raw;
        [policy fill:&raw];
        PotluckDbDatabaseStatusV1 output;
        potluckdb_database_status_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_database_set_sync_policy_v1(
                          handle, &raw, &output, (uint32_t)sizeof(output),
                          &failure),
                      &failure, bodyError)) {
            return NO;
        }
        status = [PLKDatabaseStatus statusWithRaw:&output];
        return YES;
    }
                                error:error];
    return outcome ? status : nil;
}

- (NSNumber *)clearQuarantineRecordsWithError:(NSError **)error {
    __block NSNumber *count = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        uint64_t output = 0;
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_database_clear_quarantine_records_v1(
                          handle, &output, &failure),
                      &failure, bodyError)) {
            return NO;
        }
        count = @(output);
        return YES;
    }
                                error:error];
    return outcome ? count : nil;
}

- (PLKDatabaseStatus *)statusWithError:(NSError **)error {
    __block PLKDatabaseStatus *status = nil;
    BOOL outcome = [_state withHandle:^BOOL(uint64_t handle,
                                            NSError **bodyError) {
        PotluckDbDatabaseStatusV1 output;
        potluckdb_database_status_init_v1(&output);
        PotluckDbErrorV1 failure;
        potluckdb_error_init_v1(&failure);
        if (!PLKCheck(potluckdb_database_status_v1(
                          handle, &output, (uint32_t)sizeof(output), &failure),
                      &failure, bodyError)) {
            return NO;
        }
        status = [PLKDatabaseStatus statusWithRaw:&output];
        return YES;
    }
                                error:error];
    return outcome ? status : nil;
}

- (BOOL)closeWithError:(NSError **)error {
    return [_state closeUsing:potluckdb_database_close_v1 error:error];
}

@end

@implementation PLKAdmin

+ (PLKKeyRotationReport *)reencryptFromRemote:(PLKRemote *)source
                                     toRemote:(PLKRemote *)target
                                       newKey:(NSData *)newKey
                                    sourceKey:(NSData *)sourceKey
                                     revision:(PLKRevision *)revision
                                        error:(NSError **)error {
    if (newKey.length != 32) {
        PLKFail(error,
                PLKInvalidArgument(@"encryption key must contain exactly 32 bytes",
                                   @"Supply a 32-byte key and retry."));
        return nil;
    }
    if (sourceKey != nil && sourceKey.length != 32) {
        PLKFail(error,
                PLKInvalidArgument(
                    @"source encryption key must contain exactly 32 bytes",
                    @"Supply a 32-byte key and retry."));
        return nil;
    }
    if (!PLKRequireOpenedRemote(source, error) ||
        !PLKRequireOpenedRemote(target, error)) {
        return nil;
    }
    if (source == target) {
        PLKFail(error,
                PLKInvalidArgument(
                    @"source and target must be distinct Remote values",
                    @"Open a distinct target Remote and retry."));
        return nil;
    }
    PotluckDbReencryptOptionsV1 options;
    potluckdb_reencrypt_options_init_v1(&options);
    [newKey getBytes:options.new_key length:32];
    if (sourceKey != nil) {
        options.flags |= POTLUCKDB_REENCRYPT_SOURCE_KEY_V1;
        [sourceKey getBytes:options.source_key length:32];
    }
    if (revision != nil) {
        options.flags |= POTLUCKDB_REENCRYPT_REVISION_V1;
        options.revision = [revision raw];
    }
    __block PLKKeyRotationReport *report = nil;
    BOOL outcome = [source->_state
        withPair:target->_state
            body:^BOOL(uint64_t left, uint64_t right, NSError **bodyError) {
                PotluckDbReencryptOptionsV1 callOptions = options;
                PotluckDbKeyRotationReportV1 output;
                potluckdb_key_rotation_report_init_v1(&output);
                PotluckDbErrorV1 failure;
                potluckdb_error_init_v1(&failure);
                if (!PLKCheck(potluckdb_admin_reencrypt_v1(
                                  left, right, &callOptions, &output,
                                  (uint32_t)sizeof(output), &failure),
                              &failure, bodyError)) {
                    return NO;
                }
                report = [[PLKKeyRotationReport alloc] init];
                report->_sourceRevision =
                    [PLKRevision revisionWithRaw:output.source_revision];
                report->_targetRevision =
                    [PLKRevision revisionWithRaw:output.target_revision];
                if (output.has_source_key_id != 0) {
                    report->_sourceKeyID =
                        [PLKRevision revisionWithRaw:output.source_key_id];
                }
                report->_targetKeyID =
                    [PLKRevision revisionWithRaw:output.target_key_id];
                report->_pieceCount = output.piece_count;
                report->_published = output.published != 0;
                return YES;
            }
           error:error];
    return outcome ? report : nil;
}

@end

// --- Remotes over object storage ---------------------------------------
//
// `PLKRemote remoteFromStorage:` above takes a bucket the application
// implements. What follows takes a bucket nobody implements: the
// semantics, the HTTP and every provider's credential chain live in
// `potluckdb-storage`, one native library that every SDK loads, and all
// this does is find it, hand it a JSON configuration, and give the
// function table it answers with to `remoteFromStorage:`.
//
// Six of the functions below are deliberately not static. The
// conformance beside this file links against them and drives them
// directly, because the exact bytes of the document are the contract
// with the library: a facade that spells a field wrong is invisible from
// the outside until something is listening on the other end.

enum { PLKStorageAbiVersionV1 = 1, PLKStorageOkV1 = 0 };

// The storage library's own ABI, restated. It is in neither C header --
// `potluckdb.h` is the application ABI and `potluckdb_runtime.h` is the
// runtime interface -- because the storage library is a third thing,
// loaded rather than linked. Every SDK restates these two structures.
typedef struct {
    const uint8_t *data;
    uint64_t length;
} PLKStorageSliceV1;

typedef struct {
    uint32_t struct_size;
    uint32_t abi_version;
    PLKStorageSliceV1 message;
} PLKStorageErrorV1;

typedef uint32_t (*PLKStorageAbiVersionFunction)(void);
typedef uint32_t (*PLKStorageErrorSizeFunction)(void);
typedef int32_t (*PLKStorageReleaseErrorFunction)(PLKStorageErrorV1 *);
typedef int32_t (*PLKStorageReleaseAdapterFunction)(
    const PotluckDbRuntimeBucketAdapterV1 *);
typedef int32_t (*PLKStorageCreateFunction)(
    PLKStorageSliceV1,
    const PotluckDbRuntimeBucketAdapterV1 **,
    PLKStorageErrorV1 *);

typedef struct {
    void *handle;
    PLKStorageReleaseErrorFunction releaseError;
    PLKStorageReleaseAdapterFunction releaseAdapter;
} PLKStorageLibrary;

/// Every provider the storage library builds, and the entry point that
/// builds it.
///
/// Closed on purpose: a provider is not a string this SDK forwards to
/// `dlsym`, it is one of three things the library is known to export. A
/// name outside this map is refused here, before anything is loaded,
/// rather than becoming a symbol lookup that fails in the loader's
/// wording instead of this SDK's.
NSDictionary<NSString *, NSString *> *PLKStorageEntryPoints(void) {
    static NSDictionary<NSString *, NSString *> *entries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        entries = @{
            @"s3" : @"potluckdb_storage_s3_create_v1",
            @"gcs" : @"potluckdb_storage_gcs_create_v1",
            @"azure" : @"potluckdb_storage_azure_create_v1",
        };
    });
    return entries;
}

static NSString *PLKStorageDefaultLibraryName(void) {
#if defined(__APPLE__)
    return @"libpotluckdb_storage.dylib";
#else
    return @"libpotluckdb_storage.so";
#endif
}

/// Where the storage library is for this process.
///
/// `POTLUCKDB_STORAGE_LIBRARY` first, because someone who named a library
/// meant that one. Then beside the running executable, and in the
/// `Frameworks` directory of the bundle the executable is in, which is
/// where an application's libraries ship -- there is no Objective-C
/// equivalent of the `potluckdb-storage` wheel. Otherwise the platform's
/// own name, which lets the loader search wherever it searches.
///
/// `getenv` rather than `NSProcessInfo`, whose environment dictionary is
/// a snapshot: a process that set the variable on itself would read back
/// what was there before it did.
static NSString *PLKStorageLibraryPath(void) {
    const char *named = getenv("POTLUCKDB_STORAGE_LIBRARY");
    if (named != NULL && named[0] != '\0') {
        NSString *decoded = [NSString stringWithUTF8String:named];
        if (decoded.length > 0) {
            return decoded;
        }
    }
    NSString *name = PLKStorageDefaultLibraryName();
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSURL *executable = NSBundle.mainBundle.executableURL;
    NSString *beside =
        [executable.URLByDeletingLastPathComponent URLByAppendingPathComponent:name].path;
    if (beside != nil) {
        [candidates addObject:beside];
    }
    NSString *framework = [NSBundle.mainBundle.privateFrameworksURL
        URLByAppendingPathComponent:@"PotluckDBStorage.framework/PotluckDBStorage"].path;
    if (framework != nil) {
        [candidates addObject:framework];
    }
    NSString *frameworks =
        [NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:name].path;
    if (frameworks != nil) {
        [candidates addObject:frameworks];
    }
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return name;
}

static NSError *PLKStorageUnavailable(NSString *message) {
    return PLKMakeError(
        @"storage_library_unavailable", PLKErrorCategoryPermanent, message,
        @"Ship libpotluckdb_storage inside the application bundle, or set "
        @"POTLUCKDB_STORAGE_LIBRARY to one already on this machine.");
}

/// A provider this SDK has no entry point for.
///
/// Answered before the library is looked for, because the map above is
/// this SDK's own knowledge and a caller who mistyped a provider should
/// read that back rather than a complaint about an absent install.
static NSError *PLKStorageUnknownProvider(NSString *provider) {
    return PLKMakeError(
        @"storage_library_unavailable", PLKErrorCategoryPermanent,
        [NSString stringWithFormat:
                      @"provider \"%@\" is not one this SDK can load. "
                      @"The storage library provides \"s3\", \"gcs\", and "
                      @"\"azure\".",
                      provider],
        @"Correct the provider name and retry.");
}

/// A provider this SDK knows, absent from the library it loaded.
///
/// The ordinary cause is an older storage library on the machine than the
/// one this SDK was built against -- the provider was added after it was
/// built -- so the remedy is the library, not the call.
NSError *PLKStorageMissingEntryPoint(NSString *provider, NSString *symbol) {
    return PLKMakeError(
        @"storage_library_unavailable", PLKErrorCategoryPermanent,
        [NSString stringWithFormat:
                      @"the storage library does not export \"%@\". It may "
                      @"predate provider \"%@\"; update the potluckdb storage "
                      @"library.",
                      symbol, provider],
        @"Ship a libpotluckdb_storage matching this SDK's version.");
}

/// A symbol from an open library, copied into a function pointer.
///
/// Copied rather than cast: ISO C forbids converting an object pointer to
/// a function pointer, and this file is compiled under `-Wpedantic
/// -Werror` by its own conformance. An absent symbol arrives as NULL,
/// which every caller checks.
static void PLKStorageBind(void *handle, const char *name, void *destination) {
    void *found = dlsym(handle, name);
    memcpy(destination, &found, sizeof(found));
}

static NSString *PLKStorageLoaderReason(void) {
    const char *reason = dlerror();
    if (reason == NULL) {
        return @"no reason was reported";
    }
    NSString *decoded = [NSString stringWithUTF8String:reason];
    return decoded != nil ? decoded : @"no reason was reported";
}

static BOOL PLKStorageOpen(PLKStorageLibrary *out, NSString **reason) {
    NSString *path = PLKStorageLibraryPath();
    // Cleared first: `dlerror` reports the last failure whenever it was,
    // so a stale one would be blamed on this call.
    (void)dlerror();
    void *handle = dlopen(path.UTF8String, RTLD_NOW);
    if (handle == NULL) {
        *reason = [NSString stringWithFormat:
                                @"the storage library %@ did not load: %@", path,
                                PLKStorageLoaderReason()];
        return NO;
    }

    // Every symbol every provider needs, before any of them is used. A
    // library that resolves three of four is not a usable library, and
    // finding that out at the fourth call means finding it out with an
    // adapter already built. The create functions are not here: those are
    // one per provider, resolved when one is asked for.
    PLKStorageAbiVersionFunction abiVersion = NULL;
    PLKStorageErrorSizeFunction errorSize = NULL;
    PLKStorageReleaseErrorFunction releaseError = NULL;
    PLKStorageReleaseAdapterFunction releaseAdapter = NULL;
    PLKStorageBind(handle, "potluckdb_storage_abi_version_v1", &abiVersion);
    PLKStorageBind(handle, "potluckdb_storage_error_size_v1", &errorSize);
    PLKStorageBind(handle, "potluckdb_storage_error_release_v1", &releaseError);
    PLKStorageBind(handle, "potluckdb_storage_release_v1", &releaseAdapter);
    NSDictionary<NSString *, NSNumber *> *mandatory = @{
        @"potluckdb_storage_abi_version_v1" : @(abiVersion != NULL),
        @"potluckdb_storage_error_size_v1" : @(errorSize != NULL),
        @"potluckdb_storage_error_release_v1" : @(releaseError != NULL),
        @"potluckdb_storage_release_v1" : @(releaseAdapter != NULL),
    };
    for (NSString *symbol in mandatory) {
        if (mandatory[symbol].boolValue) {
            continue;
        }
        *reason = [NSString
            stringWithFormat:@"the storage library %@ does not export %@", path,
                             symbol];
        return NO;
    }

    // Checked before anything crosses, not after something goes wrong: a
    // library from another release would fill a structure this file reads
    // at different offsets, and the first symptom would be a nonsense
    // error message rather than a refusal.
    uint32_t version = abiVersion();
    if (version != (uint32_t)PLKStorageAbiVersionV1) {
        *reason = [NSString stringWithFormat:
                                @"the storage library at %@ speaks ABI %u, not %u",
                                path, version, (uint32_t)PLKStorageAbiVersionV1];
        return NO;
    }
    if (errorSize() != (uint32_t)sizeof(PLKStorageErrorV1)) {
        *reason = [NSString
            stringWithFormat:
                @"the storage library at %@ declares a different error structure",
                path];
        return NO;
    }
    out->handle = handle;
    out->releaseError = releaseError;
    out->releaseAdapter = releaseAdapter;
    return YES;
}

/// The storage library for this process, opened at most once.
///
/// Never closed, because every table it handed out points into its code
/// and there is no moment at which the last one is known to be gone. The
/// refusal is remembered too, so a second call answers as the first did
/// rather than retrying a load already shown not to work.
static const PLKStorageLibrary *PLKStorageLoad(NSError **error) {
    static PLKStorageLibrary loaded;
    static BOOL opened;
    static NSString *refused;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *reason = nil;
        opened = PLKStorageOpen(&loaded, &reason);
        refused = reason;
    });
    if (opened) {
        return &loaded;
    }
    PLKFail(error, PLKStorageUnavailable(refused));
    return NULL;
}

/// One adapter table, given back to the library that built it.
///
/// The runtime copies the table but keeps its `context` pointer for the
/// life of the exchange, so the release has to come after the exchange is
/// closed and released. Being what the remote's handle state retains is
/// what arranges that: the state closes, releases, and only then lets ARC
/// drop what it holds. An exchange that never opened is given back by
/// hand instead, which is the same rule read from the other end.
@interface PLKStoragePackAdapter : NSObject
@end

@implementation PLKStoragePackAdapter {
    const PLKStorageLibrary *_library;
    const PotluckDbRuntimeBucketAdapterV1 *_table;
}

- (instancetype)initWithLibrary:(const PLKStorageLibrary *)library
                          table:(const PotluckDbRuntimeBucketAdapterV1 *)table {
    self = [super init];
    if (self != nil) {
        _library = library;
        _table = table;
    }
    return self;
}

/// Hand the table back, at most once.
- (void)giveBack {
    if (_table == NULL) {
        return;
    }
    const PotluckDbRuntimeBucketAdapterV1 *table = _table;
    _table = NULL;
    (void)_library->releaseAdapter(table);
}

- (void)dealloc {
    [self giveBack];
}

@end

/// A remote over whichever provider's adapter the library builds.
///
/// The one place this SDK crosses into the storage library. Everything
/// that is not the provider -- the handshake, the ownership of the
/// adapter across the exchange, the refusal the library answers a bad
/// configuration with -- is the same for all three, so it is written once
/// here and each facade supplies only its own document.
PLKRemote *_Nullable PLKStorageRemoteFromProvider(
    NSString *provider,
    NSDictionary<NSString *, id> *document,
    PLKRemoteOptions *_Nullable options,
    NSError **error) {
    NSString *symbol = PLKStorageEntryPoints()[provider];
    if (symbol == nil) {
        PLKFail(error, PLKStorageUnknownProvider(provider));
        return nil;
    }
    const PLKStorageLibrary *library = PLKStorageLoad(error);
    if (library == NULL) {
        return nil;
    }
    PLKStorageCreateFunction create = NULL;
    PLKStorageBind(library->handle, symbol.UTF8String, &create);
    if (create == NULL) {
        PLKFail(error, PLKStorageMissingEntryPoint(provider, symbol));
        return nil;
    }

    NSError *encodingFailure = nil;
    // Sorted so the bytes are the same on every run: a dictionary has no
    // order of its own, and the document is both what the library parses
    // and what this SDK's conformance compares.
    NSData *encoded =
        [NSJSONSerialization dataWithJSONObject:document
                                        options:NSJSONWritingSortedKeys
                                          error:&encodingFailure];
    if (encoded == nil) {
        PLKFail(error, PLKInternalFailure([NSString
                           stringWithFormat:@"the storage configuration could "
                                            @"not be encoded: %@",
                                            encodingFailure.localizedDescription]));
        return nil;
    }

    PLKStorageSliceV1 slice = {0};
    if (encoded.length > 0) {
        slice.data = encoded.bytes;
        slice.length = encoded.length;
    }
    const PotluckDbRuntimeBucketAdapterV1 *table = NULL;
    PLKStorageErrorV1 reported = {0};
    reported.struct_size = (uint32_t)sizeof(PLKStorageErrorV1);
    reported.abi_version = (uint32_t)PLKStorageAbiVersionV1;
    int32_t code = create(slice, &table, &reported);
    if (code != PLKStorageOkV1) {
        // Copied before the release, which is what hands the bytes back:
        // a message read afterwards is a read of memory that is no longer
        // ours.
        NSString *message = @"the storage library refused the configuration";
        if (reported.message.data != NULL && reported.message.length > 0) {
            NSString *decoded = [[NSString alloc]
                initWithBytes:reported.message.data
                       length:(NSUInteger)reported.message.length
                     encoding:NSUTF8StringEncoding];
            if (decoded != nil) {
                message = decoded;
            }
        }
        (void)library->releaseError(&reported);
        if (code == 24) {
            PLKFail(error, PLKMakeError(@"bucket_not_found", PLKErrorCategoryPermanent,
                message, @"Create the bucket or container, or correct the name the remote was configured with."));
            return nil;
        }
        PLKFail(error,
                PLKInvalidArgument(
                    message, @"Correct the storage configuration and retry."));
        return nil;
    }
    if (table == NULL) {
        PLKFail(error, PLKStorageUnavailable(
                           @"the storage library built no adapter and reported "
                           @"no reason"));
        return nil;
    }

    PLKStoragePackAdapter *owner =
        [[PLKStoragePackAdapter alloc] initWithLibrary:library table:table];
    PLKStorageAdapter *adapter =
        [PLKStorageAdapter adapterRetainingPointer:(void *)table
                                             owner:owner
                                             error:error];
    if (adapter == nil) {
        [owner giveBack];
        return nil;
    }
    PLKRemote *remote = [PLKRemote remoteFromStorage:adapter
                                             options:options
                                               error:error];
    if (remote == nil) {
        // The exchange never opened, so it is not holding the table: it
        // goes back now rather than waiting for a close that never comes.
        [owner giveBack];
        return nil;
    }
    return remote;
}

/// Whitespace, or nothing at all.
static BOOL PLKStorageBlank(NSString *value) {
    NSCharacterSet *whitespace =
        [NSCharacterSet whitespaceAndNewlineCharacterSet];
    return [value stringByTrimmingCharactersInSet:whitespace].length == 0;
}

NSDictionary<NSString *, id> *_Nullable PLKStorageS3Document(
    NSString *bucket,
    NSString *databaseNamespace,
    NSString *_Nullable region,
    NSString *_Nullable endpoint,
    BOOL forcePathStyle,
    NSString *_Nullable accessKeyID,
    NSString *_Nullable secretAccessKey,
    NSString *_Nullable sessionToken,
    NSError **error) {
    if ((accessKeyID != nil) != (secretAccessKey != nil)) {
        // Half a credential is not a credential and is not an absent one
        // either: taken as absent, the chain would answer with somebody
        // else's keys and the failure would name a permission.
        PLKFail(error,
                PLKInvalidArgument(
                    @"access_key_id and secret_access_key are given together "
                    @"or not at all",
                    @"Pass both to use explicit credentials, or neither for "
                    @"the AWS chain."));
        return nil;
    }
    NSMutableDictionary<NSString *, id> *credentials =
        [NSMutableDictionary dictionaryWithObject:@"ambient" forKey:@"mode"];
    if (accessKeyID != nil && secretAccessKey != nil) {
        credentials[@"mode"] = @"explicit";
        credentials[@"access_key_id"] = accessKeyID;
        credentials[@"secret_access_key"] = secretAccessKey;
        if (sessionToken != nil) {
            credentials[@"session_token"] = sessionToken;
        }
    }
    NSMutableDictionary<NSString *, id> *document = [@{
        @"provider" : @"s3",
        @"bucket" : bucket,
        @"namespace" : databaseNamespace,
        @"force_path_style" : @(forcePathStyle),
        @"credentials" : credentials,
    } mutableCopy];
    if (region != nil) {
        document[@"region"] = region;
    }
    if (endpoint != nil) {
        document[@"endpoint"] = endpoint;
    }
    return document;
}

NSDictionary<NSString *, id> *_Nullable PLKStorageGCSDocument(
    NSString *bucket,
    NSString *databaseNamespace,
    NSString *_Nullable endpoint,
    NSString *_Nullable serviceAccount,
    NSError **error) {
    NSMutableDictionary<NSString *, id> *credentials =
        [NSMutableDictionary dictionaryWithObject:@"ambient" forKey:@"mode"];
    if (serviceAccount != nil) {
        // An empty key is not a key and is not an absent one either: taken
        // as absent, the chain would answer with whatever identity the
        // machine carries and the failure would name a permission.
        if (PLKStorageBlank(serviceAccount)) {
            PLKFail(error,
                    PLKInvalidArgument(
                        @"service_account is a key or is absent, and is never "
                        @"empty",
                        @"Pass the service account JSON, or nothing for the "
                        @"Google chain."));
            return nil;
        }
        credentials[@"mode"] = @"explicit";
        // The key crosses as the text Google issues, carried inside one
        // JSON string: the library reads the account itself, so this file
        // never parses it and never re-emits it field by field.
        credentials[@"service_account"] = serviceAccount;
    }
    NSMutableDictionary<NSString *, id> *document = [@{
        @"provider" : @"gcs",
        @"bucket" : bucket,
        @"namespace" : databaseNamespace,
        @"credentials" : credentials,
    } mutableCopy];
    if (endpoint != nil) {
        document[@"endpoint"] = endpoint;
    }
    return document;
}

NSDictionary<NSString *, id> *_Nullable PLKStorageAzureDocument(
    NSString *account,
    NSString *container,
    NSString *databaseNamespace,
    NSString *_Nullable endpoint,
    NSString *_Nullable accountKey,
    NSError **error) {
    NSMutableDictionary<NSString *, id> *credentials =
        [NSMutableDictionary dictionaryWithObject:@"ambient" forKey:@"mode"];
    if (accountKey != nil) {
        // An empty key is not a key and is not an absent one either: taken
        // as absent, the chain would answer with whatever identity the
        // machine carries and the failure would name a permission.
        if (PLKStorageBlank(accountKey)) {
            PLKFail(error,
                    PLKInvalidArgument(
                        @"account_key is a key or is absent, and is never "
                        @"empty",
                        @"Pass the account key, or nothing for the Azure "
                        @"chain."));
            return nil;
        }
        credentials[@"mode"] = @"explicit";
        credentials[@"account_key"] = accountKey;
    }
    NSMutableDictionary<NSString *, id> *document = [@{
        @"provider" : @"azure",
        @"account" : account,
        @"container" : container,
        @"namespace" : databaseNamespace,
        @"credentials" : credentials,
    } mutableCopy];
    if (endpoint != nil) {
        // `endpoint` is what every facade calls it and `endpoint_url` is
        // what the library reads; the rename happens here so that one
        // spelling reaches callers across all three providers.
        document[@"endpoint_url"] = endpoint;
    }
    return document;
}

@implementation PLKStorage

+ (PLKRemote *)remoteFromS3Bucket:(NSString *)bucket
                      inNamespace:(NSString *)databaseNamespace
                           region:(NSString *)region
                         endpoint:(NSString *)endpoint
                   forcePathStyle:(BOOL)forcePathStyle
                      accessKeyID:(NSString *)accessKeyID
                  secretAccessKey:(NSString *)secretAccessKey
                     sessionToken:(NSString *)sessionToken
                          options:(PLKRemoteOptions *)options
                            error:(NSError **)error {
    NSDictionary<NSString *, id> *document = PLKStorageS3Document(
        bucket, databaseNamespace, region, endpoint, forcePathStyle,
        accessKeyID, secretAccessKey, sessionToken, error);
    if (document == nil) {
        return nil;
    }
    return PLKStorageRemoteFromProvider(@"s3", document, options, error);
}

+ (PLKRemote *)remoteFromGCSBucket:(NSString *)bucket
                       inNamespace:(NSString *)databaseNamespace
                          endpoint:(NSString *)endpoint
                    serviceAccount:(NSString *)serviceAccount
                           options:(PLKRemoteOptions *)options
                             error:(NSError **)error {
    NSDictionary<NSString *, id> *document = PLKStorageGCSDocument(
        bucket, databaseNamespace, endpoint, serviceAccount, error);
    if (document == nil) {
        return nil;
    }
    return PLKStorageRemoteFromProvider(@"gcs", document, options, error);
}

+ (PLKRemote *)remoteFromAzureAccount:(NSString *)account
                            container:(NSString *)container
                          inNamespace:(NSString *)databaseNamespace
                             endpoint:(NSString *)endpoint
                           accountKey:(NSString *)accountKey
                              options:(PLKRemoteOptions *)options
                                error:(NSError **)error {
    NSDictionary<NSString *, id> *document = PLKStorageAzureDocument(
        account, container, databaseNamespace, endpoint, accountKey, error);
    if (document == nil) {
        return nil;
    }
    return PLKStorageRemoteFromProvider(@"azure", document, options, error);
}

+ (NSString *)libraryPath {
    return PLKStorageLibraryPath();
}

@end
