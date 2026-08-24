// Implementation of the Objective-C facade. Every method performs exactly
// one canonical Application ABI call sequence; input buffers are borrowed
// for one call only and owner handles are released by ARC deallocation.

#import "PotluckDBObjC.h"

#include "potluckdb.h"

NSErrorDomain const PLKErrorDomain = @"dev.potluckdb.PotluckDB";
NSErrorUserInfoKey const PLKErrorCodeKey = @"PLKErrorCode";
NSErrorUserInfoKey const PLKErrorActionKey = @"PLKErrorAction";
NSErrorUserInfoKey const PLKErrorRetryAfterMillisecondsKey =
    @"PLKErrorRetryAfterMilliseconds";

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

static NSError *PLKMakeError(NSString *code,
                             PLKErrorCategory category,
                             NSString *message,
                             NSString *action,
                             NSNumber *_Nullable retryAfter) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[PLKErrorCodeKey] = code;
    info[NSLocalizedDescriptionKey] = message;
    info[PLKErrorActionKey] = action;
    if (retryAfter != nil) {
        info[PLKErrorRetryAfterMillisecondsKey] = retryAfter;
    }
    return [NSError errorWithDomain:PLKErrorDomain code:category userInfo:info];
}

static NSError *PLKInvalidArgument(NSString *message, NSString *action) {
    return PLKMakeError(@"invalid_argument", PLKErrorCategoryCaller, message,
                        action, nil);
}

static NSError *PLKInternalFailure(NSString *message) {
    return PLKMakeError(@"internal_failure", PLKErrorCategoryInternal, message,
                        @"Preserve the failure details and report this error.",
                        nil);
}

static BOOL PLKFail(NSError **error, NSError *failure) {
    if (error != NULL) {
        *error = failure;
    }
    return NO;
}

static BOOL PLKCheck(int32_t result,
                     PotluckDbErrorV1 *raw,
                     NSError **error) {
    if (result == 0) {
        (void)potluckdb_error_release_v1(raw);
        return YES;
    }
    PLKErrorCategory category = (PLKErrorCategory)raw->category;
    if (category < PLKErrorCategoryCaller ||
        category > PLKErrorCategoryInternal) {
        category = PLKErrorCategoryInternal;
    }
    NSError *failure = PLKMakeError(
        PLKBufferString(raw->code), category, PLKBufferString(raw->message),
        PLKBufferString(raw->action),
        raw->has_retry_after != 0 ? @(raw->retry_after_ms) : nil);
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

static NSData *PLKUtf8(NSString *value) {
    NSData *encoded = [value dataUsingEncoding:NSUTF8StringEncoding];
    return encoded != nil ? encoded : [NSData data];
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

- (void)dealloc {
    if (_handle == 0) {
        return;
    }
    BOOL needsClose = _closable && !_closed;
    switch (_kind) {
        case PLKOwnerKindRemote:
            if (needsClose) {
                (void)potluckdb_remote_close_v1(_handle, NULL);
            }
            (void)potluckdb_remote_release_v1(_handle, NULL);
            break;
        case PLKOwnerKindDatabase:
            if (needsClose) {
                (void)potluckdb_database_close_v1(_handle, NULL);
            }
            (void)potluckdb_database_release_v1(_handle, NULL);
            break;
        case PLKOwnerKindConnection:
            if (needsClose) {
                (void)potluckdb_connection_close_v1(_handle, NULL);
            }
            (void)potluckdb_connection_release_v1(_handle, NULL);
            break;
        case PLKOwnerKindSnapshot:
            if (needsClose) {
                (void)potluckdb_snapshot_close_v1(_handle, NULL);
            }
            (void)potluckdb_snapshot_release_v1(_handle, NULL);
            break;
        case PLKOwnerKindTransaction:
            (void)potluckdb_transaction_release_v1(_handle, NULL);
            break;
    }
    _handle = 0;
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
                         @"Open a new owner and retry.", nil));
    }
    BOOL outcome = body(handle, error);
    [_lock unlock];
    return outcome;
}

- (BOOL)closeUsing:(int32_t (*)(uint64_t, PotluckDbErrorV1 *))call
             error:(NSError **)error {
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
    if (outcome) {
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
        _maximumRows = 100000;
        _prefetch = [PLKPrefetchPolicy automaticPolicy];
        _checkpoint = [PLKCheckpointPolicy automaticPolicy];
    }
    return self;
}

- (BOOL)fill:(PotluckDbConnectionOptionsV1 *)raw error:(NSError **)error {
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
             error:(NSError **)error {
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
        raw->flags |= POTLUCKDB_OPEN_CLIENT_ID_V1;
        raw->client_id = PLKSliceFromData(*clientIdentity);
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
    }
    return self;
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
    if (_retention != nil) {
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
                items[index].value.kind = POTLUCKDB_VALUE_INTEGER_V1;
                items[index].value.integer_value = number.longLongValue;
            }
        } else if ([value isKindOfClass:[NSString class]]) {
            NSData *text = PLKUtf8(value);
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

static NSArray *_Nullable PLKCopyRows(PotluckDbRowsHandleV1 handle,
                                      NSError **error) {
    NSMutableArray *rows = nil;
    uint64_t rowCount = 0;
    PotluckDbErrorV1 failure;
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
                    [values addObject:@(value.boolean_value != 0)];
                    break;
                case POTLUCKDB_VALUE_INTEGER_V1:
                    [values addObject:@(value.integer_value)];
                    break;
                case POTLUCKDB_VALUE_REAL_V1:
                    [values addObject:@(value.real_value)];
                    break;
                case POTLUCKDB_VALUE_TEXT_V1: {
                    NSString *text = [[NSString alloc]
                        initWithBytes:value.bytes.data
                               length:(NSUInteger)value.bytes.length
                             encoding:NSUTF8StringEncoding];
                    [values addObject:text != nil ? text : @""];
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
        [rows addObject:values];
    }
    potluckdb_error_init_v1(&failure);
    if (!PLKCheck(potluckdb_rows_release_v1(handle, &failure), &failure,
                  error)) {
        return nil;
    }
    return rows;
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

@end

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
                                    const PotluckDbBindingsV1 *,
                                    PotluckDbRowsHandleV1 *,
                                    PotluckDbErrorV1 *);
typedef int32_t (*PLKExecuteFunction)(uint64_t, PotluckDbSliceV1,
                                      const PotluckDbBindingsV1 *,
                                      PotluckDbExecuteResultV1 *, uint32_t,
                                      PotluckDbErrorV1 *);

static NSArray *_Nullable PLKRunQuery(PLKHandleState *state,
                                      PLKQueryFunction function,
                                      NSString *sql,
                                      PLKBindings *_Nullable bindings,
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

- (NSArray<NSArray *> *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_transaction_query_v1, sql, bindings,
                       error);
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

static NSArray *_Nullable PLKRunQuery(PLKHandleState *state,
                                      PLKQueryFunction function,
                                      NSString *sql,
                                      PLKBindings *_Nullable bindings,
                                      NSError **error) {
    PLKBindings *selected = bindings != nil ? bindings : [PLKBindings none];
    NSData *encoded = PLKUtf8(sql);
    __block NSArray *rows = nil;
    BOOL outcome = [state withHandle:^BOOL(uint64_t handle,
                                           NSError **bodyError) {
        return [selected withRaw:^BOOL(const PotluckDbBindingsV1 *raw,
                                       NSError **innerError) {
            PotluckDbRowsHandleV1 output = 0;
            PotluckDbErrorV1 failure;
            potluckdb_error_init_v1(&failure);
            if (!PLKCheck(function(handle, PLKSliceFromData(encoded), raw,
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
    if (!block(transaction, &blockFailure)) {
        [transaction rollbackQuietly];
        NSError *reported =
            blockFailure != nil
                ? blockFailure
                : PLKInternalFailure(
                      @"the transaction block failed without an error");
        return PLKFail(error, reported);
    }
    return [transaction commitWithError:error];
}

@implementation PLKConnection {
  @public
    PLKHandleState *_state;
}

- (NSArray<NSArray *> *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_connection_query_v1, sql, bindings,
                       error);
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

- (NSArray<NSArray *> *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_snapshot_query_v1, sql, bindings,
                       error);
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
    PLKRetentionPolicy *selected =
        retention != nil ? retention : [PLKRetentionPolicy boundedPolicy];
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

@implementation PLKDatabase {
  @public
    PLKHandleState *_state;
}

+ (instancetype)openAtPath:(NSString *)path
                    remote:(PLKRemote *)remote
                   options:(PLKOpenOptions *)options
                     error:(NSError **)error {
    PLKOpenOptions *selected =
        options != nil ? options : [[PLKOpenOptions alloc] init];
    PotluckDbOpenOptionsV1 raw;
    NSData *clientIdentity = nil;
    if (![selected fill:&raw clientIdentity:&clientIdentity error:error]) {
        return nil;
    }
    NSData *encoded = PLKUtf8(path);
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
    PLKHandleState *retained = nil;
    if (remote == nil) {
        opened = open(0, error);
    } else {
        retained = remote->_state;
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
    PLKOpenOptions *selected =
        options != nil ? options : [[PLKOpenOptions alloc] init];
    PotluckDbOpenOptionsV1 raw;
    NSData *clientIdentity = nil;
    if (![selected fill:&raw clientIdentity:&clientIdentity error:error]) {
        return nil;
    }
    NSData *encoded = PLKUtf8(path);
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

- (NSArray<NSArray *> *)query:(NSString *)sql
                     bindings:(PLKBindings *)bindings
                        error:(NSError **)error {
    return PLKRunQuery(_state, potluckdb_database_query_v1, sql, bindings,
                       error);
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
        result = [[PLKSyncResult alloc] init];
        result->_outcome = (PLKSyncOutcome)output.kind;
        BOOL converted = YES;
        switch (output.kind) {
            case POTLUCKDB_SYNC_UP_TO_DATE_V1:
            case POTLUCKDB_SYNC_CONFLICT_V1:
                if (output.has_revision != 0) {
                    result->_revision =
                        [PLKRevision revisionWithRaw:output.revision];
                }
                if (output.kind == POTLUCKDB_SYNC_CONFLICT_V1) {
                    result->_conflictReason = PLKBufferString(output.reason);
                }
                break;
            case POTLUCKDB_SYNC_PUSHED_V1:
                result->_revision = [PLKRevision revisionWithRaw:output.revision];
                break;
            case POTLUCKDB_SYNC_PULLED_V1: {
                result->_revision = [PLKRevision revisionWithRaw:output.revision];
                result->_replayed = PLKCopyStrings(output.replayed, bodyError);
                result->_quarantined =
                    result->_replayed == nil
                        ? nil
                        : PLKCopyStrings(output.quarantined, bodyError);
                converted = result->_quarantined != nil;
                break;
            }
            default:
                PLKFail(bodyError,
                        PLKInternalFailure(
                            @"potluckdb returned an unknown synchronization result"));
                converted = NO;
                break;
        }
        (void)potluckdb_sync_result_release_v1(&output);
        return converted;
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
    BOOL outcome =
        [source->_state withHandle:^BOOL(uint64_t left, NSError **bodyError) {
            return [target->_state withHandle:^BOOL(uint64_t right,
                                                    NSError **innerError) {
                PotluckDbReencryptOptionsV1 callOptions = options;
                PotluckDbKeyRotationReportV1 output;
                potluckdb_key_rotation_report_init_v1(&output);
                PotluckDbErrorV1 failure;
                potluckdb_error_init_v1(&failure);
                if (!PLKCheck(potluckdb_admin_reencrypt_v1(
                                  left, right, &callOptions, &output,
                                  (uint32_t)sizeof(output), &failure),
                              &failure, innerError)) {
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
                                       error:bodyError];
        }
                             error:error];
    return outcome ? report : nil;
}

@end
