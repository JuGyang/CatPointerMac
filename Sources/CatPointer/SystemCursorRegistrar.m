#import "SystemCursorRegistrar.h"

#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <stdbool.h>

#import "CursorAssetSequence.h"

NSString *const CPSystemCursorErrorDomain =
    @"com.local.catpointer.system-cursor";

typedef int CPWindowServerConnection;
typedef NS_ENUM(NSInteger, CPManagedCursorRole) {
    CPManagedCursorRoleUnknown,
    CPManagedCursorRoleArrow,
    CPManagedCursorRoleText,
};

static BOOL CPCanonicalUserFacingScale(
    CGFloat scale,
    CGFloat *canonicalScale
) {
    for (NSNumber *step in @[@0.8, @0.9, @1.0, @1.1, @1.2]) {
        if (fabs(scale - step.doubleValue) < 0.000001) {
            if (canonicalScale != NULL) {
                *canonicalScale = step.doubleValue;
            }
            return YES;
        }
    }
    return NO;
}

typedef CPWindowServerConnection (*CPMainConnectionFunction)(void);
typedef CGError (*CPRegisterCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    bool globally,
    bool instantly,
    CGSize size,
    CGPoint hotspot,
    NSUInteger frameCount,
    CGFloat frameDuration,
    CFArrayRef images,
    int *seed
);
typedef CGError (*CPCopyCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    CGSize *size,
    CGPoint *hotspot,
    NSUInteger *frameCount,
    CGFloat *frameDuration,
    CFArrayRef *images
);
typedef CGError (*CPRemoveCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    bool unknownFlag
);
typedef CGError (*CPGetCursorDataSizeFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    size_t *size
);
typedef CGError (*CPCoreCursorUnregisterAllFunction)(
    CPWindowServerConnection connection
);
typedef CGError (*CPCoreCursorSetFunction)(
    CPWindowServerConnection connection,
    int cursorID
);
typedef CGError (*CPCoreCursorSetAndReturnSeedFunction)(
    CPWindowServerConnection connection,
    int cursorID,
    int *seed
);
typedef char *(*CPCursorNameForSystemCursorFunction)(int cursorID);
typedef void (*CPSetDockCursorOverrideFunction)(
    CPWindowServerConnection connection,
    bool flag
);
typedef CGError (*CPSetRegisteredCursorFunction)(
    CPWindowServerConnection connection,
    char *identifier,
    int *seed
);
typedef CGError (*CPObscureCursorFunction)(
    CPWindowServerConnection connection
);
typedef CGError (*CPGetGlobalCursorDataSizeFunction)(
    CPWindowServerConnection connection,
    int *size
);
typedef CGError (*CPGetGlobalCursorDataFunction)(
    CPWindowServerConnection connection,
    void *data,
    int *dataSize,
    int *bytesPerRow,
    CGRect *cursorBounds,
    CGPoint *hotspot,
    int *bitsPerPixel,
    int *samplesPerPixel,
    int *bitsPerSample
);

@interface CPCursorSnapshot : NSObject

@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) CGSize size;
@property(nonatomic) CGPoint hotspot;
@property(nonatomic) NSUInteger frameCount;
@property(nonatomic) CGFloat frameDuration;
@property(nonatomic, copy) NSArray *images;

@end

@implementation CPCursorSnapshot
@end

@interface CPSystemCursorRegistrar ()

@property(nonatomic, readwrite, getter=isAvailable) BOOL available;
@property(nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property(nonatomic, readwrite, copy, nullable) NSString *unavailableReason;
@property(nonatomic, readwrite) CGFloat scale;
@property(nonatomic, readwrite) CGFloat targetFramesPerSecond;

- (BOOL)recoverStaleBackups;
- (BOOL)ensureBackupSnapshots:
    (NSDictionary<NSString *, CPCursorSnapshot *> *)snapshots
                    identifiers:(NSArray<NSString *> *)identifiers;
- (BOOL)restoreManagedIdentifiers:(NSArray<NSString *> *)identifiers;
- (BOOL)restoreSnapshots:
    (NSDictionary<NSString *, CPCursorSnapshot *> *)snapshots
               identifiers:(NSArray<NSString *> *)identifiers;
- (BOOL)activateArrowCursor;
- (BOOL)activateTextCursor;
- (CPManagedCursorRole)activeManagedCursorRoleForSnapshots:
    (NSDictionary<NSString *, CPCursorSnapshot *> *)snapshots;
- (BOOL)reapplyWithScale:(CGFloat)scale
   targetFramesPerSecond:(CGFloat)targetFramesPerSecond
          preservingRole:(CPManagedCursorRole)preservingRole
                   error:(NSError **)error;
- (BOOL)prepareRestoredCursorForDisplay;
- (nullable NSData *)canonicalPixelDataForImage:(CGImageRef)image;

@end

@implementation CPSystemCursorRegistrar {
    CPMainConnectionFunction _mainConnection;
    CPRegisterCursorFunction _registerCursor;
    CPCopyCursorFunction _copyCursor;
    CPRemoveCursorFunction _removeCursor;
    CPGetCursorDataSizeFunction _getCursorDataSize;
    CPCoreCursorUnregisterAllFunction _unregisterAllCoreCursors;
    CPCoreCursorSetFunction _setCoreCursor;
    CPCoreCursorSetAndReturnSeedFunction _setCoreCursorAndReturnSeed;
    CPCursorNameForSystemCursorFunction _cursorNameForSystemCursor;
    CPSetDockCursorOverrideFunction _setDockCursorOverride;
    CPSetRegisteredCursorFunction _setRegisteredCursor;
    CPObscureCursorFunction _obscureCursor;
    CPGetGlobalCursorDataSizeFunction _getGlobalCursorDataSize;
    CPGetGlobalCursorDataFunction _getGlobalCursorData;
    CPWindowServerConnection _connection;
    NSDictionary<NSString *, CPCursorSnapshot *> *_customSnapshots;
    NSDictionary<NSString *, CPCursorSnapshot *> *_originalSnapshots;
    NSArray<NSString *> *_managedIdentifiers;
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *
        _renderTemplateCache;
    NSCache<NSString *, CPCursorAssetSequence *> *_assetSequenceCache;
    dispatch_queue_t _renderPrewarmQueue;
    NSUInteger _prewarmGeneration;
    CGFloat _activePrewarmScale;
    BOOL _prewarmInProgress;
    CPManagedCursorRole _lastReappliedRole;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _scale = 1.0;
        _targetFramesPerSecond = 0;
        // Exactly five size stops × two cursor roles (about 16.7 MiB).
        // A strong, bounded dictionary makes the first adjustment as fast as
        // later ones; NSCache may otherwise evict entries unpredictably.
        _renderTemplateCache = [NSMutableDictionary dictionary];
        _assetSequenceCache = [NSCache new];
        _assetSequenceCache.countLimit = 2;
        dispatch_queue_attr_t prewarmAttributes =
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            );
        _renderPrewarmQueue = dispatch_queue_create(
            "com.local.catpointer.render-prewarm",
            prewarmAttributes
        );
        [self loadPrivateCursorAPI];
    }
    return self;
}

- (void)dealloc {
    if (_enabled) {
        [self stop];
    }
}

- (void)loadPrivateCursorAPI {
    _mainConnection = (CPMainConnectionFunction)dlsym(
        RTLD_DEFAULT,
        "CGSMainConnectionID"
    );
    _registerCursor = (CPRegisterCursorFunction)dlsym(
        RTLD_DEFAULT,
        "CGSRegisterCursorWithImages"
    );
    _copyCursor = (CPCopyCursorFunction)dlsym(
        RTLD_DEFAULT,
        "CGSCopyRegisteredCursorImages"
    );
    _removeCursor = (CPRemoveCursorFunction)dlsym(
        RTLD_DEFAULT,
        "CGSRemoveRegisteredCursor"
    );
    _getCursorDataSize = (CPGetCursorDataSizeFunction)dlsym(
        RTLD_DEFAULT,
        "CGSGetRegisteredCursorDataSize"
    );
    _unregisterAllCoreCursors =
        (CPCoreCursorUnregisterAllFunction)dlsym(
            RTLD_DEFAULT,
            "CoreCursorUnregisterAll"
        );
    _setCoreCursor = (CPCoreCursorSetFunction)dlsym(
        RTLD_DEFAULT,
        "CoreCursorSet"
    );
    _setCoreCursorAndReturnSeed =
        (CPCoreCursorSetAndReturnSeedFunction)dlsym(
            RTLD_DEFAULT,
            "CoreCursorSetAndReturnSeed"
        );
    _cursorNameForSystemCursor =
        (CPCursorNameForSystemCursorFunction)dlsym(
            RTLD_DEFAULT,
            "CGSCursorNameForSystemCursor"
        );
    _setDockCursorOverride =
        (CPSetDockCursorOverrideFunction)dlsym(
            RTLD_DEFAULT,
            "CGSSetDockCursorOverride"
        );
    _setRegisteredCursor = (CPSetRegisteredCursorFunction)dlsym(
        RTLD_DEFAULT,
        "CGSSetRegisteredCursor"
    );
    _obscureCursor = (CPObscureCursorFunction)dlsym(
        RTLD_DEFAULT,
        "CGSObscureCursor"
    );
    _getGlobalCursorDataSize =
        (CPGetGlobalCursorDataSizeFunction)dlsym(
            RTLD_DEFAULT,
            "CGSGetGlobalCursorDataSize"
        );
    _getGlobalCursorData = (CPGetGlobalCursorDataFunction)dlsym(
        RTLD_DEFAULT,
        "CGSGetGlobalCursorData"
    );

    if (_mainConnection == NULL || _registerCursor == NULL ||
        _copyCursor == NULL || _removeCursor == NULL ||
        _getCursorDataSize == NULL ||
        _unregisterAllCoreCursors == NULL ||
        _setCoreCursor == NULL ||
        _cursorNameForSystemCursor == NULL ||
        _setDockCursorOverride == NULL ||
        _setRegisteredCursor == NULL ||
        _obscureCursor == NULL ||
        _getGlobalCursorDataSize == NULL ||
        _getGlobalCursorData == NULL) {
        self.available = NO;
        self.unavailableReason =
            @"当前 macOS 没有提供所需的系统光标注册入口。";
        return;
    }

    _connection = _mainConnection();
    if (_connection == 0) {
        self.available = NO;
        self.unavailableReason = @"无法连接 WindowServer。";
        return;
    }

    self.available = YES;
}

- (NSArray<NSDictionary<NSString *, id> *> *)cursorDefinitions {
    NSMutableOrderedSet<NSString *> *arrowNames =
        [NSMutableOrderedSet orderedSetWithArray:@[
            @"com.apple.coregraphics.Arrow",
            @"com.apple.coregraphics.ArrowCtx",
            @"com.apple.coregraphics.ArrowS",
        ]];
    NSMutableOrderedSet<NSString *> *textNames =
        [NSMutableOrderedSet orderedSetWithArray:@[
            @"com.apple.coregraphics.IBeam",
            @"com.apple.coregraphics.IBeamXOR",
            @"com.apple.coregraphics.IBeamS",
        ]];

    // macOS 26 moved the live pointer roles to ArrowS/IBeamS while retaining
    // the old registered names. Discover all aliases so future OS revisions
    // do not silently accept a registration that the live cursor never uses.
    for (int cursorID = 0; cursorID < 128; cursorID++) {
        char *rawName = _cursorNameForSystemCursor(cursorID);
        if (rawName == NULL) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (name.length == 0) {
            continue;
        }
        if ([name rangeOfString:@"arrow"
                        options:NSCaseInsensitiveSearch].location !=
                NSNotFound) {
            [arrowNames addObject:name];
        }
        if ([name rangeOfString:@"ibeam"
                        options:NSCaseInsensitiveSearch].location !=
                NSNotFound) {
            [textNames addObject:name];
        }
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *definitions =
        [NSMutableArray array];
    for (NSString *identifier in arrowNames) {
        [definitions addObject:@{
            @"identifier": identifier,
            @"backup": [@"com.local.catpointer.backup."
                stringByAppendingString:identifier],
            @"role": @"default",
            @"required":
                @([identifier isEqualToString:
                    @"com.apple.coregraphics.Arrow"]),
        }];
    }
    for (NSString *identifier in textNames) {
        [definitions addObject:@{
            @"identifier": identifier,
            @"backup": [@"com.local.catpointer.backup."
                stringByAppendingString:identifier],
            @"role": @"text",
            @"required":
                @([identifier isEqualToString:
                    @"com.apple.coregraphics.IBeam"]),
        }];
    }
    return definitions.copy;
}

- (BOOL)startWithScale:(CGFloat)scale error:(NSError **)error {
    return [self startWithScale:scale
         targetFramesPerSecond:0
                         error:error];
}

- (BOOL)startWithScale:(CGFloat)scale
 targetFramesPerSecond:(CGFloat)targetFramesPerSecond
                 error:(NSError **)error {
    if (!self.available) {
        if (error != NULL) {
            *error = [self errorWithCode:1
                             description:self.unavailableReason ?:
                                 @"系统光标注册不可用。"];
        }
        return NO;
    }

    if (self.enabled) {
        return [self reapplyWithScale:scale
               targetFramesPerSecond:targetFramesPerSecond
                               error:error];
    }

    if (![self recoverStaleBackups]) {
        if (error != NULL) {
            *error = [self errorWithCode:2
                             description:
                @"检测到上次遗留的光标备份，但恢复失败；"
                @"为避免覆盖原系统光标，本次未安装猫标。"];
        }
        return NO;
    }

    CGFloat clampedScale = fmax(0.75, fmin(1.25, scale));
    CGFloat clampedFPS = targetFramesPerSecond <= 0
        ? 0
        : fmax(1.0, fmin(30.0, targetFramesPerSecond));
    NSMutableArray<NSString *> *managed = [NSMutableArray array];
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *originals =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *custom =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *roleCache =
        [NSMutableDictionary dictionary];

    // Snapshot every role before touching the system cursor registry.
    for (NSDictionary<NSString *, id> *definition in
         [self cursorDefinitions]) {
        NSString *identifier = definition[@"identifier"];
        NSString *backupIdentifier = definition[@"backup"];
        BOOL required = [definition[@"required"] boolValue];
        CPCursorSnapshot *original = [self snapshotForIdentifier:identifier];

        if (original == nil) {
            if (required) {
                [self restoreManagedIdentifiers:managed];
                if (error != NULL) {
                    *error = [self errorWithCode:2
                                     description:[NSString stringWithFormat:
                        @"无法备份系统光标 %@。", identifier]];
                }
                return NO;
            }
            continue;
        }
        originals[identifier] = original;

        if (![self registerSnapshot:original
                       asIdentifier:backupIdentifier]) {
            [self restoreSnapshots:originals
                       identifiers:managed];
            if (error != NULL) {
                *error = [self errorWithCode:3
                                 description:[NSString stringWithFormat:
                    @"无法创建安全备份 %@。", identifier]];
            }
            return NO;
        }
        [managed addObject:identifier];
    }

    if (![self resetCoreCursorCache]) {
        [self restoreSnapshots:originals identifiers:managed];
        if (error != NULL) {
            *error = [self errorWithCode:4
                             description:
                @"无法刷新 macOS 系统光标注册表。"];
        }
        return NO;
    }

    // CoreCursorUnregisterAll may clear custom names, including our crash
    // recovery copies. Recreate and verify every backup after each reset.
    if (![self ensureBackupSnapshots:originals identifiers:managed]) {
        [self restoreSnapshots:originals identifiers:managed];
        if (error != NULL) {
            *error = [self errorWithCode:5
                             description:
                @"刷新后无法保留原光标安全备份。"];
        }
        return NO;
    }

    for (NSDictionary<NSString *, id> *definition in
         [self cursorDefinitions]) {
        NSString *identifier = definition[@"identifier"];
        if (![managed containsObject:identifier]) {
            continue;
        }
        NSError *assetError = nil;
        CPCursorSnapshot *replacement =
            [self customSnapshotForDefinition:definition
                                        scale:clampedScale
                        targetFramesPerSecond:clampedFPS
                                    roleCache:roleCache
                                        error:&assetError];
        if (replacement == nil ||
            ![self registerSnapshot:replacement asIdentifier:identifier]) {
            [self restoreSnapshots:originals
                       identifiers:managed];
            if (error != NULL) {
                *error = assetError ?: [self errorWithCode:6
                    description:[NSString stringWithFormat:
                        @"无法注册猫标动画 %@。", identifier]];
            }
            return NO;
        }
        custom[identifier] = replacement;
    }

    _managedIdentifiers = managed.copy;
    _originalSnapshots = originals.copy;
    _customSnapshots = custom.copy;
    self.scale = clampedScale;
    self.targetFramesPerSecond = clampedFPS;
    self.enabled = _managedIdentifiers.count >= 2;
    if (self.enabled) {
        _lastReappliedRole = CPManagedCursorRoleArrow;
        [self activateArrowCursor];
    }
    return self.enabled;
}

- (BOOL)reapplyWithScale:(CGFloat)scale error:(NSError **)error {
    return [self reapplyWithScale:scale
           targetFramesPerSecond:self.targetFramesPerSecond
                           error:error];
}

- (BOOL)reapplyWithScale:(CGFloat)scale
   targetFramesPerSecond:(CGFloat)targetFramesPerSecond
                   error:(NSError **)error {
    return [self reapplyWithScale:scale
           targetFramesPerSecond:targetFramesPerSecond
                  preservingRole:CPManagedCursorRoleUnknown
                           error:error];
}

- (BOOL)reapplyWithScale:(CGFloat)scale
   targetFramesPerSecond:(CGFloat)targetFramesPerSecond
          preservingRole:(CPManagedCursorRole)preservingRole
                   error:(NSError **)error {
    if (!self.enabled) {
        return [self startWithScale:scale
             targetFramesPerSecond:targetFramesPerSecond
                             error:error];
    }

    CGFloat clampedScale = fmax(0.75, fmin(1.25, scale));
    CGFloat clampedFPS = targetFramesPerSecond <= 0
        ? 0
        : fmax(1.0, fmin(30.0, targetFramesPerSecond));
    NSDictionary<NSString *, CPCursorSnapshot *> *previous =
        _customSnapshots;
    CPManagedCursorRole activeRole =
        preservingRole == CPManagedCursorRoleUnknown
            ? [self activeManagedCursorRoleForSnapshots:previous]
            : preservingRole;
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *custom =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *roleCache =
        [NSMutableDictionary dictionary];

    for (NSDictionary<NSString *, id> *definition in
         [self cursorDefinitions]) {
        NSString *identifier = definition[@"identifier"];
        if (![_managedIdentifiers containsObject:identifier]) {
            continue;
        }

        NSError *assetError = nil;
        CPCursorSnapshot *replacement =
            [self customSnapshotForDefinition:definition
                                        scale:clampedScale
                        targetFramesPerSecond:clampedFPS
                                    roleCache:roleCache
                                        error:&assetError];
        if (replacement == nil) {
            if (error != NULL) {
                *error = assetError ?: [self errorWithCode:5
                    description:[NSString stringWithFormat:
                        @"无法重新渲染 %@。", identifier]];
            }
            return NO;
        }
        custom[identifier] = replacement;
    }

    if (![self resetCoreCursorCache]) {
        if (error != NULL) {
            *error = [self errorWithCode:7
                             description:
                @"无法刷新 macOS 系统光标注册表。"];
        }
        return NO;
    }

    if (![self ensureBackupSnapshots:_originalSnapshots
                         identifiers:_managedIdentifiers]) {
        BOOL restored = [self restoreSnapshots:_originalSnapshots
                                   identifiers:_managedIdentifiers];
        if (restored) {
            _managedIdentifiers = nil;
            _customSnapshots = nil;
            _originalSnapshots = nil;
            self.enabled = NO;
            _lastReappliedRole = CPManagedCursorRoleUnknown;
            [self activateArrowCursor];
        }
        if (error != NULL) {
            *error = [self errorWithCode:8
                             description:
                @"重新应用前无法重建原光标安全备份。"];
        }
        return NO;
    }

    for (NSString *identifier in _managedIdentifiers) {
        if (![self registerSnapshot:custom[identifier]
                       asIdentifier:identifier]) {
            BOOL rolledBack = [self resetCoreCursorCache] &&
                [self ensureBackupSnapshots:_originalSnapshots
                                identifiers:_managedIdentifiers];
            if (rolledBack) {
                for (NSString *previousIdentifier in
                     _managedIdentifiers) {
                    CPCursorSnapshot *old =
                        previous[previousIdentifier];
                    if (old == nil ||
                        ![self registerSnapshot:old
                                 asIdentifier:previousIdentifier]) {
                        rolledBack = NO;
                        break;
                    }
                }
            }
            if (!rolledBack) {
                BOOL restored = [self restoreSnapshots:_originalSnapshots
                                           identifiers:_managedIdentifiers];
                if (restored) {
                    _managedIdentifiers = nil;
                    _customSnapshots = nil;
                    _originalSnapshots = nil;
                    self.enabled = NO;
                    _lastReappliedRole = CPManagedCursorRoleUnknown;
                    [self activateArrowCursor];
                }
            }
            if (error != NULL) {
                *error = [self errorWithCode:9
                                 description:[NSString stringWithFormat:
                    @"重新应用 %@ 失败。", identifier]];
            }
            return NO;
        }
    }

    _customSnapshots = custom.copy;
    self.scale = clampedScale;
    self.targetFramesPerSecond = clampedFPS;
    // Keep the last known Arrow/Text role when the current global cursor is a
    // transient unmanaged shape (or cannot be read). Explicit settings refresh
    // can then reassert the last known role instead of leaving a stale frame,
    // while this reapply itself does not override hand/resize cursors.
    if (activeRole != CPManagedCursorRoleUnknown) {
        _lastReappliedRole = activeRole;
    }
    BOOL roleActivationAccepted = YES;
    if (activeRole == CPManagedCursorRoleArrow) {
        roleActivationAccepted = [self activateArrowCursor];
    } else if (activeRole == CPManagedCursorRoleText) {
        roleActivationAccepted = [self activateTextCursor];
    }
    if (preservingRole != CPManagedCursorRoleUnknown &&
        !roleActivationAccepted) {
        if (error != NULL) {
            *error = [self errorWithCode:16
                             description:
                @"设置已注册，但无法恢复之前的活动光标角色。"];
        }
        return NO;
    }
    return YES;
}

- (void)stop {
    [self stopWithError:nil];
}

- (BOOL)stopWithError:(NSError **)error {
    [self cancelPrewarming];
    if (!self.available) {
        if (error != NULL) {
            *error = [self errorWithCode:10
                             description:self.unavailableReason ?:
                @"系统光标恢复接口不可用。"];
        }
        return NO;
    }

    if (_managedIdentifiers.count == 0) {
        self.enabled = NO;
        _lastReappliedRole = CPManagedCursorRoleUnknown;
        [self activateArrowCursor];
        _setDockCursorOverride(_connection, true);
        return YES;
    }

    NSArray<NSString *> *identifiers = _managedIdentifiers;
    if (![self restoreManagedIdentifiers:identifiers]) {
        if (error != NULL) {
            *error = [self errorWithCode:11
                             description:
                @"原系统光标恢复验证失败；安全备份仍保留，"
                @"请不要强制结束猫标。"];
        }
        return NO;
    }
    if (![self prepareRestoredCursorForDisplay]) {
        if (error != NULL) {
            *error = [self errorWithCode:12
                             description:
                @"原光标注册表已恢复，但无法安全刷新当前可见指针；"
                @"屏幕可能暂存最后一帧猫标。请移动鼠标后重试退出；"
                @"应用暂不退出，以保留恢复上下文。"];
        }
        return NO;
    }
    _managedIdentifiers = nil;
    _customSnapshots = nil;
    _originalSnapshots = nil;
    self.enabled = NO;
    _lastReappliedRole = CPManagedCursorRoleUnknown;
    _setDockCursorOverride(_connection, true);
    return YES;
}

- (void)restoreStaleBackup {
    [self restoreStaleBackupWithError:nil];
}

- (BOOL)restoreStaleBackupWithError:(NSError **)error {
    if (!self.available) {
        if (error != NULL) {
            *error = [self errorWithCode:13
                             description:self.unavailableReason ?:
                @"系统光标恢复接口不可用。"];
        }
        return NO;
    }
    if (![self recoverStaleBackups]) {
        if (error != NULL) {
            *error = [self errorWithCode:14
                             description:
                @"遗留的原系统光标备份恢复失败。"];
        }
        return NO;
    }
    if (![self prepareRestoredCursorForDisplay]) {
        if (error != NULL) {
            *error = [self errorWithCode:15
                             description:
                @"原光标已恢复，但无法压掉当前缓存的旧指针画面。"];
        }
        return NO;
    }
    _setDockCursorOverride(_connection, true);
    return YES;
}

- (BOOL)recoverStaleBackups {
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *backups =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *definition in
         [self cursorDefinitions]) {
        NSString *identifier = definition[@"identifier"];
        NSString *backupIdentifier = definition[@"backup"];
        CPCursorSnapshot *backup =
            [self snapshotForIdentifier:backupIdentifier];
        if (backup != nil) {
            backups[identifier] = backup;
        }
    }

    if (backups.count == 0) {
        return YES;
    }
    NSArray<NSString *> *identifiers = backups.allKeys;
    if (![self restoreSnapshots:backups identifiers:identifiers]) {
        [self ensureBackupSnapshots:backups identifiers:identifiers];
        return NO;
    }
    return YES;
}

- (BOOL)ensureBackupSnapshots:
    (NSDictionary<NSString *, CPCursorSnapshot *> *)snapshots
                    identifiers:(NSArray<NSString *> *)identifiers {
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *definitions =
        [self definitionsByIdentifier];
    for (NSString *identifier in identifiers) {
        CPCursorSnapshot *expected = snapshots[identifier];
        NSString *backupIdentifier =
            definitions[identifier][@"backup"];
        if (expected == nil || backupIdentifier.length == 0) {
            return NO;
        }
        CPCursorSnapshot *existing =
            [self snapshotForIdentifier:backupIdentifier];
        if (existing != nil &&
            [self snapshot:existing matchesCustomSnapshot:expected]) {
            continue;
        }
        if (![self registerSnapshot:expected
                       asIdentifier:backupIdentifier]) {
            return NO;
        }
        CPCursorSnapshot *verified =
            [self snapshotForIdentifier:backupIdentifier];
        if (![self snapshot:verified matchesCustomSnapshot:expected]) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)restoreManagedIdentifiers:(NSArray<NSString *> *)identifiers {
    NSMutableDictionary<NSString *, CPCursorSnapshot *> *snapshots =
        [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *definitions =
        [self definitionsByIdentifier];
    for (NSString *identifier in identifiers) {
        NSDictionary<NSString *, id> *definition = definitions[identifier];
        NSString *backupIdentifier = definition[@"backup"];
        CPCursorSnapshot *backup =
            [self snapshotForIdentifier:backupIdentifier];
        CPCursorSnapshot *fallback = _originalSnapshots[identifier];
        CPCursorSnapshot *snapshot = backup ?: fallback;
        if (snapshot == nil) {
            return NO;
        }
        snapshots[identifier] = snapshot;
    }
    return [self restoreSnapshots:snapshots identifiers:identifiers];
}

- (BOOL)restoreSnapshots:
    (NSDictionary<NSString *, CPCursorSnapshot *> *)snapshots
             identifiers:(NSArray<NSString *> *)identifiers {
    if (snapshots.count != identifiers.count ||
        ![self resetCoreCursorCache]) {
        return NO;
    }

    NSDictionary *definitions = [self definitionsByIdentifier];
    BOOL restored = YES;
    for (NSString *identifier in identifiers.reverseObjectEnumerator) {
        CPCursorSnapshot *snapshot = snapshots[identifier];
        if (snapshot == nil ||
            ![self registerSnapshot:snapshot asIdentifier:identifier]) {
            restored = NO;
            break;
        }
    }
    if (restored) {
        for (NSString *identifier in identifiers) {
            CPCursorSnapshot *actual =
                [self snapshotForIdentifier:identifier];
            if (![self snapshot:actual
                 matchesCustomSnapshot:snapshots[identifier]]) {
                restored = NO;
                break;
            }
        }
    }
    if (!restored) {
        [self ensureBackupSnapshots:snapshots identifiers:identifiers];
        return NO;
    }
    for (NSString *identifier in identifiers) {
        [self removeIdentifier:definitions[identifier][@"backup"]];
    }
    _setDockCursorOverride(_connection, true);
    return YES;
}

- (BOOL)resetCoreCursorCache {
    CGError resetResult = _unregisterAllCoreCursors(_connection);
    if (resetResult != kCGErrorSuccess) {
        return NO;
    }

    // Core cursor IDs 0...44 are the image-backed cursor cache. Tahoe's
    // ArrowS/IBeamS are named aliases (100/101), not CoreCursor image IDs.
    for (int cursorID = 0; cursorID < 45; cursorID++) {
        _setCoreCursor(_connection, cursorID);
    }
    return YES;
}

- (BOOL)activateArrowCursor {
    // Registering with `instantly=true` invalidates the named cursor, but
    // AppKit processes may still hold a cursor seed from before the change.
    // Refresh CoreCursor ID 0 first, then make the freshly registered Tahoe
    // alias the final operation. Do not call NSCursor.arrowCursor here: that
    // singleton can itself contain the stale pre-registration seed.
    int coreSeed = 0;
    BOOL coreActivated = NO;
    if (_setCoreCursorAndReturnSeed != NULL) {
        coreActivated =
            _setCoreCursorAndReturnSeed(_connection, 0, &coreSeed) ==
                kCGErrorSuccess;
    } else {
        coreActivated =
            _setCoreCursor(_connection, 0) == kCGErrorSuccess;
    }

    NSArray<NSString *> *candidates = @[
        @"com.apple.coregraphics.ArrowS",
        @"com.apple.coregraphics.Arrow",
    ];
    BOOL namedActivated = NO;
    for (NSString *identifier in candidates) {
        if ([self snapshotForIdentifier:identifier] == nil) {
            continue;
        }
        int seed = 0;
        if (_setRegisteredCursor(
                _connection,
                (char *)identifier.UTF8String,
                &seed
            ) == kCGErrorSuccess) {
            namedActivated = YES;
            break;
        }
    }
    return namedActivated || coreActivated;
}

- (BOOL)activateTextCursor {
    NSArray<NSString *> *candidates = @[
        @"com.apple.coregraphics.IBeamS",
        @"com.apple.coregraphics.IBeam",
    ];
    for (NSString *identifier in candidates) {
        if ([self snapshotForIdentifier:identifier] == nil) {
            continue;
        }
        int seed = 0;
        if (_setRegisteredCursor(
                _connection,
                (char *)identifier.UTF8String,
                &seed
            ) == kCGErrorSuccess) {
            return YES;
        }
    }
    return NO;
}

- (CPManagedCursorRole)activeManagedCursorRoleForSnapshots:
    (NSDictionary<NSString *, CPCursorSnapshot *> *)snapshots {
    if (snapshots.count == 0) {
        return CPManagedCursorRoleUnknown;
    }
    NSDictionary<NSString *, id> *global =
        [self currentGlobalCursorDiagnostics];
    for (NSString *identifier in @[
        @"com.apple.coregraphics.ArrowS",
        @"com.apple.coregraphics.Arrow",
    ]) {
        if ([self globalDiagnostics:global
                    matchesSnapshot:snapshots[identifier]]) {
            return CPManagedCursorRoleArrow;
        }
    }
    for (NSString *identifier in @[
        @"com.apple.coregraphics.IBeamS",
        @"com.apple.coregraphics.IBeam",
    ]) {
        if ([self globalDiagnostics:global
                    matchesSnapshot:snapshots[identifier]]) {
            return CPManagedCursorRoleText;
        }
    }
    return CPManagedCursorRoleUnknown;
}

- (BOOL)refreshVisibleCursorAfterSettingChange {
    if (!self.enabled) {
        return NO;
    }
    CPManagedCursorRole role = _lastReappliedRole;
    BOOL activated = role == CPManagedCursorRoleText
        ? [self activateTextCursor]
        : (role == CPManagedCursorRoleArrow
            ? [self activateArrowCursor]
            : YES);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.enabled) {
            if (role == CPManagedCursorRoleText) {
                [strongSelf activateTextCursor];
            } else if (role == CPManagedCursorRoleArrow) {
                [strongSelf activateArrowCursor];
            }
        }
    });
    return activated;
}

- (void)prewarmScales:(NSArray<NSNumber *> *)scales
targetFramesPerSecond:(CGFloat)targetFramesPerSecond {
    NSArray<NSNumber *> *requestedScales = [scales copy];
    if (!self.available || requestedScales.count == 0) {
        return;
    }
    CGFloat clampedFPS = targetFramesPerSecond <= 0
        ? 0
        : fmax(1.0, fmin(30.0, targetFramesPerSecond));
    CGFloat primaryScale = fmax(
        0.75,
        fmin(1.25, requestedScales.firstObject.doubleValue)
    );
    NSUInteger generation;
    @synchronized (self) {
        if (_prewarmInProgress &&
            fabs(_activePrewarmScale - primaryScale) < 0.001) {
            return;
        }
        generation = ++_prewarmGeneration;
        _activePrewarmScale = primaryScale;
        _prewarmInProgress = YES;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(_renderPrewarmQueue, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        @synchronized (strongSelf) {
            if (generation != strongSelf->_prewarmGeneration) {
                return;
            }
        }
        BOOL (^warmScale)(CGFloat) = ^BOOL(CGFloat scale) {
            @autoreleasepool {
                @synchronized (strongSelf) {
                    if (generation != strongSelf->_prewarmGeneration) {
                        return NO;
                    }
                }
                NSMutableDictionary<
                    NSString *,
                    CPCursorSnapshot *
                > *roleCache = [NSMutableDictionary dictionary];
                for (NSString *role in @[@"default", @"text"]) {
                    NSError *error = nil;
                    if ([strongSelf
                            customSnapshotForDefinition:@{
                                @"identifier": role,
                                @"role": role,
                            }
                                                 scale:scale
                                 targetFramesPerSecond:clampedFPS
                                             roleCache:roleCache
                                                 error:&error] == nil) {
                        return NO;
                    }
                    @synchronized (strongSelf) {
                        if (generation !=
                            strongSelf->_prewarmGeneration) {
                            // The completed template is still valid because
                            // every speed shares the same artwork. Keep it;
                            // a newer main-thread setting may also have
                            // published the same key meanwhile.
                            return NO;
                        }
                    }
                }
            }
            return YES;
        };
        void (^finishIfCurrent)(void) = ^{
            @synchronized (strongSelf) {
                if (generation == strongSelf->_prewarmGeneration) {
                    strongSelf->_prewarmInProgress = NO;
                    strongSelf->_activePrewarmScale = 0;
                }
            }
        };

        for (NSUInteger index = 0;
             index < requestedScales.count;
             index++) {
            CGFloat scale = fmax(
                0.75,
                fmin(
                    1.25,
                    requestedScales[index].doubleValue
                )
            );
            if (!warmScale(scale)) {
                finishIfCurrent();
                return;
            }
        }
        finishIfCurrent();
    });
}

- (void)cancelPrewarming {
    @synchronized (self) {
        _prewarmGeneration++;
        _prewarmInProgress = NO;
        _activePrewarmScale = 0;
    }
}

- (void)waitForPrewarming {
    dispatch_sync(_renderPrewarmQueue, ^{});
}

- (BOOL)prepareRestoredCursorForDisplay {
    [self activateArrowCursor];

    CPCursorSnapshot *restoredArrow =
        [self snapshotForIdentifier:@"com.apple.coregraphics.ArrowS"] ?:
        [self snapshotForIdentifier:@"com.apple.coregraphics.Arrow"];
    NSDictionary<NSString *, id> *global =
        [self currentGlobalCursorDiagnostics];
    if ([self globalDiagnostics:global
                matchesSnapshot:restoredArrow]) {
        return YES;
    }

    // The active application can retain the previous hardware cursor even
    // after every named role has been restored. Obscuring it is the only
    // documented reversed CGS path that does not inject input or require
    // accessibility permission: the next real mouse movement asks the
    // active application for its role again, now resolving the restored
    // Arrow/IBeam registration.
    return _obscureCursor(_connection) == kCGErrorSuccess;
}

- (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)
    definitionsByIdentifier {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *definition in
         [self cursorDefinitions]) {
        result[definition[@"identifier"]] = definition;
    }
    return result;
}

- (nullable CPCursorSnapshot *)snapshotForIdentifier:
    (NSString *)identifier {
    size_t dataSize = 0;
    CGError sizeResult = _getCursorDataSize(
        _connection,
        (char *)identifier.UTF8String,
        &dataSize
    );
    if (sizeResult != kCGErrorSuccess || dataSize == 0) {
        return nil;
    }

    CGSize size = CGSizeZero;
    CGPoint hotspot = CGPointZero;
    NSUInteger frameCount = 0;
    CGFloat frameDuration = 0;
    CFArrayRef images = NULL;
    CGError result = _copyCursor(
        _connection,
        (char *)identifier.UTF8String,
        &size,
        &hotspot,
        &frameCount,
        &frameDuration,
        &images
    );
    if (result != kCGErrorSuccess || images == NULL ||
        CFArrayGetCount(images) == 0) {
        if (images != NULL) {
            CFRelease(images);
        }
        return nil;
    }

    CPCursorSnapshot *snapshot = [CPCursorSnapshot new];
    snapshot.identifier = identifier;
    snapshot.size = size;
    snapshot.hotspot = hotspot;
    snapshot.frameCount = MAX((NSUInteger)1, frameCount);
    snapshot.frameDuration = frameDuration;
    snapshot.images = CFBridgingRelease(images);
    return snapshot;
}

- (BOOL)registerSnapshot:(CPCursorSnapshot *)snapshot
            asIdentifier:(NSString *)identifier {
    int seed = 0;
    CGError result = _registerCursor(
        _connection,
        (char *)identifier.UTF8String,
        true,
        true,
        snapshot.size,
        snapshot.hotspot,
        snapshot.frameCount,
        snapshot.frameDuration,
        (__bridge CFArrayRef)snapshot.images,
        &seed
    );
    if (result == kCGErrorSuccess) {
        // Tahoe's Dock can otherwise immediately reassert the stock cursor.
        _setDockCursorOverride(_connection, false);
    }
    return result == kCGErrorSuccess;
}

- (BOOL)removeIdentifier:(NSString *)identifier {
    CGError result = _removeCursor(
        _connection,
        (char *)identifier.UTF8String,
        false
    );
    return result == kCGErrorSuccess;
}

- (nullable CPCursorSnapshot *)customSnapshotForDefinition:
    (NSDictionary<NSString *, id> *)definition
                                                     scale:(CGFloat)scale
                                     targetFramesPerSecond:
    (CGFloat)targetFramesPerSecond
                                                 roleCache:
    (NSMutableDictionary<NSString *, CPCursorSnapshot *> *)roleCache
                                                     error:(NSError **)error {
    NSString *role = definition[@"role"];
    CPCursorSnapshot *template = roleCache[role];
    if (template == nil) {
        CGFloat canonicalCacheScale = scale;
        BOOL shouldCache = CPCanonicalUserFacingScale(
            scale,
            &canonicalCacheScale
        );
        NSString *cacheKey = [NSString stringWithFormat:
            @"%@|%.3f|motion",
            role,
            canonicalCacheScale];
        if (shouldCache) {
            @synchronized (_renderTemplateCache) {
                template = _renderTemplateCache[cacheKey];
            }
        }
        if (template == nil) {
            NSString *sequenceCacheKey = [NSString stringWithFormat:
                @"%@|motion",
                role];
            CPCursorAssetSequence *sequence =
                [_assetSequenceCache objectForKey:sequenceCacheKey];
            if (sequence == nil) {
                sequence = [CPCursorAssetSequence
                    sequenceForRole:role
             optimizedForSmoothness:YES
                              error:error];
                if (sequence != nil) {
                    [_assetSequenceCache setObject:sequence
                                            forKey:sequenceCacheKey];
                }
            }
            if (sequence == nil) {
                return nil;
            }
            NSArray *representations = nil;
            if (fabs(scale - 1.0) >= 0.001) {
                NSString *baseKey = [NSString stringWithFormat:
                    @"%@|1.000|motion",
                    role];
                CPCursorSnapshot *base;
                @synchronized (_renderTemplateCache) {
                    base = _renderTemplateCache[baseKey];
                }
                if (base.images.count >= 2) {
                    NSError *resizeError = nil;
                    representations = [sequence
                        createFilmstripRepresentationsAtScale:scale
                                         baseTwoXFilmstrip:
                            (__bridge CGImageRef)base.images[1]
                                                        error:&resizeError];
                }
            }
            if (representations == nil) {
                representations = [sequence
                    createFilmstripRepresentationsAtScale:scale
                                                     error:error];
            }
            if (representations == nil) {
                return nil;
            }

            template = [CPCursorSnapshot new];
            template.identifier = role;
            template.size = CGSizeMake(
                sequence.logicalSize.width * scale,
                sequence.logicalSize.height * scale
            );
            template.hotspot = CGPointMake(
                sequence.logicalHotspot.x * scale,
                sequence.logicalHotspot.y * scale
            );
            template.frameCount = sequence.registeredFrameCount;
            template.frameDuration = sequence.registeredFrameDuration;
            template.images = representations;

            if (shouldCache) {
                @synchronized (_renderTemplateCache) {
                    _renderTemplateCache[cacheKey] = template;
                }
            }
        }
        roleCache[role] = template;
    }

    CPCursorSnapshot *snapshot = [CPCursorSnapshot new];
    snapshot.identifier = definition[@"identifier"];
    snapshot.size = template.size;
    snapshot.hotspot = template.hotspot;
    snapshot.frameCount = template.frameCount;
    snapshot.frameDuration = targetFramesPerSecond > 0
        ? 1.0 / targetFramesPerSecond
        : template.frameDuration;
    snapshot.images = template.images;
    return snapshot;
}

- (NSDictionary<NSString *, id> *)liveCursorProbe {
    // Read WindowServer first. Initializing a fresh AppKit client after the
    // theme is installed makes Tahoe resolve its live ArrowS role from the
    // updated registry, which is exactly what a newly focused application
    // does.
    NSDictionary *global = [self currentGlobalCursorDiagnostics];
    CPCursorSnapshot *registeredArrow =
        [self snapshotForIdentifier:@"com.apple.coregraphics.ArrowS"] ?:
        [self snapshotForIdentifier:@"com.apple.coregraphics.Arrow"];
    CPCursorSnapshot *registeredText =
        [self snapshotForIdentifier:@"com.apple.coregraphics.IBeamS"] ?:
        [self snapshotForIdentifier:@"com.apple.coregraphics.IBeam"];
    return @{
        @"global": global,
        @"registeredArrow":
            [self diagnosticsForSnapshot:registeredArrow],
        @"registeredText":
            [self diagnosticsForSnapshot:registeredText],
        @"appKitArrow":
            [self diagnosticsForAppKitCursor:NSCursor.arrowCursor],
        @"appKitText":
            [self diagnosticsForAppKitCursor:NSCursor.IBeamCursor],
        @"passed": @YES,
    };
}

- (NSDictionary<NSString *, id> *)diagnosticsForAppKitCursor:
    (NSCursor *)cursor {
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *representations =
        [NSMutableArray array];
    for (NSImageRep *representation in cursor.image.representations) {
        [representations addObject:@{
            @"pixelsWide": @(representation.pixelsWide),
            @"pixelsHigh": @(representation.pixelsHigh),
        }];
    }
    return @{
        @"width": @(cursor.image.size.width),
        @"height": @(cursor.image.size.height),
        @"hotspotX": @(cursor.hotSpot.x),
        @"hotspotY": @(cursor.hotSpot.y),
        @"representations": representations,
    };
}

- (NSDictionary<NSString *, id> *)runExternalLiveProbe {
    NSString *executablePath =
        NSBundle.mainBundle.executableURL.path ?:
        NSProcessInfo.processInfo.arguments.firstObject;
    if (executablePath.length == 0) {
        return @{
            @"launched": @NO,
            @"error": @"找不到自检可执行文件。",
        };
    }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = @[@"--live-probe"];
    NSPipe *standardOutput = [NSPipe pipe];
    NSPipe *standardError = [NSPipe pipe];
    task.standardOutput = standardOutput;
    task.standardError = standardError;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        return @{
            @"launched": @NO,
            @"error": launchError.localizedDescription ?:
                @"无法启动外部 WindowServer 探针。",
        };
    }
    [task waitUntilExit];
    NSData *output =
        [standardOutput.fileHandleForReading readDataToEndOfFile];
    NSError *jsonError = nil;
    NSDictionary *result = output.length == 0 ? nil :
        [NSJSONSerialization JSONObjectWithData:output
                                        options:0
                                          error:&jsonError];
    if (![result isKindOfClass:NSDictionary.class]) {
        NSData *errorData =
            [standardError.fileHandleForReading readDataToEndOfFile];
        NSString *stderrText = [[NSString alloc]
            initWithData:errorData
                encoding:NSUTF8StringEncoding
        ];
        return @{
            @"launched": @YES,
            @"terminationStatus": @(task.terminationStatus),
            @"error": jsonError.localizedDescription ?:
                stderrText ?: @"外部 WindowServer 探针没有返回结果。",
        };
    }

    NSMutableDictionary *withProcess =
        [result mutableCopy];
    withProcess[@"launched"] = @YES;
    withProcess[@"terminationStatus"] = @(task.terminationStatus);
    return withProcess;
}

- (BOOL)appKitDiagnostics:(NSDictionary<NSString *, id> *)diagnostics
          matchesSnapshot:(nullable CPCursorSnapshot *)snapshot {
    if (snapshot == nil) {
        return NO;
    }
    if (fabs([diagnostics[@"width"] doubleValue] -
             snapshot.size.width) >= 0.01 ||
        fabs([diagnostics[@"height"] doubleValue] -
             snapshot.size.height) >= 0.01 ||
        fabs([diagnostics[@"hotspotX"] doubleValue] -
             snapshot.hotspot.x) >= 0.01 ||
        fabs([diagnostics[@"hotspotY"] doubleValue] -
             snapshot.hotspot.y) >= 0.01) {
        return NO;
    }

    NSArray<NSDictionary *> *representations =
        diagnostics[@"representations"];
    for (NSDictionary *representation in representations) {
        NSUInteger width =
            [representation[@"pixelsWide"] unsignedIntegerValue];
        NSUInteger height =
            [representation[@"pixelsHigh"] unsignedIntegerValue];
        for (id object in snapshot.images) {
            CGImageRef expected = (__bridge CGImageRef)object;
            if (width == CGImageGetWidth(expected) &&
                height ==
                    CGImageGetHeight(expected) /
                        MAX((NSUInteger)1, snapshot.frameCount)) {
                return YES;
            }
        }
    }
    return NO;
}

- (NSDictionary<NSString *, id> *)performSelfTestWithScale:(CGFloat)scale
                                                      error:(NSError **)error {
    [self cancelPrewarming];
    dispatch_sync(_renderPrewarmQueue, ^{});
    if (!self.available) {
        if (error != NULL) {
            *error = [self errorWithCode:10
                             description:self.unavailableReason ?:
                                 @"系统光标注册不可用。"];
        }
        return @{};
    }

    if (self.enabled && ![self stopWithError:error]) {
        return @{};
    }
    if (![self recoverStaleBackups]) {
        if (error != NULL) {
            *error = [self errorWithCode:14
                             description:
                @"自检前无法恢复遗留的原光标备份。"];
        }
        return @{};
    }

    NSMutableDictionary<NSString *, CPCursorSnapshot *> *baseline =
        [NSMutableDictionary dictionary];
    for (NSDictionary<NSString *, id> *definition in
         [self cursorDefinitions]) {
        CPCursorSnapshot *snapshot =
            [self snapshotForIdentifier:definition[@"identifier"]];
        if (snapshot != nil) {
            baseline[definition[@"identifier"]] = snapshot;
        }
    }

    NSError *startError = nil;
    const CGFloat testFramesPerSecond = 20.0;
    CFAbsoluteTime startBegan = CFAbsoluteTimeGetCurrent();
    BOOL started = [self startWithScale:scale
                 targetFramesPerSecond:testFramesPerSecond
                                 error:&startError];
    double startMilliseconds =
        (CFAbsoluteTimeGetCurrent() - startBegan) * 1000.0;
    NSError *reapplyError = nil;
    CFAbsoluteTime reapplyBegan = CFAbsoluteTimeGetCurrent();
    BOOL reapplied = started &&
        [self reapplyWithScale:scale
        targetFramesPerSecond:testFramesPerSecond
                        error:&reapplyError];
    double reapplyMilliseconds =
        (CFAbsoluteTimeGetCurrent() - reapplyBegan) * 1000.0;
    BOOL backupsPreservedAfterReapply = reapplied;
    if (reapplied) {
        NSDictionary *definitions = [self definitionsByIdentifier];
        for (NSString *identifier in _managedIdentifiers) {
            NSString *backupIdentifier =
                definitions[identifier][@"backup"];
            CPCursorSnapshot *backup =
                [self snapshotForIdentifier:backupIdentifier];
            if (![self snapshot:backup
                 matchesCustomSnapshot:_originalSnapshots[identifier]]) {
                backupsPreservedAfterReapply = NO;
                break;
            }
        }
    }

    BOOL allSizeLevelsValidated = reapplied;
    NSError *sizeSwitchError = nil;
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *
        sizeSwitchTimings = [NSMutableArray array];
    double maximumSizeSwitchMilliseconds = 0;
    NSArray<NSNumber *> *sizeLevels =
        @[@1.0, @0.8, @0.9, @1.1, @1.2];
    if (reapplied) {
        [self prewarmScales:sizeLevels
     targetFramesPerSecond:testFramesPerSecond];
        [self waitForPrewarming];
        for (NSNumber *sizeLevel in sizeLevels) {
            CGFloat requestedScale = sizeLevel.doubleValue;
            CFAbsoluteTime sizeSwitchBegan =
                CFAbsoluteTimeGetCurrent();
            BOOL sizeApplied = [self
                reapplyWithScale:requestedScale
           targetFramesPerSecond:testFramesPerSecond
                           error:&sizeSwitchError];
            double milliseconds =
                (CFAbsoluteTimeGetCurrent() - sizeSwitchBegan) * 1000.0;
            maximumSizeSwitchMilliseconds =
                fmax(maximumSizeSwitchMilliseconds, milliseconds);
            [sizeSwitchTimings addObject:@{
                @"scale": sizeLevel,
                @"milliseconds": @(milliseconds),
            }];
            CPCursorSnapshot *sizeArrow =
                _customSnapshots[@"com.apple.coregraphics.ArrowS"] ?:
                _customSnapshots[@"com.apple.coregraphics.Arrow"];
            CPCursorSnapshot *sizeText =
                _customSnapshots[@"com.apple.coregraphics.IBeamS"] ?:
                _customSnapshots[@"com.apple.coregraphics.IBeam"];
            if (!sizeApplied ||
                fabs(sizeArrow.size.width -
                     64.0 * requestedScale) >= 0.01 ||
                fabs(sizeArrow.size.height -
                     60.0 * requestedScale) >= 0.01 ||
                fabs(sizeText.size.width -
                     64.0 * requestedScale) >= 0.01 ||
                fabs(sizeText.size.height -
                     52.0 * requestedScale) >= 0.01) {
                allSizeLevelsValidated = NO;
                break;
            }
        }
        if (![self reapplyWithScale:scale
              targetFramesPerSecond:testFramesPerSecond
                              error:&sizeSwitchError]) {
            allSizeLevelsValidated = NO;
        }
    }

    BOOL allPlaybackProfilesValidated = reapplied;
    NSError *profileSwitchError = nil;
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *
        speedSwitchTimings = [NSMutableArray array];
    double maximumSpeedSwitchMilliseconds = 0;
    CFAbsoluteTime profileSwitchBegan = CFAbsoluteTimeGetCurrent();
    if (reapplied) {
        NSString *profileArrowIdentifier =
            _customSnapshots[@"com.apple.coregraphics.ArrowS"] != nil
                ? @"com.apple.coregraphics.ArrowS"
                : @"com.apple.coregraphics.Arrow";
        NSString *profileTextIdentifier =
            _customSnapshots[@"com.apple.coregraphics.IBeamS"] != nil
                ? @"com.apple.coregraphics.IBeamS"
                : @"com.apple.coregraphics.IBeam";
        CPCursorSnapshot *baselineArrow =
            _customSnapshots[profileArrowIdentifier];
        CPCursorSnapshot *baselineText =
            _customSnapshots[profileTextIdentifier];
        NSData *baselineArrowPixels = baselineArrow.images.count == 0
            ? nil
            : [self canonicalPixelDataForImage:
                (__bridge CGImageRef)baselineArrow.images[0]];
        NSData *baselineTextPixels = baselineText.images.count == 0
            ? nil
            : [self canonicalPixelDataForImage:
                (__bridge CGImageRef)baselineText.images[0]];
        for (NSNumber *requestedFPS in
             @[@0.0, @12.0, @20.0, @30.0]) {
            CGFloat fps = requestedFPS.doubleValue;
            CFAbsoluteTime speedSwitchBegan =
                CFAbsoluteTimeGetCurrent();
            BOOL speedApplied = [self
                reapplyWithScale:scale
           targetFramesPerSecond:fps
                           error:&profileSwitchError];
            double milliseconds =
                (CFAbsoluteTimeGetCurrent() - speedSwitchBegan) * 1000.0;
            maximumSpeedSwitchMilliseconds =
                fmax(maximumSpeedSwitchMilliseconds, milliseconds);
            [speedSwitchTimings addObject:@{
                @"framesPerSecond": requestedFPS,
                @"milliseconds": @(milliseconds),
            }];
            if (!speedApplied) {
                allPlaybackProfilesValidated = NO;
                break;
            }
            CPCursorSnapshot *profileArrow =
                [self snapshotForIdentifier:profileArrowIdentifier];
            CPCursorSnapshot *profileText =
                [self snapshotForIdentifier:profileTextIdentifier];
            CGFloat expectedArrowDuration = fps > 0
                ? 1.0 / fps
                : 4.29 / CPSystemCursorFrameLimit;
            CGFloat expectedTextDuration = fps > 0
                ? 1.0 / fps
                : 4.62 / CPSystemCursorFrameLimit;
            NSData *profileArrowPixels =
                profileArrow.images.count == 0
                    ? nil
                    : [self canonicalPixelDataForImage:
                        (__bridge CGImageRef)profileArrow.images[0]];
            NSData *profileTextPixels =
                profileText.images.count == 0
                    ? nil
                    : [self canonicalPixelDataForImage:
                        (__bridge CGImageRef)profileText.images[0]];
            if (profileArrow.frameCount != CPSystemCursorFrameLimit ||
                profileText.frameCount != CPSystemCursorFrameLimit ||
                fabs(profileArrow.frameDuration -
                     expectedArrowDuration) >= 0.001 ||
                fabs(profileText.frameDuration -
                     expectedTextDuration) >= 0.001 ||
                ![profileArrowPixels isEqualToData:
                    baselineArrowPixels] ||
                ![profileTextPixels isEqualToData:
                    baselineTextPixels]) {
                allPlaybackProfilesValidated = NO;
                break;
            }
        }
        if (![self reapplyWithScale:scale
              targetFramesPerSecond:testFramesPerSecond
                              error:&profileSwitchError]) {
            allPlaybackProfilesValidated = NO;
        }

        NSDictionary *definitions = [self definitionsByIdentifier];
        for (NSString *identifier in _managedIdentifiers) {
            NSString *backupIdentifier =
                definitions[identifier][@"backup"];
            CPCursorSnapshot *backup =
                [self snapshotForIdentifier:backupIdentifier];
            if (![self snapshot:backup
                 matchesCustomSnapshot:_originalSnapshots[identifier]]) {
                backupsPreservedAfterReapply = NO;
                break;
            }
        }
    }
    double profileSwitchMilliseconds =
        (CFAbsoluteTimeGetCurrent() - profileSwitchBegan) * 1000.0;
    BOOL arrowInstalled = NO;
    BOOL textInstalled = NO;
    BOOL animationInstalled = NO;
    CPCursorSnapshot *installedArrow = nil;
    CPCursorSnapshot *installedText = nil;
    CPCursorSnapshot *expectedArrow = nil;
    CPCursorSnapshot *expectedText = nil;
    CPCursorSnapshot *installedBackup = nil;
    NSDictionary<NSString *, id> *externalLiveProbe = @{};
    NSDictionary<NSString *, id> *liveArrow = @{};
    NSDictionary<NSString *, id> *liveText = @{};
    CPCursorSnapshot *verifiedArrowAnimation = nil;
    CPCursorSnapshot *verifiedTextAnimation = nil;
    BOOL arrowLive = NO;
    BOOL textLive = NO;
    BOOL activationSucceeded = NO;
    BOOL activeTextRolePreserved = NO;
    NSError *rolePreservationError = nil;
    NSString *arrowIdentifier =
        @"com.apple.coregraphics.Arrow";
    NSString *textIdentifier =
        @"com.apple.coregraphics.IBeam";
    if (reapplied) {
        if (_customSnapshots[
                @"com.apple.coregraphics.ArrowS"] != nil) {
            arrowIdentifier = @"com.apple.coregraphics.ArrowS";
        }
        if (_customSnapshots[
                @"com.apple.coregraphics.IBeamS"] != nil) {
            textIdentifier = @"com.apple.coregraphics.IBeamS";
        }
        // A background CLI cannot make a foreground application's cursor rect
        // become an I-beam, so global cursor pixels are not a deterministic
        // role oracle here. Exercise the exact role-preserving reapply path
        // explicitly, then verify the registered Text snapshot and activation
        // request instead.
        BOOL roleReapplied = [self
            reapplyWithScale:scale
       targetFramesPerSecond:testFramesPerSecond
              preservingRole:CPManagedCursorRoleText
                       error:&rolePreservationError];
        CPCursorSnapshot *roleTextAfter =
            _customSnapshots[textIdentifier];
        activeTextRolePreserved = roleReapplied &&
            _lastReappliedRole == CPManagedCursorRoleText &&
            [self snapshot:
                [self snapshotForIdentifier:textIdentifier]
             matchesCustomSnapshot:roleTextAfter];

        expectedArrow = _customSnapshots[arrowIdentifier];
        expectedText = _customSnapshots[textIdentifier];
        installedArrow =
            [self snapshotForIdentifier:arrowIdentifier];
        installedText =
            [self snapshotForIdentifier:textIdentifier];
        installedBackup =
            [self snapshotForIdentifier:
                [@"com.local.catpointer.backup."
                    stringByAppendingString:arrowIdentifier]];
        NSString *verifyArrowIdentifier =
            @"com.local.catpointer.verify.Arrow";
        NSString *verifyTextIdentifier =
            @"com.local.catpointer.verify.IBeam";
        if ([self registerSnapshot:expectedArrow
                     asIdentifier:verifyArrowIdentifier]) {
            verifiedArrowAnimation =
                [self snapshotForIdentifier:verifyArrowIdentifier];
        }
        if ([self registerSnapshot:expectedText
                     asIdentifier:verifyTextIdentifier]) {
            verifiedTextAnimation =
                [self snapshotForIdentifier:verifyTextIdentifier];
        }
        [self removeIdentifier:verifyArrowIdentifier];
        [self removeIdentifier:verifyTextIdentifier];
        arrowInstalled = [self snapshot:installedArrow
                 matchesCustomSnapshot:expectedArrow];
        textInstalled = [self snapshot:installedText
                matchesCustomSnapshot:expectedText];
        animationInstalled =
            verifiedArrowAnimation.frameCount ==
                CPSystemCursorFrameLimit &&
            verifiedTextAnimation.frameCount ==
                CPSystemCursorFrameLimit &&
            fabs(verifiedArrowAnimation.frameDuration -
                 1.0 / testFramesPerSecond) < 0.001 &&
            fabs(verifiedTextAnimation.frameDuration -
                 1.0 / testFramesPerSecond) < 0.001;

        // A background CLI cannot force the foreground application's cached
        // pointer image to refresh without synthesizing mouse input. Require
        // the WindowServer activation request itself to succeed, and retain
        // the current global image as a separate diagnostic.
        activationSucceeded = [self activateArrowCursor];

        // Use a fresh AppKit client, mirroring a newly focused Finder/editor.
        // This avoids this test process' NSCursor cache from before the
        // replacement was registered.
        externalLiveProbe = [self runExternalLiveProbe];
        liveArrow = externalLiveProbe[@"global"] ?: @{};
        liveText = externalLiveProbe[@"appKitText"] ?: @{};
        NSDictionary *appKitArrow =
            externalLiveProbe[@"appKitArrow"] ?: @{};
        arrowLive = [self appKitDiagnostics:appKitArrow
                                  matchesSnapshot:expectedArrow];
        textLive = [self appKitDiagnostics:liveText
                                  matchesSnapshot:expectedText];
    }

    NSError *stopError = nil;
    CFAbsoluteTime stopBegan = CFAbsoluteTimeGetCurrent();
    BOOL stopSucceeded = [self stopWithError:&stopError];
    double stopMilliseconds =
        (CFAbsoluteTimeGetCurrent() - stopBegan) * 1000.0;

    BOOL restored = stopSucceeded && baseline.count >= 2;
    for (NSString *identifier in baseline) {
        CPCursorSnapshot *after =
            [self snapshotForIdentifier:identifier];
        if (![self snapshot:after
             matchesCustomSnapshot:baseline[identifier]]) {
            restored = NO;
            break;
        }
    }

    BOOL distinctLiveImages =
        ![externalLiveProbe[@"appKitArrow"]
            isEqual:externalLiveProbe[@"appKitText"]];
    BOOL windowServerAnimated =
        [liveArrow[@"dataSucceeded"] boolValue] &&
        [liveArrow[@"height"] unsignedIntegerValue] %
                CPSystemCursorFrameLimit == 0 &&
        [liveArrow[@"height"] unsignedIntegerValue] /
                CPSystemCursorFrameLimit > 1;
    CPCursorAssetSequence *defaultArtwork =
        [CPCursorAssetSequence sequenceForRole:@"default" error:nil];
    CPCursorAssetSequence *textArtwork =
        [CPCursorAssetSequence sequenceForRole:@"text" error:nil];
    CPCursorAssetSequence *smoothDefaultArtwork =
        [CPCursorAssetSequence
            sequenceForRole:@"default"
     optimizedForSmoothness:YES
                      error:nil];
    CPCursorAssetSequence *smoothTextArtwork =
        [CPCursorAssetSequence
            sequenceForRole:@"text"
     optimizedForSmoothness:YES
                      error:nil];
    BOOL artworkValidated =
        defaultArtwork.sourceFrameCount == 130 &&
        textArtwork.sourceFrameCount == 140 &&
        defaultArtwork.registeredFrameCount ==
            CPSystemCursorFrameLimit &&
        textArtwork.registeredFrameCount ==
            CPSystemCursorFrameLimit &&
        [defaultArtwork.sourceAssetSHA256 isEqualToString:
            @"407827d370a0df8ba228f98ce7f3def8a281d3fe902b001504107dca4819d2a4"] &&
        [textArtwork.sourceAssetSHA256 isEqualToString:
            @"9833bee08c269031d25fceadbb96a9058d3139a50185a3a06fe24e6837560453"];
    BOOL smoothSamplingValidated =
        smoothDefaultArtwork.isMotionOptimized &&
        smoothTextArtwork.isMotionOptimized &&
        smoothDefaultArtwork.selectedSourceFrameNumbers.count ==
            CPSystemCursorFrameLimit &&
        smoothTextArtwork.selectedSourceFrameNumbers.count ==
            CPSystemCursorFrameLimit &&
        [smoothDefaultArtwork.selectedSourceFrameNumbers.lastObject
            unsignedIntegerValue] == 126 &&
        [smoothTextArtwork.selectedSourceFrameNumbers.lastObject
            unsignedIntegerValue] == 135;
    BOOL passed = started && reapplied &&
        allSizeLevelsValidated &&
        allPlaybackProfilesValidated &&
        backupsPreservedAfterReapply &&
        arrowInstalled && textInstalled &&
        animationInstalled && arrowLive && textLive &&
        activationSucceeded && distinctLiveImages && artworkValidated &&
        smoothSamplingValidated && restored;
    passed = passed && activeTextRolePreserved;
    if (!passed && error != NULL) {
        *error = startError ?: reapplyError ?: sizeSwitchError ?:
            profileSwitchError ?: rolePreservationError ?: stopError ?:
            [self errorWithCode:15
                                      description:
            @"系统光标注册或恢复验证未通过。"];
    }

    NSMutableDictionary<NSString *, id> *result = [@{
        @"apiAvailable": @(self.available),
        @"started": @(started),
        @"reapplied": @(reapplied),
        @"allPlaybackProfilesValidated":
            @(allPlaybackProfilesValidated),
        @"allSpeedLevelsValidated":
            @(allPlaybackProfilesValidated),
        @"allSizeLevelsValidated": @(allSizeLevelsValidated),
        @"backupsPreservedAfterReapply":
            @(backupsPreservedAfterReapply),
        @"arrowInstalled": @(arrowInstalled),
        @"textInstalled": @(textInstalled),
        @"animated24Frames": @(animationInstalled),
        @"motionOptimized20FPS": @(animationInstalled),
        @"arrowResolvedByAppKit": @(arrowLive),
        @"windowServerActivationSucceeded": @(activationSucceeded),
        @"activeTextRolePreservedAcrossSettingChange":
            @(activeTextRolePreserved),
        @"currentGlobalCursorAnimatedDuringProbe":
            @(windowServerAnimated),
        @"windowServerRegistrationVerified":
            @((BOOL)(
                arrowInstalled &&
                textInstalled &&
                animationInstalled &&
                activationSucceeded
            )),
        @"textResolvedByAppKit": @(textLive),
        @"liveImagesDistinct": @(distinctLiveImages),
        @"originalArtworkValidated": @(artworkValidated),
        @"smoothSamplingValidated": @(smoothSamplingValidated),
        @"originalsRestored": @(restored),
        @"passed": @(passed),
        @"testedScale": @(fmax(0.75, fmin(1.25, scale))),
        @"testedFramesPerSecond": @(testFramesPerSecond),
        @"startMilliseconds": @(startMilliseconds),
        @"cachedReapplyMilliseconds": @(reapplyMilliseconds),
        @"maximumSizeSwitchMilliseconds":
            @(maximumSizeSwitchMilliseconds),
        @"maximumSpeedSwitchMilliseconds":
            @(maximumSpeedSwitchMilliseconds),
        @"profileSwitchMilliseconds": @(profileSwitchMilliseconds),
        @"restoreMilliseconds": @(stopMilliseconds),
    } mutableCopy];
    result[@"installedArrow"] =
        [self diagnosticsForSnapshot:installedArrow];
    result[@"installedText"] =
        [self diagnosticsForSnapshot:installedText];
    result[@"expectedArrow"] =
        [self diagnosticsForSnapshot:expectedArrow];
    result[@"expectedText"] =
        [self diagnosticsForSnapshot:expectedText];
    result[@"arrowBackup"] =
        [self diagnosticsForSnapshot:installedBackup];
    result[@"externalLiveProbe"] = externalLiveProbe;
    result[@"liveArrow"] = liveArrow;
    result[@"liveText"] = liveText;
    result[@"verifiedArrowIdentifier"] = arrowIdentifier;
    result[@"verifiedTextIdentifier"] = textIdentifier;
    result[@"verifiedArrowAnimation"] =
        [self diagnosticsForSnapshot:verifiedArrowAnimation];
    result[@"verifiedTextAnimation"] =
        [self diagnosticsForSnapshot:verifiedTextAnimation];
    result[@"sizeSwitchTimings"] = sizeSwitchTimings.copy;
    result[@"speedSwitchTimings"] = speedSwitchTimings.copy;
    result[@"defaultArtwork"] =
        defaultArtwork == nil ? @{@"present": @NO}
                              : defaultArtwork.diagnostics;
    result[@"textArtwork"] =
        textArtwork == nil ? @{@"present": @NO}
                           : textArtwork.diagnostics;
    result[@"smoothDefaultArtwork"] =
        smoothDefaultArtwork == nil
            ? @{@"present": @NO}
            : smoothDefaultArtwork.diagnostics;
    result[@"smoothTextArtwork"] =
        smoothTextArtwork == nil
            ? @{@"present": @NO}
            : smoothTextArtwork.diagnostics;
    @synchronized (_renderTemplateCache) {
        [_renderTemplateCache removeAllObjects];
    }
    return result;
}

- (NSDictionary<NSString *, id> *)activeCursorDiagnosticsForIdentifier:
    (NSString *)identifier {
    int seed = 0;
    CGError setResult = _setRegisteredCursor(
        _connection,
        (char *)identifier.UTF8String,
        &seed
    );
    if (setResult != kCGErrorSuccess) {
        return @{
            @"setSucceeded": @NO,
            @"setError": @(setResult),
        };
    }

    NSMutableDictionary<NSString *, id> *diagnostics =
        [[self currentGlobalCursorDiagnostics] mutableCopy];
    diagnostics[@"setSucceeded"] = @YES;
    diagnostics[@"seed"] = @(seed);
    return diagnostics;
}

- (NSDictionary<NSString *, id> *)currentGlobalCursorDiagnostics {
    int dataSize = 0;
    CGError sizeResult =
        _getGlobalCursorDataSize(_connection, &dataSize);
    if (sizeResult != kCGErrorSuccess || dataSize <= 0 ||
        dataSize > 64 * 1024 * 1024) {
        return @{
            @"dataSucceeded": @NO,
            @"sizeError": @(sizeResult),
            @"dataBytes": @(dataSize),
        };
    }

    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)dataSize];
    int mutableSize = dataSize;
    // Tahoe's ABI differs from older reversed headers: after dataSize it
    // writes bytesPerRow, CGRect bounds, CGPoint hotspot, bitsPerPixel,
    // samplesPerPixel and bitsPerSample. Supplying the old CGSize-first
    // layout shifts every output and can corrupt adjacent stack variables.
    int bytesPerRow = 0;
    CGRect cursorBounds = CGRectZero;
    CGPoint hotspot = CGPointZero;
    int bitsPerPixel = 0;
    int samplesPerPixel = 0;
    int bitsPerSample = 0;
    CGError dataResult = _getGlobalCursorData(
        _connection,
        data.mutableBytes,
        &mutableSize,
        &bytesPerRow,
        &cursorBounds,
        &hotspot,
        &bitsPerPixel,
        &samplesPerPixel,
        &bitsPerSample
    );
    if (dataResult != kCGErrorSuccess || mutableSize < 0 ||
        (NSUInteger)mutableSize > data.length) {
        return @{
            @"dataSucceeded": @NO,
            @"dataError": @(dataResult),
            @"dataBytes": @(mutableSize),
        };
    }
    const uint8_t *bytes = data.bytes;
    uint64_t hash = UINT64_C(1469598103934665603);
    for (NSUInteger index = 0;
         index < (NSUInteger)mutableSize;
         index++) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return @{
        @"dataSucceeded": @(dataResult == kCGErrorSuccess),
        @"dataError": @(dataResult),
        @"dataBytes": @(mutableSize),
        @"width": @(cursorBounds.size.width),
        @"height": @(cursorBounds.size.height),
        @"hotspotX": @(hotspot.x),
        @"hotspotY": @(hotspot.y),
        @"bytesPerRow": @(bytesPerRow),
        @"bitsPerPixel": @(bitsPerPixel),
        @"samplesPerPixel": @(samplesPerPixel),
        @"bitsPerSample": @(bitsPerSample),
        @"fnv1a64": [NSString stringWithFormat:
            @"%016llx", (unsigned long long)hash],
    };
}

- (BOOL)globalDiagnostics:(NSDictionary<NSString *, id> *)diagnostics
          matchesSnapshot:(nullable CPCursorSnapshot *)snapshot {
    if (![diagnostics[@"dataSucceeded"] boolValue] ||
        snapshot == nil) {
        return NO;
    }
    size_t width = (size_t)[diagnostics[@"width"] unsignedLongLongValue];
    size_t height =
        (size_t)[diagnostics[@"height"] unsignedLongLongValue];
    for (id object in snapshot.images) {
        CGImageRef image = (__bridge CGImageRef)object;
        if (CGImageGetWidth(image) == width &&
            CGImageGetHeight(image) == height) {
            return YES;
        }
    }
    return NO;
}

- (NSDictionary<NSString *, id> *)diagnosticsForSnapshot:
    (nullable CPCursorSnapshot *)snapshot {
    if (snapshot == nil) {
        return @{@"present": @NO};
    }

    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *imageSizes =
        [NSMutableArray array];
    for (id object in snapshot.images) {
        CGImageRef image = (__bridge CGImageRef)object;
        [imageSizes addObject:@{
            @"width": @(CGImageGetWidth(image)),
            @"height": @(CGImageGetHeight(image)),
        }];
    }
    return @{
        @"present": @YES,
        @"width": @(snapshot.size.width),
        @"height": @(snapshot.size.height),
        @"hotspotX": @(snapshot.hotspot.x),
        @"hotspotY": @(snapshot.hotspot.y),
        @"frameCount": @(snapshot.frameCount),
        @"frameDuration": @(snapshot.frameDuration),
        @"representations": imageSizes,
    };
}

- (BOOL)snapshot:(nullable CPCursorSnapshot *)actual
    matchesCustomSnapshot:(nullable CPCursorSnapshot *)expected {
    if (actual == nil || expected == nil) {
        return NO;
    }
    if (![self snapshot:actual metadataMatchesSnapshot:expected]) {
        return NO;
    }
    if (actual.images.count != expected.images.count) {
        return NO;
    }

    for (NSUInteger index = 0; index < actual.images.count; index++) {
        CGImageRef actualImage =
            (__bridge CGImageRef)actual.images[index];
        CGImageRef expectedImage =
            (__bridge CGImageRef)expected.images[index];
        if (CGImageGetWidth(actualImage) !=
                CGImageGetWidth(expectedImage) ||
            CGImageGetHeight(actualImage) !=
                CGImageGetHeight(expectedImage)) {
            return NO;
        }
        NSData *actualPixels =
            [self canonicalPixelDataForImage:actualImage];
        NSData *expectedPixels =
            [self canonicalPixelDataForImage:expectedImage];
        if (actualPixels == nil || expectedPixels == nil ||
            ![actualPixels isEqualToData:expectedPixels]) {
            return NO;
        }
    }
    return YES;
}

- (nullable NSData *)canonicalPixelDataForImage:(CGImageRef)image {
    size_t width = CGImageGetWidth(image);
    size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0 ||
        width > 4096 || height > 65536 ||
        width > SIZE_MAX / 4 ||
        height > SIZE_MAX / (width * 4)) {
        return nil;
    }

    size_t bytesPerRow = width * 4;
    NSMutableData *pixels =
        [NSMutableData dataWithLength:bytesPerRow * height];
    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        pixels.mutableBytes,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        return nil;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(
        context,
        CGRectMake(0, 0, width, height),
        image
    );
    CGContextRelease(context);
    return pixels;
}

- (BOOL)snapshot:(nullable CPCursorSnapshot *)left
    metadataMatchesSnapshot:(nullable CPCursorSnapshot *)right {
    if (left == nil || right == nil) {
        return NO;
    }
    return left.frameCount == right.frameCount &&
        fabs(left.frameDuration - right.frameDuration) < 0.001 &&
        fabs(left.size.width - right.size.width) < 0.01 &&
        fabs(left.size.height - right.size.height) < 0.01 &&
        fabs(left.hotspot.x - right.hotspot.x) < 0.01 &&
        fabs(left.hotspot.y - right.hotspot.y) < 0.01 &&
        left.images.count == right.images.count;
}

- (BOOL)writePreviewToURL:(NSURL *)url error:(NSError **)error {
    NSMutableArray<CPCursorAssetSequence *> *sequences =
        [NSMutableArray array];
    for (NSString *role in @[@"default", @"text"]) {
        CPCursorAssetSequence *sequence =
            [CPCursorAssetSequence sequenceForRole:role error:error];
        if (sequence == nil) {
            return NO;
        }
        [sequences addObject:sequence];
    }

    const NSUInteger columns = 6;
    const CGFloat cellWidth = 128;
    const CGFloat cellHeight = 128;
    const CGFloat rowGap = 12;
    size_t width = (size_t)(columns * cellWidth);
    size_t height = (size_t)(
        sequences.count * cellHeight +
        (sequences.count - 1) * rowGap
    );
    CGColorSpaceRef colorSpace =
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        NULL,
        width,
        height,
        8,
        width * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (context == NULL) {
        if (error != NULL) {
            *error = [self errorWithCode:20
                             description:@"无法创建预览画布。"];
        }
        return NO;
    }

    CGContextSetRGBFillColor(context, 0.87, 0.91, 0.98, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));

    for (NSUInteger row = 0; row < sequences.count; row++) {
        CPCursorAssetSequence *sequence = sequences[row];
        for (NSUInteger column = 0; column < columns; column++) {
            NSUInteger frameIndex =
                (column * sequence.registeredFrameCount) / columns;
            CGImageRef frame =
                [sequence createFrameAtRegisteredIndex:frameIndex
                                            pixelScale:2.0
                                                 error:error];
            if (frame == NULL) {
                CGContextRelease(context);
                if (error != NULL && *error == nil) {
                    *error = [self errorWithCode:21
                                     description:@"无法渲染猫标帧。"];
                }
                return NO;
            }
            CGFloat frameWidth = CGImageGetWidth(frame);
            CGFloat frameHeight = CGImageGetHeight(frame);
            CGFloat x =
                column * cellWidth +
                (cellWidth - frameWidth) / 2.0;
            CGFloat y =
                height - (row + 1) * cellHeight -
                row * rowGap +
                (cellHeight - frameHeight) / 2.0;
            CGContextDrawImage(
                context,
                CGRectMake(x, y, frameWidth, frameHeight),
                frame
            );
            CGImageRelease(frame);
        }
    }

    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSBitmapImageRep *representation =
        [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    NSData *data = [representation
        representationUsingType:NSBitmapImageFileTypePNG
                     properties:@{}
    ];
    BOOL result = [data writeToURL:url
                          options:NSDataWritingAtomic
                            error:error];
    return result;
}

- (NSError *)errorWithCode:(NSInteger)code
               description:(NSString *)description {
    return [NSError errorWithDomain:CPSystemCursorErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey: description,
    }];
}

@end
