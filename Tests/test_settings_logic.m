#import <AppKit/AppKit.h>

#define main CatPointerApplicationMain
#import "../Sources/CatPointer/main.m"
#undef main

@interface CPSettingsSliderProbe : NSObject

@property(nonatomic) NSInteger actionCount;
@property(nonatomic) NSInteger commitCount;
@property(nonatomic) double lastValue;
@property(nonatomic) BOOL sawTrackingDuringPreview;
@property(nonatomic) BOOL sawTrackingDuringCommit;

- (void)sliderChanged:(NSSlider *)sender;
- (void)sliderCommitted:(CPCommitSlider *)sender;

@end

@implementation CPSettingsSliderProbe

- (void)sliderChanged:(NSSlider *)sender {
    self.actionCount++;
    self.lastValue = sender.doubleValue;
    if ([sender isKindOfClass:CPCommitSlider.class]) {
        self.sawTrackingDuringPreview |=
            ((CPCommitSlider *)sender).isMouseTracking;
    }
    sender.accessibilityValueDescription = [NSString stringWithFormat:
        @"档位 %.0f",
        sender.doubleValue];
}

- (void)sliderCommitted:(CPCommitSlider *)sender {
    self.commitCount++;
    self.sawTrackingDuringCommit |= sender.isMouseTracking;
}

@end

@interface CPAppDelegate (CPMenuBarTesting)

- (BOOL)statusItemNeedsDockFallback;
- (void)updateMenuBarAccessFallback;

@end

@interface CPMenuBarFallbackDelegate : CPAppDelegate

@property(nonatomic) BOOL simulatedFallbackRequired;

@end

@implementation CPMenuBarFallbackDelegate

- (BOOL)statusItemNeedsDockFallback {
    return self.simulatedFallbackRequired;
}

@end

static void CPTestRequire(BOOL condition, NSString *message) {
    if (condition) {
        return;
    }
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static NSEvent *CPTestArrowKeyEvent(
    unichar character,
    unsigned short keyCode,
    BOOL isRepeat
) {
    NSString *characters =
        [NSString stringWithCharacters:&character length:1];
    return [NSEvent
        keyEventWithType:NSEventTypeKeyDown
                location:NSZeroPoint
           modifierFlags:0
               timestamp:0
            windowNumber:0
                 context:nil
              characters:characters
charactersIgnoringModifiers:characters
                isARepeat:isRepeat
                  keyCode:keyCode];
}

static void CPTestCanonicalSettings(void) {
    CPTestRequire(
        fabs(CPCanonicalScale(0) - 1.0) < 0.001,
        @"缺失尺寸应恢复为标准档"
    );
    CPTestRequire(
        fabs(CPCanonicalScale(0.84) - 0.8) < 0.001,
        @"旧尺寸应迁移到最近的小档"
    );
    CPTestRequire(
        fabs(CPCanonicalScale(0.86) - 0.9) < 0.001,
        @"旧尺寸应迁移到最近的偏小档"
    );
    CPTestRequire(
        fabs(CPCanonicalScale(1.24) - 1.2) < 0.001,
        @"过大尺寸应迁移到公开最大档"
    );

    NSDictionary<NSString *, NSString *> *legacyProfiles = @{
        @"original": CPAnimationProfileSlow,
        @"efficient": CPAnimationProfileMedium,
        @"balanced": CPAnimationProfileFast,
        @"high": CPAnimationProfileExtreme,
    };
    [legacyProfiles enumerateKeysAndObjectsUsingBlock:
        ^(NSString *legacy, NSString *expected, BOOL *stop) {
            (void)stop;
            CPTestRequire(
                [CPCanonicalAnimationProfile(legacy)
                    isEqualToString:expected],
                [NSString stringWithFormat:
                    @"旧速度 %@ 迁移错误",
                    legacy]
            );
        }];
    CPTestRequire(
        [CPCanonicalAnimationProfile(@"unknown")
            isEqualToString:CPAnimationProfileExtreme],
        @"未知速度应安全回到默认极致档"
    );
    CPTestRequire(
        CPFramesPerSecondForProfile(CPAnimationProfileMedium) == 12.0 &&
        CPFramesPerSecondForProfile(CPAnimationProfileFast) == 20.0 &&
        CPFramesPerSecondForProfile(CPAnimationProfileExtreme) == 30.0,
        @"三档固定播放速度错误"
    );

    NSArray<NSNumber *> *ordered = CPSizeStepsStartingAtScale(0.9);
    CPTestRequire(
        ordered.count == 5 &&
        fabs(ordered[0].doubleValue - 0.9) < 0.001 &&
        fabs(ordered[1].doubleValue - 1.0) < 0.001,
        @"预热顺序应从当前档开始并优先标准档"
    );
}

static void CPTestNotchedMenuBarFallback(void) {
    NSRect screen = NSMakeRect(0, 0, 1512, 982);
    NSEdgeInsets notchInsets = NSEdgeInsetsMake(32, 0, 0, 0);
    NSRect rightSafeArea = NSMakeRect(920, 950, 592, 32);

    CPTestRequire(
        !CPMenuBarNeedsFallback(
            screen,
            NSEdgeInsetsMake(0, 0, 0, 0),
            NSZeroRect,
            NSZeroRect,
            NO
        ),
        @"无刘海屏不应显示 Dock 备用入口"
    );
    CPTestRequire(
        !CPMenuBarNeedsFallback(
            screen,
            notchInsets,
            rightSafeArea,
            NSMakeRect(1450, 950, 24, 32),
            YES
        ),
        @"位于刘海右侧安全区的菜单栏图标不应触发备用入口"
    );
    CPTestRequire(
        CPMenuBarNeedsFallback(
            screen,
            notchInsets,
            rightSafeArea,
            NSMakeRect(895, 950, 24, 32),
            YES
        ),
        @"被刘海覆盖的菜单栏图标必须触发 Dock 备用入口"
    );
    CPTestRequire(
        CPMenuBarNeedsFallback(
            screen,
            notchInsets,
            rightSafeArea,
            NSZeroRect,
            NO
        ),
        @"刘海屏上不可见的菜单栏窗口必须触发备用入口"
    );

    CPMenuBarFallbackDelegate *delegate =
        [CPMenuBarFallbackDelegate new];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    delegate.simulatedFallbackRequired = YES;
    [delegate updateMenuBarAccessFallback];
    CPTestRequire(
        NSApp.activationPolicy == NSApplicationActivationPolicyRegular &&
        NSApp.mainMenu.numberOfItems == 1,
        @"菜单栏入口被遮挡时应实际显示 Dock 与应用菜单入口"
    );
    delegate.simulatedFallbackRequired = NO;
    [delegate updateMenuBarAccessFallback];
    CPTestRequire(
        NSApp.activationPolicy == NSApplicationActivationPolicyAccessory,
        @"菜单栏入口恢复后应退出 Dock 备用模式"
    );
}

static void CPTestSliderKeyboardAndAccessibility(void) {
    CPSettingsSliderProbe *probe = [CPSettingsSliderProbe new];
    CPCommitSlider *slider =
        [[CPCommitSlider alloc] initWithFrame:NSMakeRect(0, 0, 300, 30)];
    slider.minValue = 0;
    slider.maxValue = 4;
    slider.doubleValue = 2;
    slider.target = probe;
    slider.action = @selector(sliderChanged:);
    slider.numberOfTickMarks = 5;
    slider.allowsTickMarkValuesOnly = YES;

    unichar right = NSRightArrowFunctionKey;
    [slider keyDown:CPTestArrowKeyEvent(right, 124, NO)];
    CPTestRequire(
        slider.doubleValue == 3 &&
        probe.actionCount == 1 &&
        probe.lastValue == 3,
        @"右方向键应只前进一档并发送一次 action"
    );

    unichar down = NSDownArrowFunctionKey;
    [slider keyDown:CPTestArrowKeyEvent(down, 125, YES)];
    CPTestRequire(
        slider.doubleValue == 2 &&
        probe.actionCount == 2 &&
        probe.lastValue == 2,
        @"下方向键连发事件也应只后退一档"
    );

    CPTestRequire(
        [slider accessibilityPerformIncrement] &&
        slider.doubleValue == 3 &&
        probe.actionCount == 3,
        @"VoiceOver 增加动作应前进一档"
    );
    CPTestRequire(
        [slider.accessibilityValueDescription isEqualToString:@"档位 3"],
        @"值描述应在辅助功能通知前更新"
    );
    CPTestRequire(
        [slider accessibilityPerformDecrement] &&
        slider.doubleValue == 2 &&
        probe.actionCount == 4,
        @"VoiceOver 减少动作应后退一档"
    );

    slider.doubleValue = slider.maxValue;
    NSInteger actionCountAtBoundary = probe.actionCount;
    CPTestRequire(
        ![slider accessibilityPerformIncrement] &&
        slider.doubleValue == slider.maxValue &&
        probe.actionCount == actionCountAtBoundary,
        @"最大档继续增加应返回失败且不重复 action"
    );

    slider.doubleValue = slider.minValue;
    actionCountAtBoundary = probe.actionCount;
    CPTestRequire(
        ![slider accessibilityPerformDecrement] &&
        slider.doubleValue == slider.minValue &&
        probe.actionCount == actionCountAtBoundary,
        @"最小档继续减少应返回失败且不重复 action"
    );
}

static NSEvent *CPTestMouseEvent(
    NSEventType type,
    NSPoint location,
    NSInteger windowNumber,
    NSInteger eventNumber
) {
    return [NSEvent
        mouseEventWithType:type
                  location:location
             modifierFlags:0
                 timestamp:(NSTimeInterval)eventNumber / 1000.0
              windowNumber:windowNumber
                   context:nil
               eventNumber:eventNumber
                clickCount:1
                  pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
}

static void CPTestSliderMouseCommit(void) {
    CPSettingsSliderProbe *probe = [CPSettingsSliderProbe new];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 360, 80)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    CPCommitSlider *slider =
        [[CPCommitSlider alloc] initWithFrame:NSMakeRect(30, 24, 300, 28)];
    slider.minValue = 0;
    slider.maxValue = 4;
    slider.doubleValue = 0;
    slider.numberOfTickMarks = 5;
    slider.allowsTickMarkValuesOnly = YES;
    slider.continuous = YES;
    slider.target = probe;
    slider.action = @selector(sliderChanged:);
    slider.commitTarget = probe;
    slider.commitAction = @selector(sliderCommitted:);
    [window.contentView addSubview:slider];
    [window orderFront:nil];
    [window displayIfNeeded];

    NSPoint end =
        [slider convertPoint:NSMakePoint(290, 14) toView:nil];
    NSInteger windowNumber = window.windowNumber;
    NSEvent *down = CPTestMouseEvent(
        NSEventTypeLeftMouseDown,
        end,
        windowNumber,
        1
    );
    [NSApp postEvent:CPTestMouseEvent(
        NSEventTypeLeftMouseUp,
        end,
        windowNumber,
        2
    ) atStart:NO];
    [slider mouseDown:down];

    CPTestRequire(
        probe.actionCount >= 1 &&
        probe.sawTrackingDuringPreview,
        @"鼠标拖动应连续预览，并在 action 期间标记为 tracking"
    );
    CPTestRequire(
        probe.commitCount == 1 &&
        !probe.sawTrackingDuringCommit,
        @"一次鼠标拖动松手后应只提交一次"
    );
    CPTestRequire(
        slider.doubleValue == slider.maxValue,
        @"点击轨道末端应落在最终档位"
    );
    [window orderOut:nil];
}

static BOOL CPTestViewTreeHasAmbiguousLayout(NSView *view) {
    if (view.hasAmbiguousLayout) {
        return YES;
    }
    for (NSView *subview in view.subviews) {
        if (CPTestViewTreeHasAmbiguousLayout(subview)) {
            return YES;
        }
    }
    return NO;
}

static void CPTestSettingsWindowStructure(void) {
    CPAppDelegate *delegate = [CPAppDelegate new];
    [delegate buildSettingsWindow];

    NSWindow *window = [delegate valueForKey:@"settingsWindow"];
    CPCommitSlider *sizeSlider =
        [delegate valueForKey:@"settingsSizeSlider"];
    CPCommitSlider *speedSlider =
        [delegate valueForKey:@"settingsSpeedSlider"];
    NSSwitch *enableSwitch =
        [delegate valueForKey:@"settingsEnableSwitch"];
    NSTextField *explanationLabel =
        [delegate valueForKey:@"settingsExplanationLabel"];
    NSButton *verifyButton =
        [delegate valueForKey:@"settingsVerifyButton"];
    NSButton *resetButton =
        [delegate valueForKey:@"settingsResetButton"];
    [window.contentView layoutSubtreeIfNeeded];

    CPTestRequire(
        window != nil &&
        [window isKindOfClass:CPSettingsWindow.class] &&
        window.contentView.frame.size.width == 500 &&
        window.contentView.frame.size.height == 400,
        @"设置窗口应使用固定、可读的原生布局"
    );
    CPTestRequire(
        [window.frameAutosaveName
            isEqualToString:CPSettingsWindowFrameAutosaveName],
        @"设置窗口应记住上次位置"
    );
    CPTestRequire(
        !CPTestViewTreeHasAmbiguousLayout(window.contentView),
        @"设置窗口不应存在模糊 Auto Layout 约束"
    );
    CPTestRequire(
        sizeSlider.isContinuous &&
        sizeSlider.numberOfTickMarks == 5 &&
        sizeSlider.allowsTickMarkValuesOnly &&
        sizeSlider.commitAction ==
            @selector(settingsSizeCommitted:),
        @"尺寸滑杆应连续预览、五档吸附并独立松手提交"
    );
    CPTestRequire(
        speedSlider.isContinuous &&
        speedSlider.numberOfTickMarks == 4 &&
        speedSlider.allowsTickMarkValuesOnly &&
        speedSlider.commitAction ==
            @selector(settingsSpeedCommitted:),
        @"速度滑杆应连续预览、四档吸附并独立松手提交"
    );
    CPTestRequire(
        [explanationLabel.stringValue
            containsString:@"拖动选择档位，松开后应用"] &&
        [sizeSlider.toolTip
            containsString:@"松开后应用到鼠标指针"] &&
        [speedSlider.toolTip
            containsString:@"松开后应用到小猫动画"],
        @"设置页必须明确说明拖动只选择档位、松开后才应用"
    );
    CPTestRequire(
        [enableSwitch.accessibilityLabel isEqualToString:@"启用猫标"] &&
        [verifyButton.title isEqualToString:@"检查是否正常…"] &&
        [resetButton.title isEqualToString:@"恢复默认"],
        @"普通用户操作名称或开关辅助标签错误"
    );
    CPTestRequire(
        window.initialFirstResponder == sizeSlider &&
        sizeSlider.nextKeyView == speedSlider &&
        speedSlider.nextKeyView == verifyButton &&
        verifyButton.nextKeyView == resetButton &&
        resetButton.nextKeyView == enableSwitch &&
        enableSwitch.nextKeyView == sizeSlider,
        @"设置窗口键盘焦点顺序错误"
    );
    [window close];
}

static BOOL CPWriteSettingsSnapshot(
    NSString *path,
    NSString *appearanceName
) {
    NSAppearance *previousAppearance = NSApp.appearance;
    NSAppearance *appearance =
        [NSAppearance appearanceNamed:appearanceName];
    NSApp.appearance = appearance;
    CPAppDelegate *delegate = [CPAppDelegate new];
    [delegate buildSettingsWindow];
    NSWindow *window = [delegate valueForKey:@"settingsWindow"];
    window.appearance = appearance;
    NSView *content = window.contentView;
    [appearance performAsCurrentDrawingAppearance:^{
        content.layer.backgroundColor =
            NSColor.windowBackgroundColor.CGColor;
    }];
    [content layoutSubtreeIfNeeded];
    NSBitmapImageRep *representation =
        [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    if (representation == nil) {
        [window close];
        NSApp.appearance = previousAppearance;
        return NO;
    }
    [content cacheDisplayInRect:content.bounds
              toBitmapImageRep:representation];
    NSData *data = [representation
        representationUsingType:NSBitmapImageFileTypePNG
                      properties:@{}];
    BOOL wrote = [data writeToFile:path atomically:YES];
    [window close];
    NSApp.appearance = previousAppearance;
    return wrote;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)NSApplication.sharedApplication;
        CPTestCanonicalSettings();
        CPTestNotchedMenuBarFallback();
        CPTestSliderKeyboardAndAccessibility();
        CPTestSliderMouseCommit();
        CPTestSettingsWindowStructure();
        if (argc == 4 &&
            strcmp(argv[1], "--render-settings") == 0) {
            NSString *path =
                [NSString stringWithUTF8String:argv[2]];
            NSString *appearance =
                strcmp(argv[3], "dark") == 0
                    ? NSAppearanceNameDarkAqua
                    : NSAppearanceNameAqua;
            CPTestRequire(
                CPWriteSettingsSnapshot(path, appearance),
                @"无法输出设置窗口快照"
            );
        }
        puts(
            "PASS: settings layout, notched menu bar fallback, migration, "
            "mouse commit, keyboard stepping, and accessibility actions "
            "validated"
        );
    }
    return 0;
}
