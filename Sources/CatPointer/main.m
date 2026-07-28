#import <AppKit/AppKit.h>
#import <errno.h>
#import <fcntl.h>
#import <malloc/malloc.h>
#import <signal.h>
#import <sys/file.h>
#import <unistd.h>

#import "SystemCursorRegistrar.h"

typedef NS_ENUM(NSInteger, CPApplicationState) {
    CPApplicationStatePreparing,
    CPApplicationStatePaused,
    CPApplicationStateActive,
    CPApplicationStateApplying,
    CPApplicationStateVerifying,
    CPApplicationStateError,
};

static NSString *const CPAnimationProfileSlow = @"slow";
static NSString *const CPAnimationProfileMedium = @"medium";
static NSString *const CPAnimationProfileFast = @"fast";
static NSString *const CPAnimationProfileExtreme = @"extreme";
static NSString *const CPActivateExistingNotification =
    @"com.local.catpointer.activate-existing";
static NSString *const CPSettingsWindowFrameAutosaveName =
    @"CatPointerSettingsWindowFrame";
static NSString *const CPStatusItemAutosaveName =
    @"CatPointerPrimaryStatusItem";

static CGFloat CPCanonicalScale(CGFloat scale);

static BOOL CPMenuBarNeedsFallback(
    NSRect screenFrame,
    NSEdgeInsets safeAreaInsets,
    NSRect auxiliaryTopRightArea,
    NSRect statusItemFrame,
    BOOL statusItemWindowVisible
) {
    if (safeAreaInsets.top < 1.0) {
        return NO;
    }
    if (NSIsEmptyRect(auxiliaryTopRightArea) ||
        NSIsEmptyRect(statusItemFrame) ||
        !statusItemWindowVisible) {
        return YES;
    }

    NSRect toleratedSafeArea =
        NSInsetRect(auxiliaryTopRightArea, -1.0, -1.0);
    BOOL safeAreaBelongsToScreen =
        NSIntersectsRect(screenFrame, auxiliaryTopRightArea);
    return !safeAreaBelongsToScreen ||
        !NSContainsRect(toleratedSafeArea, statusItemFrame);
}

static NSArray<NSNumber *> *CPSizeSteps(void) {
    static NSArray<NSNumber *> *steps;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        steps = @[@0.8, @0.9, @1.0, @1.1, @1.2];
    });
    return steps;
}

static NSArray<NSNumber *> *CPSizeStepsStartingAtScale(CGFloat scale) {
    CGFloat current = CPCanonicalScale(scale);
    NSArray<NSNumber *> *byDistance =
        [CPSizeSteps() sortedArrayUsingComparator:
        ^NSComparisonResult(NSNumber *left, NSNumber *right) {
            CGFloat leftDistance = fabs(left.doubleValue - current);
            CGFloat rightDistance = fabs(right.doubleValue - current);
            if (fabs(leftDistance - rightDistance) < 0.001) {
                return [left compare:right];
            }
            return leftDistance < rightDistance
                ? NSOrderedAscending
                : NSOrderedDescending;
        }];
    NSMutableArray<NSNumber *> *ordered = [NSMutableArray array];
    NSNumber *currentValue = @(current);
    [ordered addObject:currentValue];
    if (fabs(current - 1.0) >= 0.001) {
        [ordered addObject:@1.0];
    }
    for (NSNumber *step in byDistance) {
        if (![ordered containsObject:step]) {
            [ordered addObject:step];
        }
    }
    return ordered.copy;
}

static CGFloat CPCanonicalScale(CGFloat scale) {
    CGFloat value = scale == 0 ? 1.0 : scale;
    NSArray<NSNumber *> *steps = CPSizeSteps();
    CGFloat bestValue = steps[0].doubleValue;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSNumber *step in steps) {
        CGFloat candidate = step.doubleValue;
        CGFloat distance = fabs(candidate - value);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestValue = candidate;
        }
    }
    return bestValue;
}

static NSArray<NSString *> *CPAnimationProfiles(void) {
    static NSArray<NSString *> *profiles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        profiles = @[
            CPAnimationProfileSlow,
            CPAnimationProfileMedium,
            CPAnimationProfileFast,
            CPAnimationProfileExtreme,
        ];
    });
    return profiles;
}

static NSString *CPCanonicalAnimationProfile(NSString *profile) {
    if ([CPAnimationProfiles() containsObject:profile]) {
        return profile;
    }
    if ([profile isEqualToString:@"efficient"] ||
        [profile isEqualToString:@"balanced"]) {
        return [profile isEqualToString:@"efficient"]
            ? CPAnimationProfileMedium
            : CPAnimationProfileFast;
    }
    if ([profile isEqualToString:@"original"]) {
        return CPAnimationProfileSlow;
    }
    if ([profile isEqualToString:@"high"]) {
        return CPAnimationProfileExtreme;
    }
    return CPAnimationProfileExtreme;
}

static CGFloat CPFramesPerSecondForProfile(NSString *profile) {
    NSString *canonical = CPCanonicalAnimationProfile(profile);
    if ([canonical isEqualToString:CPAnimationProfileSlow]) {
        return 0;
    }
    if ([canonical isEqualToString:CPAnimationProfileMedium]) {
        return 12.0;
    }
    if ([canonical isEqualToString:CPAnimationProfileFast]) {
        return 20.0;
    }
    if ([canonical isEqualToString:CPAnimationProfileExtreme]) {
        return 30.0;
    }
    return 30.0;
}

static NSString *CPSpeedDisplayName(NSString *profile) {
    NSString *canonical = CPCanonicalAnimationProfile(profile);
    if ([canonical isEqualToString:CPAnimationProfileSlow]) {
        return @"慢速";
    }
    if ([canonical isEqualToString:CPAnimationProfileMedium]) {
        return @"适中";
    }
    if ([canonical isEqualToString:CPAnimationProfileFast]) {
        return @"快速";
    }
    return @"极致";
}

static NSString *CPSizeDisplayName(CGFloat scale) {
    NSArray<NSString *> *names =
        @[@"小", @"偏小", @"标准", @"偏大", @"大"];
    NSArray<NSNumber *> *steps = CPSizeSteps();
    NSUInteger bestIndex = 0;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger index = 0; index < steps.count; index++) {
        CGFloat distance = fabs(steps[index].doubleValue - scale);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestIndex = index;
        }
    }
    return names[bestIndex];
}

static BOOL CPConfigurationRollbackSucceeded(NSError *error) {
    return [error.domain isEqualToString:CPSystemCursorErrorDomain] &&
        error.code == 201;
}

/// A native discrete slider that previews continuously but commits only after
/// mouse tracking ends. Keyboard and accessibility actions continue to use the
/// normal target/action path.
@interface CPCommitSlider : NSSlider

@property(nonatomic, weak, nullable) id commitTarget;
@property(nonatomic) SEL commitAction;
@property(nonatomic, readonly, getter=isMouseTracking) BOOL mouseTracking;

@end

@implementation CPCommitSlider {
    BOOL _mouseTracking;
}

- (void)mouseDown:(NSEvent *)event {
    _mouseTracking = YES;
    [super mouseDown:event];
    _mouseTracking = NO;
    if (self.commitAction != NULL) {
        [NSApp sendAction:self.commitAction
                       to:self.commitTarget
                     from:self];
    }
}

- (BOOL)stepBy:(NSInteger)delta {
    NSInteger current = (NSInteger)llround(self.doubleValue);
    NSInteger next = MAX(
        (NSInteger)llround(self.minValue),
        MIN(
            (NSInteger)llround(self.maxValue),
            current + delta
        )
    );
    if (next == current) {
        return NO;
    }
    self.doubleValue = next;
    [NSApp sendAction:self.action to:self.target from:self];
    NSAccessibilityPostNotification(
        self,
        NSAccessibilityValueChangedNotification
    );
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length > 0) {
        unichar character = [characters characterAtIndex:0];
        if (character == NSLeftArrowFunctionKey ||
            character == NSDownArrowFunctionKey) {
            [self stepBy:-1];
            return;
        }
        if (character == NSRightArrowFunctionKey ||
            character == NSUpArrowFunctionKey) {
            [self stepBy:1];
            return;
        }
    }
    [super keyDown:event];
}

- (BOOL)accessibilityPerformIncrement {
    return [self stepBy:1];
}

- (BOOL)accessibilityPerformDecrement {
    return [self stepBy:-1];
}

@end

@interface CPSettingsWindow : NSWindow
@end

@implementation CPSettingsWindow

- (void)cancelOperation:(id)sender {
    (void)sender;
    [self close];
}

@end

@interface CPAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

- (void)prewarmSizeChoicesForProfile:(NSString *)profile;
- (BOOL)applyPendingSettingsNow;
- (void)persistPendingSettingsAndCancel;
- (void)scheduleMenuBarAccessCheck;

@end

@implementation CPAppDelegate {
    CPSystemCursorRegistrar *_registrar;
    NSStatusItem *_statusItem;
    NSMenuItem *_toggleItem;
    NSMenuItem *_statusDescriptionItem;
    NSArray<NSMenuItem *> *_sizeItems;
    NSArray<NSMenuItem *> *_animationItems;
    NSMenuItem *_sizeParentItem;
    NSMenuItem *_animationParentItem;
    NSMenuItem *_reapplyItem;
    NSMenuItem *_verifyItem;
    NSWindow *_settingsWindow;
    CPCommitSlider *_settingsSizeSlider;
    CPCommitSlider *_settingsSpeedSlider;
    NSArray<NSTextField *> *_settingsSizeTickLabels;
    NSArray<NSTextField *> *_settingsSpeedTickLabels;
    NSTextField *_settingsSizeValueLabel;
    NSTextField *_settingsSpeedValueLabel;
    NSTextField *_settingsStatusLabel;
    NSTextField *_settingsExplanationLabel;
    NSImageView *_settingsStatusIndicator;
    NSProgressIndicator *_settingsProgressIndicator;
    NSSwitch *_settingsEnableSwitch;
    NSButton *_settingsEnableLabelButton;
    NSButton *_settingsVerifyButton;
    NSButton *_settingsResetButton;
    BOOL _desiredEnabled;
    BOOL _selfTest;
    BOOL _restoreOnly;
    BOOL _liveProbe;
    BOOL _showSettingsOnLaunch;
    NSString *_previewPath;
    dispatch_source_t _terminationSignal;
    dispatch_source_t _interruptSignal;
    dispatch_source_t _systemReapplyTimer;
    BOOL _hasPendingSettings;
    CGFloat _pendingScale;
    NSString *_pendingProfile;
    NSUInteger _settingsCommitGeneration;
    NSUInteger _settingsTransientStatusGeneration;
    NSString *_settingsTransientStatus;
    NSInteger _lastPreviewSizeIndex;
    NSInteger _lastPreviewSpeedIndex;
    BOOL _terminationApproved;
    BOOL _secondaryInstance;
    BOOL _dockFallbackActive;
    NSUInteger _menuBarAccessCheckGeneration;
    int _instanceLockFD;
    NSError *_instanceLockError;
    CPApplicationState _applicationState;
    NSError *_lastBackgroundError;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSArray<NSString *> *arguments =
            NSProcessInfo.processInfo.arguments;
        _selfTest = [arguments containsObject:@"--self-test"] ||
            [arguments containsObject:@"--smoke-test"];
        _restoreOnly = [arguments containsObject:@"--restore"];
        _liveProbe = [arguments containsObject:@"--live-probe"];
        _showSettingsOnLaunch =
            [arguments containsObject:@"--show-settings"];

        NSUInteger previewIndex =
            [arguments indexOfObject:@"--render-preview"];
        if (previewIndex != NSNotFound &&
            previewIndex + 1 < arguments.count) {
            _previewPath = [arguments[previewIndex + 1] copy];
        }

        _instanceLockFD = -1;
        NSString *lockPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                @"com.local.catpointer.instance.lock"];
        int lockFlags = O_CREAT | O_RDWR;
#ifdef O_CLOEXEC
        lockFlags |= O_CLOEXEC;
#endif
#ifdef O_NOFOLLOW
        lockFlags |= O_NOFOLLOW;
#endif
        _instanceLockFD = open(
            lockPath.fileSystemRepresentation,
            lockFlags,
            0600
        );
        if (_instanceLockFD < 0) {
            int lockErrorCode = errno;
            _instanceLockError = [NSError
                errorWithDomain:NSPOSIXErrorDomain
                           code:lockErrorCode
                       userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"无法创建用户私有的单实例锁：%@",
                    [NSString stringWithUTF8String:
                        strerror(lockErrorCode)]],
            }];
        } else if (flock(
                       _instanceLockFD,
                       LOCK_EX | LOCK_NB
                   ) != 0) {
            int lockErrorCode = errno;
            if (lockErrorCode == EWOULDBLOCK ||
                lockErrorCode == EAGAIN) {
                _secondaryInstance = YES;
            } else {
                _instanceLockError = [NSError
                    errorWithDomain:NSPOSIXErrorDomain
                               code:lockErrorCode
                           userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:
                        @"无法取得单实例锁：%@",
                        [NSString stringWithUTF8String:
                            strerror(lockErrorCode)]],
                }];
            }
        }

        _registrar = [CPSystemCursorRegistrar new];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        _desiredEnabled = [defaults objectForKey:@"desiredEnabled"] == nil
            ? YES
            : [defaults boolForKey:@"desiredEnabled"];
        NSString *savedProfile =
            [defaults stringForKey:@"animationProfile"];
        NSString *canonicalProfile =
            CPCanonicalAnimationProfile(savedProfile);
        if (![savedProfile isEqualToString:canonicalProfile]) {
            [defaults setObject:canonicalProfile
                         forKey:@"animationProfile"];
        }
        CGFloat savedScale = [defaults doubleForKey:@"cursorScale"];
        CGFloat canonicalScale = CPCanonicalScale(savedScale);
        if (savedScale == 0 ||
            fabs(savedScale - canonicalScale) >= 0.001) {
            [defaults setDouble:canonicalScale
                         forKey:@"cursorScale"];
        }
        _lastPreviewSizeIndex = -1;
        _lastPreviewSpeedIndex = -1;
        _applicationState = CPApplicationStatePreparing;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self installSignalHandlers];

    if (_previewPath != nil) {
        [self renderPreviewAndExit];
        return;
    }
    if (_liveProbe) {
        NSDictionary *probe = [_registrar liveCursorProbe];
        [self writeJSONAndExit:probe passed:YES];
        return;
    }
    if (_instanceLockError != nil) {
        if (_selfTest || _restoreOnly) {
            NSDictionary *result = @{
                @"passed": @NO,
                @"error": _instanceLockError.localizedDescription,
            };
            NSData *json = [NSJSONSerialization
                dataWithJSONObject:result
                           options:NSJSONWritingSortedKeys
                             error:nil];
            [NSFileHandle.fileHandleWithStandardOutput writeData:json];
            [NSFileHandle.fileHandleWithStandardOutput writeData:
                [@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            _exit(2);
        }
        [self showError:_instanceLockError];
        _terminationApproved = YES;
        [NSApp terminate:nil];
        return;
    }
    if (_secondaryInstance) {
        if (_selfTest || _restoreOnly) {
            NSDictionary *result = @{
                @"passed": @NO,
                @"error":
                    @"猫标正在运行。请先通过菜单栏退出，再执行此命令。",
            };
            NSData *json = [NSJSONSerialization
                dataWithJSONObject:result
                           options:NSJSONWritingSortedKeys
                             error:nil];
            [NSFileHandle.fileHandleWithStandardOutput writeData:json];
            [NSFileHandle.fileHandleWithStandardOutput writeData:
                [@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            _exit(2);
        }
        [NSDistributedNotificationCenter.defaultCenter
            postNotificationName:CPActivateExistingNotification
                          object:nil
                        userInfo:@{
                            @"showSettings": @YES,
                        }
              deliverImmediately:YES];
        _terminationApproved = YES;
        [NSApp terminate:nil];
        return;
    }
    if (_restoreOnly) {
        NSError *restoreError = nil;
        BOOL restored =
            [_registrar restoreStaleBackupWithError:&restoreError];
        NSMutableDictionary *result = [@{
            @"apiAvailable": @(_registrar.available),
            @"restored": @(restored),
            @"passed": @(restored),
        } mutableCopy];
        if (restoreError != nil) {
            result[@"error"] = restoreError.localizedDescription;
        }
        [self writeJSONAndExit:result passed:restored];
        return;
    }
    if (_selfTest) {
        [self runSelfTestAndExit];
        return;
    }

    [self buildStatusItem];
    [self observeSystemEvents];
    [self scheduleMenuBarAccessCheck];
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(showExistingStatusMenu:)
               name:CPActivateExistingNotification
             object:nil];
    if (_desiredEnabled) {
        [self enablePointerShowingError:YES];
    } else {
        _applicationState = CPApplicationStatePaused;
        [self refreshMenu];
    }
    if (_showSettingsOnLaunch) {
        [self showSettings:nil];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (!_terminationApproved) {
        [_registrar stop];
    }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
    (NSApplication *)sender {
    (void)sender;
    if (_hasPendingSettings) {
        [self applyPendingSettingsNow];
    }
    if (_terminationApproved) {
        return NSTerminateNow;
    }

    NSError *error = nil;
    if ([_registrar stopWithError:&error]) {
        _terminationApproved = YES;
        return NSTerminateNow;
    }
    [self showError:error];
    return NSTerminateCancel;
}

- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self refreshMenu];
}

- (void)buildStatusItem {
    _statusItem = [NSStatusBar.systemStatusBar
        statusItemWithLength:NSSquareStatusItemLength
    ];
    _statusItem.autosaveName = CPStatusItemAutosaveName;
    _statusItem.button.image = [self makeStatusIcon];
    _statusItem.button.imagePosition = NSImageOnly;
    _statusItem.button.toolTip = @"猫标 CatPointer";
    _statusItem.button.accessibilityLabel = @"猫标菜单";

    NSMenu *menu = [NSMenu new];
    menu.delegate = self;

    _toggleItem = [[NSMenuItem alloc]
        initWithTitle:@"启用猫标"
        action:@selector(togglePointer:)
        keyEquivalent:@""
    ];
    _toggleItem.target = self;
    [menu addItem:_toggleItem];

    _statusDescriptionItem = [[NSMenuItem alloc]
        initWithTitle:@"猫标正在准备"
        action:nil
        keyEquivalent:@""
    ];
    _statusDescriptionItem.enabled = NO;
    [menu addItem:_statusDescriptionItem];
    [menu addItem:NSMenuItem.separatorItem];

    _sizeParentItem = [[NSMenuItem alloc]
        initWithTitle:@"尺寸"
        action:nil
        keyEquivalent:@""
    ];
    NSMenu *sizeMenu = [[NSMenu alloc] initWithTitle:@"尺寸"];
    NSMutableArray<NSMenuItem *> *sizeItems = [NSMutableArray array];
    NSArray<NSArray *> *sizes = @[
        @[@"小", @0.8],
        @[@"偏小", @0.9],
        @[@"标准", @1.0],
        @[@"偏大", @1.1],
        @[@"大", @1.2],
    ];
    for (NSArray *entry in sizes) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:entry[0]
            action:@selector(chooseSize:)
            keyEquivalent:@""
        ];
        item.target = self;
        item.representedObject = entry[1];
        [sizeMenu addItem:item];
        [sizeItems addObject:item];
    }
    _sizeItems = sizeItems.copy;
    _sizeParentItem.submenu = sizeMenu;
    [menu addItem:_sizeParentItem];

    _animationParentItem = [[NSMenuItem alloc]
        initWithTitle:@"小猫动作速度"
        action:nil
        keyEquivalent:@""
    ];
    NSMenu *animationMenu =
        [[NSMenu alloc] initWithTitle:@"小猫动作速度"];
    NSMutableArray<NSMenuItem *> *animationItems =
        [NSMutableArray array];
    NSArray<NSArray<NSString *> *> *profiles = @[
        @[@"慢速", CPAnimationProfileSlow],
        @[@"适中", CPAnimationProfileMedium],
        @[@"快速", CPAnimationProfileFast],
        @[@"极致", CPAnimationProfileExtreme],
    ];
    for (NSArray<NSString *> *entry in profiles) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:entry[0]
            action:@selector(chooseAnimationProfile:)
            keyEquivalent:@""
        ];
        item.target = self;
        item.representedObject = entry[1];
        [animationMenu addItem:item];
        [animationItems addObject:item];
    }
    _animationItems = animationItems.copy;
    _animationParentItem.submenu = animationMenu;
    [menu addItem:_animationParentItem];

    NSMenuItem *settings = [[NSMenuItem alloc]
        initWithTitle:@"设置…"
        action:@selector(showSettings:)
        keyEquivalent:@","
    ];
    settings.target = self;
    [menu addItem:settings];

    [menu addItem:NSMenuItem.separatorItem];

    _reapplyItem = [[NSMenuItem alloc]
        initWithTitle:@"修复显示问题"
        action:@selector(reapplyPointer:)
        keyEquivalent:@""
    ];
    _reapplyItem.target = self;
    [menu addItem:_reapplyItem];

    _verifyItem = [[NSMenuItem alloc]
        initWithTitle:@"检查猫标…"
        action:@selector(verifyPointer:)
        keyEquivalent:@""
    ];
    _verifyItem.target = self;
    [menu addItem:_verifyItem];

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *about = [[NSMenuItem alloc]
        initWithTitle:@"关于猫标"
        action:@selector(showAbout:)
        keyEquivalent:@""
    ];
    about.target = self;
    [menu addItem:about];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"退出并恢复系统指针"
        action:@selector(quitAndRestore:)
        keyEquivalent:@"q"
    ];
    quit.target = self;
    [menu addItem:quit];
    _statusItem.menu = menu;
    [self refreshMenu];
}

- (void)refreshMenu {
    BOOL busy =
        _applicationState == CPApplicationStateVerifying ||
        _applicationState == CPApplicationStatePreparing;
    BOOL displayedEnabled =
        _applicationState == CPApplicationStateApplying
            ? _desiredEnabled
            : _registrar.enabled;
    _toggleItem.title = busy
        ? (_applicationState == CPApplicationStateVerifying
            ? @"正在检查…"
            : @"正在准备…")
        : (displayedEnabled
            ? @"暂停猫标"
            : @"启用猫标");
    _toggleItem.state = displayedEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    _toggleItem.enabled = !busy;

    if (!_registrar.available) {
        _statusDescriptionItem.title =
            @"当前 macOS 暂不支持猫标";
    } else if (_applicationState == CPApplicationStateVerifying) {
        _statusDescriptionItem.title =
            @"正在全面检查，通常需要几秒…";
    } else if (_applicationState == CPApplicationStateApplying) {
        if (_hasPendingSettings) {
            _statusDescriptionItem.title = [NSString stringWithFormat:
                @"正在切换到 %@ · %.0f%%…",
                CPSpeedDisplayName(_pendingProfile),
                _pendingScale * 100.0];
        } else if (_desiredEnabled && !_registrar.enabled) {
            _statusDescriptionItem.title = @"正在启用猫标…";
        } else if (!_desiredEnabled && _registrar.enabled) {
            _statusDescriptionItem.title =
                @"正在暂停并恢复系统指针…";
        } else {
            _statusDescriptionItem.title = @"正在刷新猫标…";
        }
    } else if (_applicationState == CPApplicationStatePreparing) {
        _statusDescriptionItem.title = @"正在准备猫标…";
    } else if (_applicationState == CPApplicationStateError) {
        _statusDescriptionItem.title = _lastBackgroundError == nil
            ? @"上次操作失败，可尝试“修复显示问题”或暂停猫标"
            : [NSString stringWithFormat:@"上次操作失败：%@",
                _lastBackgroundError.localizedDescription];
    } else if (_registrar.enabled) {
        CGFloat scale = _hasPendingSettings
            ? _pendingScale
            : _registrar.scale;
        NSString *profile = _hasPendingSettings
            ? _pendingProfile
            : [self savedAnimationProfile];
        _statusDescriptionItem.title = _hasPendingSettings
            ? [NSString stringWithFormat:
                @"正在应用 · %@ · %.0f%%",
                CPSpeedDisplayName(profile),
                scale * 100.0]
            : [NSString stringWithFormat:
                @"猫标已启用 · %@ · %.0f%%",
                CPSpeedDisplayName(profile),
                scale * 100.0];
    } else {
        _statusDescriptionItem.title =
            @"猫标已暂停 · 当前使用系统指针";
    }

    double currentScale = _hasPendingSettings
        ? _pendingScale
        : (_registrar.enabled ? _registrar.scale : [self savedScale]);
    for (NSMenuItem *item in _sizeItems) {
        item.state =
            fabs([item.representedObject doubleValue] - currentScale) <
                    0.01
                ? NSControlStateValueOn
                : NSControlStateValueOff;
    }

    NSString *profile = _hasPendingSettings
        ? _pendingProfile
        : [self savedAnimationProfile];
    for (NSMenuItem *item in _animationItems) {
        item.state =
            [item.representedObject isEqualToString:profile]
                ? NSControlStateValueOn
                : NSControlStateValueOff;
    }
    _sizeParentItem.title = [NSString stringWithFormat:
        @"尺寸 · %.0f%%",
        currentScale * 100.0];
    _animationParentItem.title = [NSString stringWithFormat:
        @"小猫动作速度 · %@",
        CPSpeedDisplayName(profile)];
    _sizeParentItem.enabled = !busy;
    _animationParentItem.enabled = !busy;
    _reapplyItem.enabled = !busy && _registrar.enabled;
    _verifyItem.enabled = !busy && _registrar.enabled;
    _statusItem.button.toolTip = displayedEnabled
        ? @"猫标已启用"
        : @"猫标已暂停，系统光标已恢复";
    [self refreshSettingsWindow];
}

- (double)savedScale {
    double saved = [NSUserDefaults.standardUserDefaults
        doubleForKey:@"cursorScale"
    ];
    return CPCanonicalScale(saved);
}

- (NSString *)savedAnimationProfile {
    NSString *saved = [NSUserDefaults.standardUserDefaults
        stringForKey:@"animationProfile"];
    return CPCanonicalAnimationProfile(saved);
}

- (CGFloat)effectiveFramesPerSecond {
    return CPFramesPerSecondForProfile([self savedAnimationProfile]);
}

- (void)prewarmSizeChoicesForProfile:(NSString *)profile {
    CGFloat currentScale = _registrar.enabled
        ? _registrar.scale
        : [self savedScale];
    [_registrar
        prewarmScales:CPSizeStepsStartingAtScale(currentScale)
 targetFramesPerSecond:CPFramesPerSecondForProfile(profile)];
}

- (BOOL)enablePointerShowingError:(BOOL)showError {
    _applicationState = CPApplicationStateApplying;
    _lastBackgroundError = nil;
    [self refreshMenu];
    NSError *error = nil;
    BOOL started = [_registrar
        startWithScale:[self savedScale]
 targetFramesPerSecond:[self effectiveFramesPerSecond]
                 error:&error];
    _desiredEnabled = started;
    _applicationState = started
        ? CPApplicationStateActive
        : CPApplicationStateError;
    _lastBackgroundError = started ? nil : error;
    if (started) {
        [NSUserDefaults.standardUserDefaults setBool:YES
                                              forKey:@"desiredEnabled"];
        [self prewarmSizeChoicesForProfile:
            [self savedAnimationProfile]];
        [_registrar waitForPrewarming];
    }
    [self refreshMenu];
    if (!started && showError) {
        [self showError:error ?: [NSError errorWithDomain:
            CPSystemCursorErrorDomain
                                                    code:100
                                                userInfo:@{
            NSLocalizedDescriptionKey:
                @"无法安装系统动画光标。",
        }]];
    }
    return started;
}

- (void)observeSystemEvents {
    NSNotificationCenter *workspaceCenter =
        NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self
                       selector:@selector(systemDidBecomeActive:)
                           name:
        NSWorkspaceSessionDidBecomeActiveNotification
                         object:nil];
    [workspaceCenter addObserver:self
                       selector:@selector(systemDidBecomeActive:)
                           name:NSWorkspaceScreensDidWakeNotification
                         object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(screenParametersDidChange:)
               name:NSApplicationDidChangeScreenParametersNotification
             object:nil
    ];
}

- (void)systemDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self scheduleSystemReapply];
    [self scheduleMenuBarAccessCheck];
}

- (void)screenParametersDidChange:(NSNotification *)notification {
    (void)notification;
    [self scheduleSystemReapply];
    [self scheduleMenuBarAccessCheck];
}

- (BOOL)statusItemNeedsDockFallback {
    NSButton *button = _statusItem.button;
    NSWindow *window = button.window;
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (screen == nil) {
        return NO;
    }
    NSRect buttonWindowFrame =
        [button convertRect:button.bounds toView:nil];
    NSRect buttonScreenFrame = window == nil
        ? NSZeroRect
        : [window convertRectToScreen:buttonWindowFrame];
    return CPMenuBarNeedsFallback(
        screen.frame,
        screen.safeAreaInsets,
        screen.auxiliaryTopRightArea,
        buttonScreenFrame,
        window.isVisible
    );
}

- (void)installFallbackMainMenu {
    if (NSApp.mainMenu != nil) {
        return;
    }

    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *applicationItem =
        [[NSMenuItem alloc] initWithTitle:@"猫标"
                                  action:nil
                           keyEquivalent:@""];
    [mainMenu addItem:applicationItem];

    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"猫标"];
    NSMenuItem *settings = [[NSMenuItem alloc]
        initWithTitle:@"设置…"
               action:@selector(showSettings:)
        keyEquivalent:@","];
    settings.target = self;
    [applicationMenu addItem:settings];
    [applicationMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"退出并恢复系统指针"
               action:@selector(quitAndRestore:)
        keyEquivalent:@"q"];
    quit.target = self;
    [applicationMenu addItem:quit];
    applicationItem.submenu = applicationMenu;
    NSApp.mainMenu = mainMenu;
}

- (void)updateMenuBarAccessFallback {
    BOOL shouldShowDock = [self statusItemNeedsDockFallback];
    if (shouldShowDock == _dockFallbackActive) {
        return;
    }

    if (shouldShowDock) {
        [self installFallbackMainMenu];
    }
    NSApplicationActivationPolicy policy = shouldShowDock
        ? NSApplicationActivationPolicyRegular
        : NSApplicationActivationPolicyAccessory;
    if ([NSApp setActivationPolicy:policy]) {
        _dockFallbackActive = shouldShowDock;
        [self refreshMenu];
    }
}

- (void)scheduleMenuBarAccessCheck {
    if (_statusItem == nil) {
        return;
    }
    NSUInteger generation = ++_menuBarAccessCheckGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC),
        dispatch_get_main_queue(),
        ^{
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil ||
                generation != strongSelf->_menuBarAccessCheckGeneration) {
                return;
            }
            [strongSelf updateMenuBarAccessFallback];
        }
    );
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self scheduleMenuBarAccessCheck];
}

- (void)scheduleSystemReapply {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf scheduleSystemReapply];
        });
        return;
    }

    if (!_desiredEnabled || !_registrar.enabled) {
        return;
    }

    if (_systemReapplyTimer != nil) {
        dispatch_source_cancel(_systemReapplyTimer);
    }
    _systemReapplyTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER,
        0,
        0,
        dispatch_get_main_queue()
    );
    dispatch_source_set_timer(
        _systemReapplyTimer,
        dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
        DISPATCH_TIME_FOREVER,
        200 * NSEC_PER_MSEC
    );
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_systemReapplyTimer, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_source_cancel(strongSelf->_systemReapplyTimer);
        strongSelf->_systemReapplyTimer = nil;
        [strongSelf performBackgroundReapply];
    });
    dispatch_resume(_systemReapplyTimer);
}

- (void)performBackgroundReapply {
    if (!_desiredEnabled || !_registrar.enabled ||
        _hasPendingSettings ||
        _applicationState == CPApplicationStateApplying ||
        _applicationState == CPApplicationStateVerifying) {
        return;
    }

    _applicationState = CPApplicationStateApplying;
    [self refreshMenu];
    NSError *error = nil;
    BOOL success = [_registrar
        reapplyWithScale:[self savedScale]
   targetFramesPerSecond:[self effectiveFramesPerSecond]
                   error:&error];
    _applicationState = success
        ? CPApplicationStateActive
        : CPApplicationStateError;
    _lastBackgroundError = success ? nil : error;
    if (success) {
        [self prewarmSizeChoicesForProfile:
            [self savedAnimationProfile]];
    }
    [self refreshMenu];
}

- (void)showExistingStatusMenu:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([notification.userInfo[@"showSettings"] boolValue] ||
            [self statusItemNeedsDockFallback]) {
            [self showSettings:nil];
        } else {
            [self->_statusItem.button performClick:nil];
        }
    });
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender
                    hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)sender;
    (void)hasVisibleWindows;
    [self showSettings:nil];
    return YES;
}

- (void)installSignalHandlers {
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);

    __weak typeof(self) weakSelf = self;
    _terminationSignal = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        SIGTERM,
        0,
        dispatch_get_main_queue()
    );
    dispatch_source_set_event_handler(_terminationSignal, ^{
        [weakSelf quitAndRestore:nil];
    });
    dispatch_resume(_terminationSignal);

    _interruptSignal = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        SIGINT,
        0,
        dispatch_get_main_queue()
    );
    dispatch_source_set_event_handler(_interruptSignal, ^{
        [weakSelf quitAndRestore:nil];
    });
    dispatch_resume(_interruptSignal);
}

- (NSImage *)makeStatusIcon {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(18, 18)
        flipped:NO
        drawingHandler:^BOOL(NSRect rect) {
            (void)rect;
            [NSColor.labelColor setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(5, 3, 8, 7)]
                fill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, 9, 4, 5)]
                fill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(6, 12, 4, 5)]
                fill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(11, 10, 4, 5)]
                fill];
            return YES;
        }
    ];
    image.template = YES;
    return image;
}

- (void)showSettings:(id)sender {
    (void)sender;
    if (_settingsWindow == nil) {
        [self buildSettingsWindow];
    }
    [self refreshSettingsWindow];
    [NSApp activateIgnoringOtherApps:YES];
    [_settingsWindow makeKeyAndOrderFront:nil];
}

- (void)buildSettingsWindow {
    NSRect frame = NSMakeRect(0, 0, 500, 400);
    _settingsWindow = [[CPSettingsWindow alloc]
        initWithContentRect:frame
                  styleMask:
            NSWindowStyleMaskTitled |
            NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO
    ];
    _settingsWindow.title = @"猫标设置";
    _settingsWindow.releasedWhenClosed = NO;
    _settingsWindow.movableByWindowBackground = YES;
    BOOL restoredFrame = [_settingsWindow
        setFrameUsingName:CPSettingsWindowFrameAutosaveName];
    [_settingsWindow
        setFrameAutosaveName:CPSettingsWindowFrameAutosaveName];
    if (!restoredFrame) {
        [_settingsWindow center];
    }

    NSView *content = _settingsWindow.contentView;
    content.wantsLayer = YES;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.image = [self makeStatusIcon];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [icon setAccessibilityElement:NO];

    NSTextField *title =
        [NSTextField labelWithString:@"猫标 CatPointer"];
    title.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];

    NSTextField *subtitle = [NSTextField labelWithString:
        @"原作猫标 · 7 类常用指针动作同步生效"];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.font = [NSFont systemFontOfSize:12];

    _settingsEnableLabelButton =
        [NSButton buttonWithTitle:@"启用猫标"
                           target:self
                           action:@selector(toggleSettingsSwitchFromLabel:)];
    _settingsEnableLabelButton.bordered = NO;
    _settingsEnableLabelButton.font =
        [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _settingsEnableLabelButton.contentTintColor =
        NSColor.secondaryLabelColor;
    _settingsEnableLabelButton.toolTip =
        @"点按文字或开关都可以启用、暂停猫标。";
    [_settingsEnableLabelButton setAccessibilityElement:NO];

    _settingsEnableSwitch = [[NSSwitch alloc] initWithFrame:NSZeroRect];
    _settingsEnableSwitch.target = self;
    _settingsEnableSwitch.action = @selector(togglePointer:);
    _settingsEnableSwitch.controlSize = NSControlSizeSmall;
    _settingsEnableSwitch.accessibilityLabel = @"启用猫标";
    _settingsEnableSwitch.toolTip =
        @"关闭后立即恢复系统指针；当前尺寸和速度会保留。";

    _settingsStatusIndicator =
        [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage *statusDot =
        [NSImage imageWithSystemSymbolName:@"circle.fill"
                  accessibilityDescription:nil];
    _settingsStatusIndicator.image = [statusDot
        imageWithSymbolConfiguration:
            [NSImageSymbolConfiguration
                configurationWithPointSize:7
                                    weight:NSFontWeightSemibold]];
    _settingsStatusIndicator.imageScaling =
        NSImageScaleProportionallyUpOrDown;
    [_settingsStatusIndicator setAccessibilityElement:NO];

    _settingsProgressIndicator =
        [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _settingsProgressIndicator.style =
        NSProgressIndicatorStyleSpinning;
    _settingsProgressIndicator.controlSize = NSControlSizeSmall;
    _settingsProgressIndicator.indeterminate = YES;
    _settingsProgressIndicator.displayedWhenStopped = NO;
    _settingsProgressIndicator.hidden = YES;
    [_settingsProgressIndicator setAccessibilityElement:NO];

    _settingsStatusLabel =
        [NSTextField wrappingLabelWithString:@"正在读取状态…"];
    _settingsStatusLabel.font =
        [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _settingsStatusLabel.maximumNumberOfLines = 2;
    _settingsStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;

    NSTextField *sizeLabel = [NSTextField labelWithString:@"指针尺寸"];
    sizeLabel.font =
        [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _settingsSizeValueLabel =
        [NSTextField labelWithString:@"标准 · 100%"];
    _settingsSizeValueLabel.font =
        [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _settingsSizeValueLabel.textColor = NSColor.controlAccentColor;
    _settingsSizeValueLabel.alignment = NSTextAlignmentRight;
    [_settingsSizeValueLabel setAccessibilityElement:NO];

    _settingsSizeSlider =
        [[CPCommitSlider alloc] initWithFrame:NSZeroRect];
    _settingsSizeSlider.minValue = 0;
    _settingsSizeSlider.maxValue = 4;
    _settingsSizeSlider.doubleValue = 2;
    _settingsSizeSlider.target = self;
    _settingsSizeSlider.action =
        @selector(settingsSizePreviewChanged:);
    _settingsSizeSlider.commitTarget = self;
    _settingsSizeSlider.commitAction =
        @selector(settingsSizeCommitted:);
    _settingsSizeSlider.continuous = YES;
    _settingsSizeSlider.numberOfTickMarks = 5;
    _settingsSizeSlider.tickMarkPosition = NSTickMarkPositionBelow;
    _settingsSizeSlider.allowsTickMarkValuesOnly = YES;
    _settingsSizeSlider.altIncrementValue = 1;
    _settingsSizeSlider.controlSize = NSControlSizeLarge;
    _settingsSizeSlider.accessibilityLabel = @"指针尺寸";
    _settingsSizeSlider.accessibilityHelp =
        @"拖动选择档位，松开后应用；也可使用左右方向键逐档调整。";
    _settingsSizeSlider.toolTip =
        @"拖动选择指针尺寸，松开后应用到鼠标指针。";

    NSMutableArray<NSView *> *sizeTickLabels =
        [NSMutableArray array];
    for (NSString *text in
         @[@"80%", @"90%", @"100%", @"110%", @"120%"]) {
        NSTextField *label = [NSTextField labelWithString:text];
        label.font = [NSFont systemFontOfSize:10.5];
        label.textColor = NSColor.tertiaryLabelColor;
        label.alignment = NSTextAlignmentCenter;
        [label setAccessibilityElement:NO];
        [sizeTickLabels addObject:label];
    }
    _settingsSizeTickLabels = sizeTickLabels.copy;
    NSStackView *sizeTicks =
        [NSStackView stackViewWithViews:sizeTickLabels];
    sizeTicks.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    sizeTicks.distribution = NSStackViewDistributionEqualCentering;
    sizeTicks.spacing = 0;

    NSTextField *animationLabel =
        [NSTextField labelWithString:@"小猫动作速度"];
    animationLabel.font =
        [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _settingsSpeedValueLabel =
        [NSTextField labelWithString:@"极致"];
    _settingsSpeedValueLabel.font =
        [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _settingsSpeedValueLabel.textColor = NSColor.controlAccentColor;
    _settingsSpeedValueLabel.alignment = NSTextAlignmentRight;
    [_settingsSpeedValueLabel setAccessibilityElement:NO];

    _settingsSpeedSlider =
        [[CPCommitSlider alloc] initWithFrame:NSZeroRect];
    _settingsSpeedSlider.minValue = 0;
    _settingsSpeedSlider.maxValue = 3;
    _settingsSpeedSlider.doubleValue = 3;
    _settingsSpeedSlider.target = self;
    _settingsSpeedSlider.action =
        @selector(settingsSpeedPreviewChanged:);
    _settingsSpeedSlider.commitTarget = self;
    _settingsSpeedSlider.commitAction =
        @selector(settingsSpeedCommitted:);
    _settingsSpeedSlider.continuous = YES;
    _settingsSpeedSlider.numberOfTickMarks = 4;
    _settingsSpeedSlider.tickMarkPosition = NSTickMarkPositionBelow;
    _settingsSpeedSlider.allowsTickMarkValuesOnly = YES;
    _settingsSpeedSlider.altIncrementValue = 1;
    _settingsSpeedSlider.controlSize = NSControlSizeLarge;
    _settingsSpeedSlider.accessibilityLabel = @"小猫动作速度";
    _settingsSpeedSlider.accessibilityHelp =
        @"只改变小猫动作快慢，不改变鼠标移动速度。"
         "拖动选择档位，松开后应用。";
    _settingsSpeedSlider.toolTip =
        @"拖动选择小猫动作速度，松开后应用到小猫动画；"
         "不改变鼠标移动速度。";

    NSMutableArray<NSView *> *speedTickLabels =
        [NSMutableArray array];
    for (NSString *text in @[@"慢", @"适中", @"快", @"极致"]) {
        NSTextField *label = [NSTextField labelWithString:text];
        label.font = [NSFont systemFontOfSize:10.5];
        label.textColor = NSColor.tertiaryLabelColor;
        label.alignment = NSTextAlignmentCenter;
        [label setAccessibilityElement:NO];
        [speedTickLabels addObject:label];
    }
    _settingsSpeedTickLabels = speedTickLabels.copy;
    NSStackView *speedTicks =
        [NSStackView stackViewWithViews:speedTickLabels];
    speedTicks.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    speedTicks.distribution = NSStackViewDistributionEqualCentering;
    speedTicks.spacing = 0;

    _settingsExplanationLabel = [NSTextField wrappingLabelWithString:
        @"拖动选择档位，松开后应用；也可用 ← → 逐档调整。\n"
        @"只改变猫标外观，不改变鼠标移动速度，也不影响点击、拖拽、"
        @"滚动或输入。"];
    _settingsExplanationLabel.textColor = NSColor.secondaryLabelColor;
    _settingsExplanationLabel.font = [NSFont systemFontOfSize:11.5];

    _settingsVerifyButton =
        [NSButton buttonWithTitle:@"检查是否正常…"
                           target:self
                           action:@selector(verifyPointer:)];
    _settingsVerifyButton.bezelStyle = NSBezelStyleRounded;
    _settingsVerifyButton.toolTip =
        @"检查 7 类指针、五档尺寸、四档速度和安全恢复，通常需要几秒。";

    _settingsResetButton =
        [NSButton buttonWithTitle:@"恢复默认"
                           target:self
                           action:@selector(resetSettings:)];
    _settingsResetButton.bezelStyle = NSBezelStyleRounded;
    _settingsResetButton.toolTip = @"恢复为标准 100% 和极致速度。";

    NSArray<NSView *> *views = @[
        icon,
        title,
        subtitle,
        _settingsEnableLabelButton,
        _settingsEnableSwitch,
        _settingsStatusIndicator,
        _settingsProgressIndicator,
        _settingsStatusLabel,
        sizeLabel,
        _settingsSizeValueLabel,
        _settingsSizeSlider,
        sizeTicks,
        animationLabel,
        _settingsSpeedValueLabel,
        _settingsSpeedSlider,
        speedTicks,
        _settingsExplanationLabel,
        _settingsVerifyButton,
        _settingsResetButton,
    ];
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                          constant:24],
        [icon.topAnchor constraintEqualToAnchor:content.topAnchor
                                       constant:23],
        [icon.widthAnchor constraintEqualToConstant:34],
        [icon.heightAnchor constraintEqualToConstant:34],

        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                            constant:12],
        [title.topAnchor constraintEqualToAnchor:content.topAnchor
                                         constant:20],
        [title.trailingAnchor
            constraintLessThanOrEqualToAnchor:
                _settingsEnableLabelButton.leadingAnchor
            constant:-12],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                            constant:2],
        [subtitle.trailingAnchor
            constraintLessThanOrEqualToAnchor:content.trailingAnchor
            constant:-24],
        [_settingsEnableSwitch.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsEnableSwitch.centerYAnchor
            constraintEqualToAnchor:title.centerYAnchor],
        [_settingsEnableLabelButton.trailingAnchor
            constraintEqualToAnchor:_settingsEnableSwitch.leadingAnchor
            constant:-7],
        [_settingsEnableLabelButton.centerYAnchor
            constraintEqualToAnchor:_settingsEnableSwitch.centerYAnchor],

        [_settingsStatusIndicator.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_settingsStatusIndicator.widthAnchor constraintEqualToConstant:8],
        [_settingsStatusIndicator.heightAnchor constraintEqualToConstant:8],
        [_settingsProgressIndicator.centerXAnchor
            constraintEqualToAnchor:_settingsStatusIndicator.centerXAnchor],
        [_settingsProgressIndicator.centerYAnchor
            constraintEqualToAnchor:_settingsStatusIndicator.centerYAnchor],
        [_settingsProgressIndicator.widthAnchor constraintEqualToConstant:14],
        [_settingsProgressIndicator.heightAnchor constraintEqualToConstant:14],
        [_settingsStatusLabel.leadingAnchor
            constraintEqualToAnchor:_settingsStatusIndicator.trailingAnchor
            constant:7],
        [_settingsStatusLabel.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsStatusLabel.topAnchor
            constraintEqualToAnchor:icon.bottomAnchor constant:15],
        [_settingsStatusIndicator.centerYAnchor
            constraintEqualToAnchor:_settingsStatusLabel.centerYAnchor],

        [sizeLabel.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [sizeLabel.topAnchor
            constraintEqualToAnchor:_settingsStatusLabel.bottomAnchor
            constant:20],
        [_settingsSizeValueLabel.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsSizeValueLabel.centerYAnchor
            constraintEqualToAnchor:sizeLabel.centerYAnchor],
        [_settingsSizeSlider.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_settingsSizeSlider.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsSizeSlider.topAnchor
            constraintEqualToAnchor:sizeLabel.bottomAnchor constant:7],
        [sizeTicks.leadingAnchor
            constraintEqualToAnchor:_settingsSizeSlider.leadingAnchor
            constant:7],
        [sizeTicks.trailingAnchor
            constraintEqualToAnchor:_settingsSizeSlider.trailingAnchor
            constant:-7],
        [sizeTicks.topAnchor
            constraintEqualToAnchor:_settingsSizeSlider.bottomAnchor
            constant:-1],
        [sizeTicks.heightAnchor constraintEqualToConstant:15],

        [animationLabel.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [animationLabel.topAnchor
            constraintEqualToAnchor:sizeTicks.bottomAnchor constant:20],
        [_settingsSpeedValueLabel.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsSpeedValueLabel.centerYAnchor
            constraintEqualToAnchor:animationLabel.centerYAnchor],
        [_settingsSpeedSlider.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_settingsSpeedSlider.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsSpeedSlider.topAnchor
            constraintEqualToAnchor:animationLabel.bottomAnchor constant:7],
        [speedTicks.leadingAnchor
            constraintEqualToAnchor:_settingsSpeedSlider.leadingAnchor
            constant:7],
        [speedTicks.trailingAnchor
            constraintEqualToAnchor:_settingsSpeedSlider.trailingAnchor
            constant:-7],
        [speedTicks.topAnchor
            constraintEqualToAnchor:_settingsSpeedSlider.bottomAnchor
            constant:-1],
        [speedTicks.heightAnchor constraintEqualToConstant:15],

        [_settingsExplanationLabel.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_settingsExplanationLabel.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsExplanationLabel.topAnchor
            constraintEqualToAnchor:speedTicks.bottomAnchor constant:19],

        [_settingsVerifyButton.leadingAnchor
            constraintEqualToAnchor:content.leadingAnchor constant:24],
        [_settingsVerifyButton.bottomAnchor
            constraintEqualToAnchor:content.bottomAnchor constant:-22],
        [_settingsResetButton.trailingAnchor
            constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [_settingsResetButton.bottomAnchor
            constraintEqualToAnchor:content.bottomAnchor constant:-22],
    ]];

    _settingsWindow.initialFirstResponder = _settingsSizeSlider;
    _settingsSizeSlider.nextKeyView = _settingsSpeedSlider;
    _settingsSpeedSlider.nextKeyView = _settingsVerifyButton;
    _settingsVerifyButton.nextKeyView = _settingsResetButton;
    _settingsResetButton.nextKeyView = _settingsEnableSwitch;
    _settingsEnableSwitch.nextKeyView = _settingsSizeSlider;
}

- (void)updateTickLabels:(NSArray<NSTextField *> *)labels
           selectedIndex:(NSInteger)selectedIndex {
    for (NSUInteger index = 0; index < labels.count; index++) {
        BOOL selected = (NSInteger)index == selectedIndex;
        NSTextField *label = labels[index];
        label.textColor = selected
            ? NSColor.controlAccentColor
            : NSColor.tertiaryLabelColor;
        label.font = [NSFont
            systemFontOfSize:10.5
                      weight:selected
                ? NSFontWeightSemibold
                : NSFontWeightRegular];
    }
}

- (void)updateSizePreviewAtIndex:(NSInteger)index
                  performHaptic:(BOOL)performHaptic {
    index = MAX(0, MIN(
        index,
        (NSInteger)CPSizeSteps().count - 1
    ));
    CGFloat scale = CPSizeSteps()[index].doubleValue;
    _settingsSizeValueLabel.stringValue = [NSString stringWithFormat:
        @"%@ · %.0f%%",
        CPSizeDisplayName(scale),
        scale * 100.0];
    _settingsSizeSlider.accessibilityValueDescription =
        _settingsSizeValueLabel.stringValue;
    _settingsSizeSlider.toolTip = [NSString stringWithFormat:
        @"当前选择：%@。松开后应用到鼠标指针。",
        _settingsSizeValueLabel.stringValue];
    [self updateTickLabels:_settingsSizeTickLabels selectedIndex:index];
    if (performHaptic && _lastPreviewSizeIndex >= 0 &&
        _lastPreviewSizeIndex != index) {
        [NSHapticFeedbackManager.defaultPerformer
            performFeedbackPattern:NSHapticFeedbackPatternAlignment
                 performanceTime:NSHapticFeedbackPerformanceTimeNow];
    }
    _lastPreviewSizeIndex = index;
}

- (void)updateSpeedPreviewAtIndex:(NSInteger)index
                   performHaptic:(BOOL)performHaptic {
    index = MAX(0, MIN(
        index,
        (NSInteger)CPAnimationProfiles().count - 1
    ));
    NSString *profile = CPAnimationProfiles()[index];
    _settingsSpeedValueLabel.stringValue =
        CPSpeedDisplayName(profile);
    _settingsSpeedSlider.accessibilityValueDescription =
        _settingsSpeedValueLabel.stringValue;
    _settingsSpeedSlider.toolTip = [NSString stringWithFormat:
        @"当前选择：%@。松开后应用到小猫动画，不改变鼠标移动速度。",
        _settingsSpeedValueLabel.stringValue];
    [self updateTickLabels:_settingsSpeedTickLabels selectedIndex:index];
    if (performHaptic && _lastPreviewSpeedIndex >= 0 &&
        _lastPreviewSpeedIndex != index) {
        [NSHapticFeedbackManager.defaultPerformer
            performFeedbackPattern:NSHapticFeedbackPatternAlignment
                 performanceTime:NSHapticFeedbackPerformanceTimeNow];
    }
    _lastPreviewSpeedIndex = index;
}

- (void)announceAccessibilityMessage:(NSString *)message {
    if (message.length == 0) {
        return;
    }
    NSAccessibilityPostNotificationWithUserInfo(
        NSApp,
        NSAccessibilityAnnouncementRequestedNotification,
        @{
            NSAccessibilityAnnouncementKey: message,
            NSAccessibilityPriorityKey:
                @(NSAccessibilityPriorityMedium),
        }
    );
}

- (void)showTransientSettingsStatus:(NSString *)message
                           duration:(NSTimeInterval)duration
                       announcement:(nullable NSString *)announcement {
    _settingsTransientStatus = [message copy];
    NSUInteger generation = ++_settingsTransientStatusGeneration;
    [self refreshMenu];
    [self announceAccessibilityMessage:announcement];
    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(duration * NSEC_PER_SEC)
        ),
        dispatch_get_main_queue(),
        ^{
            if (generation !=
                self->_settingsTransientStatusGeneration) {
                return;
            }
            self->_settingsTransientStatus = nil;
            [self refreshMenu];
        }
    );
}

- (void)refreshSettingsWindow {
    if (_settingsWindow == nil) {
        return;
    }

    NSString *statusText = nil;
    NSColor *indicatorColor = NSColor.secondaryLabelColor;
    if (!_registrar.available) {
        statusText = @"当前 macOS 暂不支持猫标";
        indicatorColor = NSColor.systemRedColor;
    } else if (_applicationState == CPApplicationStateVerifying) {
        statusText = @"正在全面检查，通常需要几秒…";
        indicatorColor = NSColor.controlAccentColor;
    } else if (_applicationState == CPApplicationStateApplying) {
        if (_hasPendingSettings) {
            statusText = [NSString stringWithFormat:
                @"正在切换到 %@ · %.0f%%…",
                CPSpeedDisplayName(_pendingProfile),
                _pendingScale * 100.0];
        } else if (_desiredEnabled && !_registrar.enabled) {
            statusText = @"正在启用猫标…";
        } else if (!_desiredEnabled && _registrar.enabled) {
            statusText = @"正在暂停并恢复系统指针…";
        } else {
            statusText = @"正在刷新猫标…";
        }
        indicatorColor = NSColor.controlAccentColor;
    } else if (_applicationState == CPApplicationStatePreparing) {
        statusText = @"正在准备猫标…";
        indicatorColor = NSColor.controlAccentColor;
    } else if (_applicationState == CPApplicationStateError) {
        statusText = _lastBackgroundError == nil
            ? @"上次操作失败，请暂停后重新启用"
            : [NSString stringWithFormat:@"应用失败：%@",
                _lastBackgroundError.localizedDescription];
        indicatorColor = NSColor.systemRedColor;
    } else if (_settingsTransientStatus.length > 0) {
        statusText = _settingsTransientStatus;
        indicatorColor = NSColor.systemGreenColor;
    } else if (_registrar.enabled) {
        statusText = _dockFallbackActive
            ? @"已启用 · 菜单栏空间不足，已保留 Dock 入口"
            : [NSString stringWithFormat:
                @"已启用 · %@ · %.0f%%",
                CPSpeedDisplayName([self savedAnimationProfile]),
                _registrar.scale * 100.0];
        indicatorColor = NSColor.systemGreenColor;
    } else {
        statusText = _dockFallbackActive
            ? @"已暂停 · 菜单栏空间不足，已保留 Dock 入口"
            : @"已暂停 · 当前使用系统指针";
    }
    _settingsStatusLabel.stringValue = statusText ?: @"正在读取状态…";
    _settingsStatusLabel.textColor = NSColor.secondaryLabelColor;
    _settingsStatusLabel.accessibilityLabel = @"猫标状态";
    _settingsStatusLabel.accessibilityValue =
        _settingsStatusLabel.stringValue;
    _settingsStatusIndicator.contentTintColor = indicatorColor;
    BOOL checking = _applicationState == CPApplicationStateVerifying;
    _settingsStatusIndicator.hidden = checking;
    _settingsProgressIndicator.hidden = !checking;
    if (checking) {
        [_settingsProgressIndicator startAnimation:nil];
    } else {
        [_settingsProgressIndicator stopAnimation:nil];
    }
    BOOL explanationUsesEnabledBehavior =
        _applicationState == CPApplicationStateApplying
            ? _desiredEnabled
            : _registrar.enabled;
    _settingsExplanationLabel.stringValue = explanationUsesEnabledBehavior
        ? @"拖动选择档位，松开后应用；也可用 ← → 逐档调整。\n"
          @"只改变猫标外观，不改变鼠标移动速度，也不影响点击、"
          @"拖拽、滚动或输入。"
        : @"调整会自动保存，重新启用时使用；也可用 ← → 逐档调整。\n"
          @"只改变猫标外观，不改变鼠标移动速度，也不影响点击、"
          @"拖拽、滚动或输入。";

    double scale =
        _hasPendingSettings
            ? _pendingScale
            : (_registrar.enabled ? _registrar.scale : [self savedScale]);
    NSUInteger sizeIndex = [CPSizeSteps() indexOfObjectPassingTest:
        ^BOOL(NSNumber *value, NSUInteger index, BOOL *stop) {
            (void)index;
            (void)stop;
            return fabs(value.doubleValue - scale) < 0.001;
        }];
    if (sizeIndex == NSNotFound) {
        sizeIndex = 2;
    }
    if (!_settingsSizeSlider.isMouseTracking) {
        _settingsSizeSlider.doubleValue = sizeIndex;
        [self updateSizePreviewAtIndex:(NSInteger)sizeIndex
                        performHaptic:NO];
    }

    NSString *profile = _hasPendingSettings
        ? _pendingProfile
        : [self savedAnimationProfile];
    NSUInteger speedIndex =
        [CPAnimationProfiles() indexOfObject:profile];
    if (speedIndex == NSNotFound) {
        speedIndex = CPAnimationProfiles().count - 1;
    }
    if (!_settingsSpeedSlider.isMouseTracking) {
        _settingsSpeedSlider.doubleValue = speedIndex;
        [self updateSpeedPreviewAtIndex:(NSInteger)speedIndex
                         performHaptic:NO];
    }

    BOOL busy =
        _applicationState == CPApplicationStateVerifying ||
        _applicationState == CPApplicationStatePreparing;
    BOOL interactive = _registrar.available && !busy;
    _settingsSizeSlider.enabled = interactive;
    _settingsSpeedSlider.enabled = interactive;
    _settingsEnableSwitch.enabled = interactive;
    _settingsEnableLabelButton.enabled = interactive;
    BOOL switchShouldAppearEnabled =
        _applicationState == CPApplicationStateApplying
            ? _desiredEnabled
            : _registrar.enabled;
    _settingsEnableSwitch.state = switchShouldAppearEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    _settingsVerifyButton.enabled =
        interactive && _registrar.enabled && !_hasPendingSettings;
    _settingsVerifyButton.toolTip = !_registrar.enabled
        ? @"启用猫标后可进行完整检查。"
        : (_hasPendingSettings
            ? @"当前设置应用后即可检查。"
            : @"检查 7 类指针、五档尺寸、四档速度和安全恢复，通常需要几秒。");
    BOOL usesDefaults =
        fabs(scale - 1.0) < 0.001 &&
        [profile isEqualToString:CPAnimationProfileExtreme];
    _settingsResetButton.enabled = interactive && !usesDefaults;
}

- (void)settingsSizePreviewChanged:(CPCommitSlider *)sender {
    NSInteger index = (NSInteger)llround(sender.doubleValue);
    index = MAX(0, MIN(
        index,
        (NSInteger)CPSizeSteps().count - 1
    ));
    sender.doubleValue = index;
    [self updateSizePreviewAtIndex:index
                    performHaptic:sender.isMouseTracking];
    if (sender.isMouseTracking) {
        _settingsStatusLabel.stringValue =
            @"正在选择指针尺寸 · 松开后应用";
        _settingsStatusLabel.accessibilityValue =
            _settingsStatusLabel.stringValue;
        _settingsStatusIndicator.contentTintColor =
            NSColor.controlAccentColor;
        return;
    }
    [self settingsSizeCommitted:sender];
}

- (void)settingsSizeCommitted:(CPCommitSlider *)sender {
    NSInteger index = (NSInteger)llround(sender.doubleValue);
    index = MAX(0, MIN(
        index,
        (NSInteger)CPSizeSteps().count - 1
    ));
    sender.doubleValue = index;
    [self updateSizePreviewAtIndex:index performHaptic:NO];
    CGFloat scale = CPSizeSteps()[index].doubleValue;
    NSString *profile = _hasPendingSettings
        ? _pendingProfile
        : [self savedAnimationProfile];
    NSEvent *event = NSApp.currentEvent;
    NSTimeInterval delay =
        event.type == NSEventTypeKeyDown && event.isARepeat
            ? 0.075
            : 0;
    [self queueSettingsScale:scale profile:profile afterDelay:delay];
}

- (void)settingsSpeedPreviewChanged:(CPCommitSlider *)sender {
    NSInteger index = (NSInteger)llround(sender.doubleValue);
    index = MAX(0, MIN(
        index,
        (NSInteger)CPAnimationProfiles().count - 1
    ));
    sender.doubleValue = index;
    [self updateSpeedPreviewAtIndex:index
                     performHaptic:sender.isMouseTracking];
    if (sender.isMouseTracking) {
        _settingsStatusLabel.stringValue =
            @"正在选择小猫动作速度 · 松开后应用";
        _settingsStatusLabel.accessibilityValue =
            _settingsStatusLabel.stringValue;
        _settingsStatusIndicator.contentTintColor =
            NSColor.controlAccentColor;
        return;
    }
    [self settingsSpeedCommitted:sender];
}

- (void)settingsSpeedCommitted:(CPCommitSlider *)sender {
    NSInteger index = (NSInteger)llround(sender.doubleValue);
    index = MAX(0, MIN(
        index,
        (NSInteger)CPAnimationProfiles().count - 1
    ));
    sender.doubleValue = index;
    [self updateSpeedPreviewAtIndex:index performHaptic:NO];
    CGFloat scale = _hasPendingSettings
        ? _pendingScale
        : (_registrar.enabled ? _registrar.scale : [self savedScale]);
    NSEvent *event = NSApp.currentEvent;
    NSTimeInterval delay =
        event.type == NSEventTypeKeyDown && event.isARepeat
            ? 0.075
            : 0;
    [self queueSettingsScale:scale
                     profile:CPAnimationProfiles()[index]
                  afterDelay:delay];
}

- (void)togglePointer:(id)sender {
    _settingsTransientStatus = nil;
    _settingsTransientStatusGeneration++;
    BOOL shouldEnable = sender == _settingsEnableSwitch
        ? _settingsEnableSwitch.state == NSControlStateValueOn
        : !_registrar.enabled;
    if (shouldEnable == _registrar.enabled) {
        [self refreshMenu];
        return;
    }
    _desiredEnabled = shouldEnable;

    if (_hasPendingSettings && !shouldEnable) {
        [self persistPendingSettingsAndCancel];
    } else if (_hasPendingSettings) {
        [self applyPendingSettingsNow];
    }
    if (!shouldEnable) {
        _applicationState = CPApplicationStateApplying;
        [self refreshMenu];
        NSError *error = nil;
        if ([_registrar stopWithError:&error]) {
            _desiredEnabled = NO;
            _applicationState = CPApplicationStatePaused;
            _lastBackgroundError = nil;
            [NSUserDefaults.standardUserDefaults setBool:NO
                                                  forKey:@"desiredEnabled"];
            [self announceAccessibilityMessage:
                @"猫标已暂停，系统指针已恢复"];
        } else {
            _desiredEnabled = YES;
            _applicationState = CPApplicationStateError;
            _lastBackgroundError = error;
            [self showError:error];
        }
    } else {
        _desiredEnabled = YES;
        if ([self enablePointerShowingError:YES]) {
            [self announceAccessibilityMessage:@"猫标已启用"];
        }
    }
    [self refreshMenu];
}

- (void)toggleSettingsSwitchFromLabel:(id)sender {
    (void)sender;
    if (!_settingsEnableSwitch.enabled) {
        return;
    }
    _settingsEnableSwitch.state =
        _settingsEnableSwitch.state == NSControlStateValueOn
            ? NSControlStateValueOff
            : NSControlStateValueOn;
    [self togglePointer:_settingsEnableSwitch];
}

- (void)resetSettings:(id)sender {
    (void)sender;
    [self queueSettingsScale:1.0
                     profile:CPAnimationProfileExtreme
                  afterDelay:0];
}

- (void)chooseSize:(NSMenuItem *)sender {
    CGFloat scale = [sender.representedObject doubleValue];
    NSString *profile = _hasPendingSettings
        ? _pendingProfile
        : [self savedAnimationProfile];
    [self queueSettingsScale:scale
                     profile:profile];
}

- (void)chooseAnimationProfile:(NSMenuItem *)sender {
    CGFloat scale = _hasPendingSettings
        ? _pendingScale
        : (_registrar.enabled ? _registrar.scale : [self savedScale]);
    [self queueSettingsScale:scale
                     profile:sender.representedObject];
}

- (void)queueSettingsScale:(CGFloat)scale
                   profile:(NSString *)profile {
    [self queueSettingsScale:scale profile:profile afterDelay:0];
}

- (void)queueSettingsScale:(CGFloat)scale
                   profile:(NSString *)profile
                afterDelay:(NSTimeInterval)delay {
    CGFloat quantizedScale = CPCanonicalScale(scale);
    NSString *canonicalProfile =
        CPCanonicalAnimationProfile(profile);

    CGFloat appliedScale = _registrar.enabled
        ? _registrar.scale
        : [self savedScale];
    NSString *appliedProfile = [self savedAnimationProfile];
    if (fabs(appliedScale - quantizedScale) < 0.001 &&
        [appliedProfile isEqualToString:canonicalProfile]) {
        if (_hasPendingSettings) {
            [self cancelPendingSettings];
            _applicationState = _registrar.enabled
                ? CPApplicationStateActive
                : CPApplicationStatePaused;
        }
        [self refreshMenu];
        return;
    }
    if (_hasPendingSettings &&
        fabs(_pendingScale - quantizedScale) < 0.001 &&
        [_pendingProfile isEqualToString:canonicalProfile]) {
        [self refreshMenu];
        return;
    }

    _pendingScale = quantizedScale;
    _pendingProfile = canonicalProfile;
    _hasPendingSettings = YES;
    _settingsTransientStatus = nil;
    _settingsTransientStatusGeneration++;
    _applicationState = CPApplicationStateApplying;
    [self refreshMenu];
    [_settingsWindow displayIfNeeded];

    NSUInteger generation = ++_settingsCommitGeneration;
    dispatch_block_t applyBlock = ^{
        if (generation != self->_settingsCommitGeneration ||
            !self->_hasPendingSettings) {
            return;
        }
        [self applyPendingSettingsNow];
    };
    if (delay > 0) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(delay * NSEC_PER_SEC)
            ),
            dispatch_get_main_queue(),
            applyBlock
        );
    } else {
        dispatch_async(dispatch_get_main_queue(), applyBlock);
    }
}

- (void)cancelPendingSettings {
    _settingsCommitGeneration++;
    _hasPendingSettings = NO;
    _pendingProfile = nil;
}

- (void)persistPendingSettingsAndCancel {
    if (!_hasPendingSettings) {
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:_pendingScale forKey:@"cursorScale"];
    [defaults setObject:_pendingProfile forKey:@"animationProfile"];
    [self cancelPendingSettings];
}

- (BOOL)applyPendingSettingsNow {
    if (!_hasPendingSettings) {
        return YES;
    }

    CGFloat scale = _pendingScale;
    NSString *profile = [_pendingProfile copy];
    _settingsCommitGeneration++;
    _settingsTransientStatus = nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!_registrar.enabled) {
        [defaults setDouble:scale forKey:@"cursorScale"];
        [defaults setObject:profile forKey:@"animationProfile"];
        _hasPendingSettings = NO;
        _pendingProfile = nil;
        _applicationState = CPApplicationStatePaused;
        _lastBackgroundError = nil;
        [self showTransientSettingsStatus:
            @"设置已保存 · 重新启用时使用"
                                     duration:2.5
                                 announcement:
            @"设置已保存，重新启用猫标时使用"];
        return YES;
    }

    _applicationState = CPApplicationStateApplying;
    [self refreshMenu];
    [_settingsWindow displayIfNeeded];
    NSError *error = nil;
    BOOL success = [_registrar
        reapplyWithScale:scale
   targetFramesPerSecond:CPFramesPerSecondForProfile(profile)
                   error:&error];
    if (success) {
        [defaults setDouble:scale forKey:@"cursorScale"];
        [defaults setObject:profile forKey:@"animationProfile"];
        _hasPendingSettings = NO;
        _pendingProfile = nil;
        _applicationState = CPApplicationStateActive;
        _lastBackgroundError = nil;
        [_registrar refreshVisibleCursorAfterSettingChange];
        [self prewarmSizeChoicesForProfile:profile];
        NSString *message = [NSString stringWithFormat:
            @"已应用 · %.0f%% · %@",
            scale * 100.0,
            CPSpeedDisplayName(profile)];
        NSString *announcement = _settingsWindow.isVisible
            ? [NSString stringWithFormat:
                @"猫标设置已应用，尺寸百分之 %.0f，速度%@",
                scale * 100.0,
                CPSpeedDisplayName(profile)]
            : nil;
        [self showTransientSettingsStatus:message
                                 duration:1.8
                             announcement:announcement];
    } else {
        _hasPendingSettings = NO;
        _pendingProfile = nil;
        NSError *presentedError =
            [self recoverSavedPointerConfigurationAfterError:error];
        BOOL recovered =
            CPConfigurationRollbackSucceeded(presentedError);
        _applicationState = recovered
            ? CPApplicationStateActive
            : CPApplicationStateError;
        _lastBackgroundError = recovered ? nil : presentedError;
        [self showError:presentedError];
    }
    [self refreshMenu];
    return success;
}

- (NSError *)recoverSavedPointerConfigurationAfterError:
    (nullable NSError *)primaryError {
    NSError *recoveryError = nil;
    BOOL recovered = [_registrar
        reapplyWithScale:[self savedScale]
   targetFramesPerSecond:[self effectiveFramesPerSecond]
                   error:&recoveryError];
    if (recovered) {
        _desiredEnabled = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES
                                              forKey:@"desiredEnabled"];
        [self prewarmSizeChoicesForProfile:
            [self savedAnimationProfile]];
        NSString *primaryDescription =
            primaryError.localizedDescription ?: @"新设置应用失败";
        return [NSError errorWithDomain:CPSystemCursorErrorDomain
                                   code:201
                               userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"%@。已恢复上一个设置，猫标继续正常使用。",
                primaryDescription],
        }];
    }

    _desiredEnabled = _registrar.enabled;
    [NSUserDefaults.standardUserDefaults setBool:_desiredEnabled
                                          forKey:@"desiredEnabled"];
    NSString *primaryDescription =
        primaryError.localizedDescription ?: @"新设置应用失败";
    NSString *recoveryDescription =
        recoveryError.localizedDescription ?: @"未知恢复错误";
    NSString *actualState = _registrar.enabled
        ? @"猫标注册仍在，建议暂停后重试"
        : @"系统光标已恢复";
    return [NSError errorWithDomain:CPSystemCursorErrorDomain
                               code:202
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"%@；恢复上一个设置也失败：%@。当前状态：%@。",
            primaryDescription,
            recoveryDescription,
            actualState],
    }];
}

- (void)reapplyPointer:(id)sender {
    (void)sender;
    if (_hasPendingSettings) {
        [self applyPendingSettingsNow];
    }
    if (!_registrar.enabled) {
        return;
    }
    _applicationState = CPApplicationStateApplying;
    [self refreshMenu];
    NSError *error = nil;
    BOOL success = [_registrar
        reapplyWithScale:[self savedScale]
   targetFramesPerSecond:[self effectiveFramesPerSecond]
                   error:&error];
    if (!success) {
        _applicationState = CPApplicationStateError;
        _lastBackgroundError = error;
        [self showError:error];
    } else {
        _applicationState = CPApplicationStateActive;
        _lastBackgroundError = nil;
        [_registrar refreshVisibleCursorAfterSettingChange];
        [self prewarmSizeChoicesForProfile:
            [self savedAnimationProfile]];
    }
    [self refreshMenu];
}

- (void)verifyPointer:(id)sender {
    (void)sender;
    if (_applicationState == CPApplicationStateVerifying) {
        return;
    }
    if (!_registrar.enabled) {
        [self refreshMenu];
        return;
    }
    if (_hasPendingSettings) {
        if (![self applyPendingSettingsNow]) {
            return;
        }
        if (!_registrar.enabled) {
            [self refreshMenu];
            return;
        }
    }
    BOOL wasEnabled = _registrar.enabled;
    CGFloat scale = [self savedScale];
    BOOL showSuccessAlert =
        _settingsWindow == nil || !_settingsWindow.visible;
    _settingsTransientStatus = nil;
    _settingsTransientStatusGeneration++;
    _applicationState = CPApplicationStateVerifying;
    [self refreshMenu];
    [_settingsWindow displayIfNeeded];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self performPointerVerificationWasEnabled:wasEnabled
                                             scale:scale
                                  showSuccessAlert:showSuccessAlert];
    });
}

- (void)performPointerVerificationWasEnabled:(BOOL)wasEnabled
                                       scale:(CGFloat)scale
                            showSuccessAlert:(BOOL)showSuccessAlert {
    NSError *error = nil;
    NSDictionary *result = nil;
    @autoreleasepool {
        result = [[_registrar
            performSelfTestWithScale:scale
                               error:&error] copy];
    }
    NSError *resumeError = nil;
    BOOL resumed = YES;
    if (wasEnabled) {
        resumed = [_registrar
            startWithScale:scale
     targetFramesPerSecond:[self effectiveFramesPerSecond]
                     error:&resumeError];
        if (resumed) {
            [self prewarmSizeChoicesForProfile:
                [self savedAnimationProfile]];
            // The self-test intentionally clears its render cache. Refill all
            // five size stops before showing the result so the very next
            // slider release remains an immediate cached switch.
            [_registrar waitForPrewarming];
        }
    }
    (void)malloc_zone_pressure_relief(NULL, 0);

    BOOL passed = [result[@"passed"] boolValue] && resumed;
    _applicationState = passed
        ? (wasEnabled
            ? CPApplicationStateActive
            : CPApplicationStatePaused)
        : CPApplicationStateError;
    _lastBackgroundError = passed ? nil : (resumeError ?: error);
    if (passed && !showSuccessAlert) {
        [self showTransientSettingsStatus:@"检查通过 · 一切正常"
                                 duration:3
                             announcement:@"猫标检查通过，一切正常"];
        return;
    }

    NSAlert *alert = [NSAlert new];
    alert.alertStyle = passed ? NSAlertStyleInformational
                              : NSAlertStyleCritical;
    alert.messageText = passed
        ? @"检查通过"
        : @"检查未通过";
    alert.informativeText = passed
        ? @"五档尺寸、慢速到极致四档速度、跨应用显示、重复调整"
          @"和安全恢复均已通过。猫标不会读取或拦截任何鼠标操作。"
        : ((resumeError ?: error).localizedDescription ?: @"未知错误");
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
    [self refreshMenu];
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"猫标 CatPointer";
    alert.informativeText =
        @"HappyCadogt 原作“猫标”的原生 macOS 移植："
        @"支持普通、文字、链接、后台运行、忙碌和横纵拉伸动画。"
        @"图像全部来自原作帧，没有重新手绘。\n\n"
        @"动画由 macOS 播放，最高使用系统支持的 24 帧，"
        @"不会监听点击、拖拽或键盘。尺寸可以滑动调节，"
        @"速度可选择慢速、适中、快速或极致，松手后立即应用。\n\n"
        @"切换 App 后仍然生效，也不需要辅助功能或输入监控权限。"
        @"菜单栏爪印可暂停、改尺寸或退出并恢复原光标。\n\n"
        @"仅供本机个人使用；由于依赖 macOS 的内部光标能力，"
        @"macOS 大版本更新后可能需要重新适配。";
    [alert addButtonWithTitle:@"知道了"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showError:(nullable NSError *)error {
    NSAlert *alert = [NSAlert new];
    BOOL recovered = error != nil &&
        CPConfigurationRollbackSucceeded(error);
    alert.alertStyle = recovered
        ? NSAlertStyleWarning
        : NSAlertStyleCritical;
    alert.messageText = recovered
        ? @"新设置未应用"
        : @"猫标未能应用";
    alert.informativeText =
        error.localizedDescription ?: @"未知错误";
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)quitAndRestore:(id)sender {
    (void)sender;
    if (_hasPendingSettings) {
        [self applyPendingSettingsNow];
    }
    _applicationState = CPApplicationStateApplying;
    [self refreshMenu];
    NSError *error = nil;
    if (![_registrar stopWithError:&error]) {
        _applicationState = CPApplicationStateError;
        _lastBackgroundError = error;
        [self refreshMenu];
        [self showError:error];
        return;
    }
    _terminationApproved = YES;
    [NSApp terminate:nil];
}

- (void)runSelfTestAndExit {
    NSError *error = nil;
    NSDictionary *result =
        [_registrar performSelfTestWithScale:1.0 error:&error];
    NSMutableDictionary *output = result.mutableCopy;
    if (error != nil) {
        output[@"error"] = error.localizedDescription;
    }
    [self writeJSONAndExit:output
                    passed:[result[@"passed"] boolValue]];
}

- (void)renderPreviewAndExit {
    NSError *error = nil;
    BOOL passed = [_registrar
        writePreviewToURL:[NSURL fileURLWithPath:_previewPath]
                    error:&error
    ];
    NSMutableDictionary *result = [@{
        @"previewWritten": @(passed),
        @"path": _previewPath,
        @"passed": @(passed),
    } mutableCopy];
    if (error != nil) {
        result[@"error"] = error.localizedDescription;
    }
    [self writeJSONAndExit:result passed:passed];
}

- (void)writeJSONAndExit:(NSDictionary *)result passed:(BOOL)passed {
    NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                   options:
        NSJSONWritingSortedKeys
                                                     error:nil];
    NSFileHandle *standardOutput =
        NSFileHandle.fileHandleWithStandardOutput;
    [standardOutput writeData:json];
    [standardOutput writeData:
        [@"\n" dataUsingEncoding:NSUTF8StringEncoding]
    ];

    if (!passed) {
        [_registrar stop];
    }
    _exit(passed ? EXIT_SUCCESS : 2);
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    if (_systemReapplyTimer != nil) {
        dispatch_source_cancel(_systemReapplyTimer);
    }
    if (_instanceLockFD >= 0) {
        close(_instanceLockFD);
    }
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        CPAppDelegate *delegate = [CPAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
