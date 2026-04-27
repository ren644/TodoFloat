/**
 * TodoFloat v2 — macOS floating todo widget with bidirectional sync
 *
 * Data sources:
 *   1. Apple Reminders (EKReminder via EventKit)
 *   2. Lark Base (feishu) via lark-cli
 *
 * Features:
 *   - Checkbox to mark complete (syncs back to source)
 *   - Double-click to edit text (syncs back to source)
 *   - 5-minute auto-refresh
 *   - Frosted glass floating panel
 *
 * Build: clang -fobjc-arc -framework Cocoa -framework EventKit -o TodoFloat src/main.m
 */

#import <Cocoa/Cocoa.h>
#import <EventKit/EventKit.h>

static NSString *const kLarkCLI = @"/Users/mima0000/.npm-global/bin/lark-cli";
static NSString *const kBaseToken = @"Vm4nbpWDlaxWgWsSQYYcElV7nYf";
static NSString *const kTableId = @"tblJvkKfjHDBIBVA";

// ============================================================================
#pragma mark - Data Models
// ============================================================================

typedef NS_ENUM(NSInteger, TodoSource) {
    TodoSourceAppleReminder = 0,
    TodoSourceLark = 1,
};

@interface TodoItem : NSObject
@property (nonatomic, assign) TodoSource source;
@property (nonatomic, copy) NSString *itemId;       // EKReminder calendarItemIdentifier or lark record_id
@property (nonatomic, copy) NSString *content;
@property (nonatomic, copy) NSString *status;        // "待做" / "进行中" / "已完成"
@property (nonatomic, copy) NSString *deadline;
@property (nonatomic, assign) BOOL completed;
@property (nonatomic, strong) EKReminder *ekReminder; // keep reference for Apple Reminders
@end

@implementation TodoItem
@end

// ============================================================================
#pragma mark - TodoRowView (single row with checkbox + editable text + date)
// ============================================================================

@class TodoRowView;

@protocol TodoRowDelegate <NSObject>
- (void)todoRowDidToggleComplete:(TodoRowView *)row;
- (void)todoRow:(TodoRowView *)row didEditContent:(NSString *)newContent;
@end

@interface TodoRowView : NSView <NSTextFieldDelegate>
@property (nonatomic, strong) TodoItem *todoItem;
@property (nonatomic, weak) id<TodoRowDelegate> delegate;
@property (nonatomic, strong) NSButton *checkbox;
@property (nonatomic, strong) NSTextField *titleField;
@property (nonatomic, strong) NSTextField *dateLabel;
@property (nonatomic, strong) NSView *statusDot;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL isEditing;
- (instancetype)initWithTodoItem:(TodoItem *)item delegate:(id<TodoRowDelegate>)delegate;
@end

@implementation TodoRowView

- (instancetype)initWithTodoItem:(TodoItem *)item delegate:(id<TodoRowDelegate>)del {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.todoItem = item;
        self.delegate = del;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.isEditing = NO;

        // --- Checkbox ---
        self.checkbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(checkboxClicked:)];
        self.checkbox.translatesAutoresizingMaskIntoConstraints = NO;
        self.checkbox.state = item.completed ? NSControlStateValueOn : NSControlStateValueOff;
        [self addSubview:self.checkbox];

        // --- Status dot ---
        self.statusDot = [[NSView alloc] init];
        self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
        self.statusDot.wantsLayer = YES;
        self.statusDot.layer.cornerRadius = 3.5;
        [self updateDotColor];
        [self addSubview:self.statusDot];

        // --- Title field (label by default, editable on double-click) ---
        self.titleField = [[NSTextField alloc] init];
        self.titleField.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleField.stringValue = item.content ?: @"";
        self.titleField.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
        self.titleField.lineBreakMode = NSLineBreakByTruncatingTail;
        self.titleField.maximumNumberOfLines = 2;
        self.titleField.bordered = NO;
        self.titleField.drawsBackground = NO;
        self.titleField.editable = NO;
        self.titleField.selectable = NO;
        self.titleField.delegate = self;
        self.titleField.focusRingType = NSFocusRingTypeNone;
        [self.titleField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:self.titleField];

        // --- Date label ---
        NSString *dateStr = item.deadline ?: @"";
        self.dateLabel = [NSTextField labelWithString:dateStr];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [NSFont systemFontOfSize:9.0 weight:NSFontWeightRegular];
        self.dateLabel.textColor = [NSColor secondaryLabelColor];
        self.dateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.dateLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:self.dateLabel];

        [self applyCompletedStyle];

        // Layout
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:28],

            // Checkbox
            [self.checkbox.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [self.checkbox.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.checkbox.widthAnchor constraintEqualToConstant:18],

            // Status dot
            [self.statusDot.leadingAnchor constraintEqualToAnchor:self.checkbox.trailingAnchor constant:4],
            [self.statusDot.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.statusDot.widthAnchor constraintEqualToConstant:7],
            [self.statusDot.heightAnchor constraintEqualToConstant:7],

            // Title
            [self.titleField.leadingAnchor constraintEqualToAnchor:self.statusDot.trailingAnchor constant:6],
            [self.titleField.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.titleField.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:4],
            [self.titleField.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4],

            // Date
            [self.dateLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleField.trailingAnchor constant:4],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [self.dateLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

- (void)updateDotColor {
    NSColor *color;
    NSString *s = self.todoItem.status ?: @"";
    if (self.todoItem.completed || [s containsString:@"已完成"]) {
        color = [NSColor systemGreenColor];
    } else if ([s containsString:@"进行中"]) {
        color = [NSColor systemBlueColor];
    } else {
        color = [NSColor systemOrangeColor];
    }
    self.statusDot.layer.backgroundColor = color.CGColor;
}

- (void)applyCompletedStyle {
    if (self.todoItem.completed) {
        // Strikethrough + gray
        NSDictionary *attrs = @{
            NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle),
            NSForegroundColorAttributeName: [NSColor tertiaryLabelColor],
            NSFontAttributeName: [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium],
        };
        self.titleField.attributedStringValue = [[NSAttributedString alloc]
            initWithString:self.todoItem.content ?: @""
                attributes:attrs];
        self.titleField.textColor = [NSColor tertiaryLabelColor];
    } else {
        self.titleField.textColor = [NSColor labelColor];
        self.titleField.stringValue = self.todoItem.content ?: @"";
    }
}

// --- Double-click to edit ---
- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2 && !self.todoItem.completed) {
        [self startEditing];
    } else {
        [super mouseDown:event];
    }
}

- (void)startEditing {
    if (self.isEditing) return;
    self.isEditing = YES;
    self.titleField.editable = YES;
    self.titleField.selectable = YES;
    self.titleField.bordered = YES;
    self.titleField.drawsBackground = YES;
    self.titleField.backgroundColor = [NSColor controlBackgroundColor];
    [self.titleField becomeFirstResponder];
    // Select all text
    NSText *editor = [self.window fieldEditor:YES forObject:self.titleField];
    [editor selectAll:nil];
}

- (void)endEditing {
    if (!self.isEditing) return;
    self.isEditing = NO;
    self.titleField.editable = NO;
    self.titleField.selectable = NO;
    self.titleField.bordered = NO;
    self.titleField.drawsBackground = NO;

    NSString *newContent = self.titleField.stringValue;
    if (newContent.length > 0 && ![newContent isEqualToString:self.todoItem.content]) {
        self.todoItem.content = newContent;
        [self.delegate todoRow:self didEditContent:newContent];
    }
}

// NSTextField delegate — called on Return
- (void)controlTextDidEndEditing:(NSNotification *)obj {
    [self endEditing];
}

// --- Checkbox ---
- (void)checkboxClicked:(NSButton *)sender {
    BOOL nowComplete = (sender.state == NSControlStateValueOn);
    self.todoItem.completed = nowComplete;
    if (nowComplete) {
        self.todoItem.status = @"已完成";
    }
    [self updateDotColor];
    [self applyCompletedStyle];
    [self.delegate todoRowDidToggleComplete:self];
}

// Hover highlight
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow)
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor labelColor] colorWithAlphaComponent:0.05].CGColor;
    self.layer.cornerRadius = 4;
}

- (void)mouseExited:(NSEvent *)event {
    self.layer.backgroundColor = [NSColor clearColor].CGColor;
}

@end

// ============================================================================
#pragma mark - FlippedView (for top-to-bottom layout in scroll view)
// ============================================================================

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// ============================================================================
#pragma mark - SectionHeaderView
// ============================================================================

@interface SectionHeaderView : NSView
- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title count:(NSInteger)count;
@end

@implementation SectionHeaderView

- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title count:(NSInteger)count {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        NSString *text = [NSString stringWithFormat:@"%@ %@ (%ld)", icon, title, (long)count];
        NSTextField *label = [NSTextField labelWithString:text];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
        label.textColor = [NSColor secondaryLabelColor];
        [self addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],
        ]];
    }
    return self;
}

@end

// ============================================================================
#pragma mark - SeparatorView
// ============================================================================

@interface SeparatorView : NSView
@end

@implementation SeparatorView

- (instancetype)init {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor.separatorColor colorWithAlphaComponent:0.3].CGColor;
        [self.heightAnchor constraintEqualToConstant:1].active = YES;
    }
    return self;
}

- (void)updateLayer {
    self.layer.backgroundColor = [NSColor.separatorColor colorWithAlphaComponent:0.3].CGColor;
}

@end

// ============================================================================
#pragma mark - AppDelegate
// ============================================================================

@interface AppDelegate : NSObject <NSApplicationDelegate, TodoRowDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSView *contentStack;
@property (nonatomic, strong) NSTextField *refreshLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSTimer *autoRefreshTimer;
@property (nonatomic, strong) EKEventStore *eventStore;
@property (nonatomic, strong) NSArray<TodoItem *> *appleItems;
@property (nonatomic, strong) NSArray<TodoItem *> *larkItems;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.eventStore = [[EKEventStore alloc] init];
    [self createPanel];

    // Request Reminders access then refresh
    [self.eventStore requestFullAccessToRemindersWithCompletion:^(BOOL granted, NSError *error) {
        if (granted) {
            NSLog(@"Reminders access granted");
        } else {
            NSLog(@"Reminders access denied: %@", error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refresh];
        });
    }];

    [self startAutoRefresh];
}

// ============================================================================
#pragma mark - Panel Creation
// ============================================================================

- (void)createPanel {
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat panelWidth = 340;
    CGFloat panelHeight = 560;
    CGFloat x = NSMaxX(screen.visibleFrame) - panelWidth - 20;
    CGFloat y = NSMaxY(screen.visibleFrame) - panelHeight - 20;
    NSRect frame = NSMakeRect(x, y, panelWidth, panelHeight);

    self.panel = [[NSPanel alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled |
                             NSWindowStyleMaskClosable |
                             NSWindowStyleMaskResizable |
                             NSWindowStyleMaskNonactivatingPanel)
                    backing:NSBackingStoreBuffered
                      defer:NO];

    self.panel.level = NSFloatingWindowLevel;
    self.panel.floatingPanel = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.title = @"待办";
    self.panel.movableByWindowBackground = YES;
    self.panel.hasShadow = YES;
    self.panel.minSize = NSMakeSize(280, 200);
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;
    [self.panel setFrameAutosaveName:@"TodoFloatV2Position"];

    // Use system content view directly — no FullSizeContentView, no custom title bar
    NSView *container = self.panel.contentView;

    // Spinner (top-right of content area)
    self.spinner = [[NSProgressIndicator alloc] init];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeMini;
    self.spinner.displayedWhenStopped = NO;
    [container addSubview:self.spinner];

    // Refresh button (top-right)
    NSButton *refreshBtn = [NSButton buttonWithTitle:@"⟳ 刷新" target:self action:@selector(refresh)];
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    refreshBtn.bordered = NO;
    refreshBtn.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    [refreshBtn setContentTintColor:[NSColor secondaryLabelColor]];
    [container addSubview:refreshBtn];

    // Scroll view
    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.drawsBackground = NO;
    self.scrollView.borderType = NSNoBorder;
    [container addSubview:self.scrollView];

    // Document view for scrolling (flipped so content starts at top)
    FlippedView *docView = [[FlippedView alloc] initWithFrame:NSZeroRect];
    docView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.documentView = docView;
    self.contentStack = docView;

    // Footer
    self.refreshLabel = [NSTextField labelWithString:@""];
    self.refreshLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.refreshLabel.font = [NSFont systemFontOfSize:9.0];
    self.refreshLabel.textColor = [[NSColor secondaryLabelColor] colorWithAlphaComponent:0.6];
    self.refreshLabel.alignment = NSTextAlignmentCenter;
    [container addSubview:self.refreshLabel];

    // Layout — clean, no custom title bar
    [NSLayoutConstraint activateConstraints:@[
        // Spinner top-right
        [self.spinner.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [self.spinner.trailingAnchor constraintEqualToAnchor:refreshBtn.leadingAnchor constant:-6],
        // Refresh button top-right
        [refreshBtn.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [refreshBtn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        // Scroll view — main content area
        [self.scrollView.topAnchor constraintEqualToAnchor:refreshBtn.bottomAnchor constant:4],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.refreshLabel.topAnchor constant:-4],
        // Content width = scroll view width
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor],
        // Footer
        [self.refreshLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [self.refreshLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.refreshLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];

    [self.panel orderFrontRegardless];
}

// ============================================================================
#pragma mark - Auto Refresh
// ============================================================================

- (void)startAutoRefresh {
    self.autoRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:300
                                                            target:self
                                                          selector:@selector(refresh)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)refresh {
    [self.spinner startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<TodoItem *> *apple = [self fetchAppleReminders];
        NSArray<TodoItem *> *lark = [self fetchLarkTodos];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.appleItems = apple;
            self.larkItems = lark;
            [self.spinner stopAnimation:nil];
            [self rebuildUI];
            [self updateRefreshTime];
        });
    });
}

- (void)updateRefreshTime {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    self.refreshLabel.stringValue = [NSString stringWithFormat:@"更新于 %@ · 双击编辑 · 5分钟自动刷新",
                                     [fmt stringFromDate:[NSDate date]]];
}

// ============================================================================
#pragma mark - Fetch Apple Reminders
// ============================================================================

- (NSArray<TodoItem *> *)fetchAppleReminders {
    EKAuthorizationStatus authStatus = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
    if (authStatus != EKAuthorizationStatusFullAccess) {
        NSLog(@"Reminders auth status: %ld (not full access, trying anyway)", (long)authStatus);
    }

    // Get all reminder calendars
    NSArray<EKCalendar *> *calendars = [self.eventStore calendarsForEntityType:EKEntityTypeReminder];
    if (!calendars.count) return @[];

    // Predicate: incomplete reminders (no date filter — just get all incomplete)
    NSPredicate *predicate = [self.eventStore predicateForIncompleteRemindersWithDueDateStarting:nil
                                                                                         ending:nil
                                                                                      calendars:calendars];

    __block NSArray<EKReminder *> *reminders = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self.eventStore fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *result) {
        reminders = result;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (!reminders) return @[];

    // Also fetch completed reminders from last 7 days (to show recently completed)
    NSDate *sevenDaysAgo = [[NSDate date] dateByAddingTimeInterval:-7*24*3600];
    NSPredicate *completedPred = [self.eventStore predicateForCompletedRemindersWithCompletionDateStarting:sevenDaysAgo
                                                                                                   ending:[NSDate date]
                                                                                                calendars:calendars];
    __block NSArray<EKReminder *> *completedReminders = nil;
    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
    [self.eventStore fetchRemindersMatchingPredicate:completedPred completion:^(NSArray<EKReminder *> *result) {
        completedReminders = result;
        dispatch_semaphore_signal(sem2);
    }];
    dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSMutableArray<TodoItem *> *items = [NSMutableArray new];
    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    dateFmt.dateFormat = @"MM-dd";

    // Incomplete reminders
    for (EKReminder *r in reminders) {
        TodoItem *item = [[TodoItem alloc] init];
        item.source = TodoSourceAppleReminder;
        item.itemId = r.calendarItemIdentifier;
        item.content = r.title ?: @"(无标题)";
        item.completed = NO;
        item.status = @"待做";
        item.ekReminder = r;
        if (r.dueDateComponents) {
            NSDate *dueDate = [[NSCalendar currentCalendar] dateFromComponents:r.dueDateComponents];
            if (dueDate) {
                item.deadline = [dateFmt stringFromDate:dueDate];
            }
        }
        [items addObject:item];
    }

    // Completed reminders (max 5 recent ones)
    NSArray *sortedCompleted = [completedReminders ?: @[] sortedArrayUsingComparator:^NSComparisonResult(EKReminder *a, EKReminder *b) {
        return [b.completionDate compare:a.completionDate ?: [NSDate distantPast]];
    }];

    NSInteger completedCount = 0;
    for (EKReminder *r in sortedCompleted) {
        if (completedCount >= 3) break;
        TodoItem *item = [[TodoItem alloc] init];
        item.source = TodoSourceAppleReminder;
        item.itemId = r.calendarItemIdentifier;
        item.content = r.title ?: @"(无标题)";
        item.completed = YES;
        item.status = @"已完成";
        item.ekReminder = r;
        if (r.completionDate) {
            item.deadline = [dateFmt stringFromDate:r.completionDate];
        }
        [items addObject:item];
        completedCount++;
    }

    // Sort: incomplete first, then by due date
    [items sortUsingComparator:^NSComparisonResult(TodoItem *a, TodoItem *b) {
        if (a.completed != b.completed) {
            return a.completed ? NSOrderedDescending : NSOrderedAscending;
        }
        return [a.content compare:b.content];
    }];

    return items;
}

// ============================================================================
#pragma mark - Fetch Lark Todos
// ============================================================================

- (NSArray<TodoItem *> *)fetchLarkTodos {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:kLarkCLI];
    task.arguments = @[@"base", @"+record-list",
                       @"--base-token", kBaseToken,
                       @"--table-id", kTableId,
                       @"--limit", @"50"];

    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *path = env[@"PATH"] ?: @"";
    env[@"PATH"] = [path stringByAppendingString:@":/usr/local/bin:/opt/homebrew/bin:/Users/mima0000/.npm-global/bin"];
    task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        NSLog(@"lark-cli launch error: %@", e);
        return @[];
    }

    NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
    if (!data.length) return @[];

    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![json[@"ok"] boolValue]) {
        NSLog(@"lark-cli parse error: %@", err);
        return @[];
    }

    NSDictionary *dataObj = json[@"data"];
    NSArray *fields = dataObj[@"fields"];
    NSArray *records = dataObj[@"data"];
    NSArray *recordIds = dataObj[@"record_id_list"];

    if (!fields || !records) return @[];

    // Build field name → index
    NSMutableDictionary<NSString *, NSNumber *> *fieldIdx = [NSMutableDictionary new];
    for (NSUInteger i = 0; i < fields.count; i++) {
        fieldIdx[fields[i]] = @(i);
    }

    NSMutableArray<TodoItem *> *items = [NSMutableArray new];
    for (NSUInteger rowIdx = 0; rowIdx < records.count; rowIdx++) {
        NSArray *row = records[rowIdx];
        TodoItem *item = [[TodoItem alloc] init];
        item.source = TodoSourceLark;
        item.itemId = (rowIdx < recordIds.count) ? recordIds[rowIdx] : @"";

        NSString *(^strAt)(NSString *) = ^NSString *(NSString *name) {
            NSNumber *idx = fieldIdx[name];
            if (!idx || idx.unsignedIntegerValue >= row.count) return nil;
            id val = row[idx.unsignedIntegerValue];
            if ([val isKindOfClass:[NSString class]] && [val length] > 0) return val;
            return nil;
        };

        item.content = strAt(@"待办内容") ?: @"(无内容)";
        item.status = strAt(@"状态") ?: @"待做";
        item.deadline = strAt(@"截止日期");
        item.completed = [item.status isEqualToString:@"已完成"];

        [items addObject:item];
    }

    // Sort: incomplete first
    [items sortUsingComparator:^NSComparisonResult(TodoItem *a, TodoItem *b) {
        if (a.completed != b.completed) {
            return a.completed ? NSOrderedDescending : NSOrderedAscending;
        }
        NSString *sa = a.status, *sb = b.status;
        if ([sa isEqualToString:@"进行中"] && ![sb isEqualToString:@"进行中"]) return NSOrderedAscending;
        if (![sa isEqualToString:@"进行中"] && [sb isEqualToString:@"进行中"]) return NSOrderedDescending;
        return [a.content compare:b.content];
    }];

    return items;
}

// ============================================================================
#pragma mark - Write-back: Toggle Complete
// ============================================================================

- (void)todoRowDidToggleComplete:(TodoRowView *)row {
    TodoItem *item = row.todoItem;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (item.source == TodoSourceAppleReminder) {
            [self completeAppleReminder:item];
        } else {
            [self completeLarkTodo:item];
        }
    });
}

- (void)completeAppleReminder:(TodoItem *)item {
    EKReminder *reminder = item.ekReminder;
    if (!reminder) {
        // Try to find by identifier
        EKCalendarItem *ci = [self.eventStore calendarItemWithIdentifier:item.itemId];
        if ([ci isKindOfClass:[EKReminder class]]) {
            reminder = (EKReminder *)ci;
        }
    }
    if (!reminder) {
        NSLog(@"Cannot find reminder: %@", item.itemId);
        return;
    }

    reminder.completed = item.completed;
    NSError *err = nil;
    [self.eventStore saveReminder:reminder commit:YES error:&err];
    if (err) {
        NSLog(@"Error saving reminder: %@", err);
    } else {
        NSLog(@"Reminder '%@' marked %@", item.content, item.completed ? @"complete" : @"incomplete");
    }
}

- (void)completeLarkTodo:(TodoItem *)item {
    NSString *newStatus = item.completed ? @"已完成" : @"待做";
    NSString *jsonStr = [NSString stringWithFormat:@"{\"状态\":\"%@\"}", newStatus];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:kLarkCLI];
    task.arguments = @[@"base", @"+record-upsert",
                       @"--base-token", kBaseToken,
                       @"--table-id", kTableId,
                       @"--record-id", item.itemId,
                       @"--json", jsonStr];

    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *path = env[@"PATH"] ?: @"";
    env[@"PATH"] = [path stringByAppendingString:@":/usr/local/bin:/opt/homebrew/bin:/Users/mima0000/.npm-global/bin"];
    task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSLog(@"Lark status update result: %@", output);
    } @catch (NSException *e) {
        NSLog(@"Lark status update error: %@", e);
    }
}

// ============================================================================
#pragma mark - Write-back: Edit Content
// ============================================================================

- (void)todoRow:(TodoRowView *)row didEditContent:(NSString *)newContent {
    TodoItem *item = row.todoItem;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (item.source == TodoSourceAppleReminder) {
            [self editAppleReminder:item newContent:newContent];
        } else {
            [self editLarkTodo:item newContent:newContent];
        }
    });
}

- (void)editAppleReminder:(TodoItem *)item newContent:(NSString *)newContent {
    EKReminder *reminder = item.ekReminder;
    if (!reminder) {
        EKCalendarItem *ci = [self.eventStore calendarItemWithIdentifier:item.itemId];
        if ([ci isKindOfClass:[EKReminder class]]) {
            reminder = (EKReminder *)ci;
        }
    }
    if (!reminder) {
        NSLog(@"Cannot find reminder for edit: %@", item.itemId);
        return;
    }

    reminder.title = newContent;
    NSError *err = nil;
    [self.eventStore saveReminder:reminder commit:YES error:&err];
    if (err) {
        NSLog(@"Error editing reminder: %@", err);
    } else {
        NSLog(@"Reminder edited: '%@'", newContent);
    }
}

- (void)editLarkTodo:(TodoItem *)item newContent:(NSString *)newContent {
    // Escape special characters for JSON
    NSString *escaped = [newContent stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *jsonStr = [NSString stringWithFormat:@"{\"待办内容\":\"%@\"}", escaped];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:kLarkCLI];
    task.arguments = @[@"base", @"+record-upsert",
                       @"--base-token", kBaseToken,
                       @"--table-id", kTableId,
                       @"--record-id", item.itemId,
                       @"--json", jsonStr];

    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    NSString *path = env[@"PATH"] ?: @"";
    env[@"PATH"] = [path stringByAppendingString:@":/usr/local/bin:/opt/homebrew/bin:/Users/mima0000/.npm-global/bin"];
    task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    task.standardOutput = outPipe;
    task.standardError = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSLog(@"Lark content update result: %@", output);
    } @catch (NSException *e) {
        NSLog(@"Lark content update error: %@", e);
    }
}

// ============================================================================
#pragma mark - Rebuild UI
// ============================================================================

- (void)rebuildUI {
    // Remove all subviews
    for (NSView *sub in self.contentStack.subviews.copy) {
        [sub removeFromSuperview];
    }

    NSView *stack = self.contentStack;
    NSView *lastView = nil;

    // ---- Apple Reminders Section ----
    SectionHeaderView *appleHeader = [[SectionHeaderView alloc] initWithIcon:@"📅"
                                                                       title:@"苹果提醒事项"
                                                                       count:self.appleItems.count];
    [stack addSubview:appleHeader];
    [NSLayoutConstraint activateConstraints:@[
        [appleHeader.topAnchor constraintEqualToAnchor:stack.topAnchor],
        [appleHeader.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [appleHeader.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
    ]];
    lastView = appleHeader;

    if (self.appleItems.count == 0) {
        NSTextField *emptyLabel = [NSTextField labelWithString:@"暂无提醒事项（请在系统设置中授权）"];
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        emptyLabel.font = [NSFont systemFontOfSize:11.0];
        emptyLabel.textColor = [NSColor secondaryLabelColor];
        [stack addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [emptyLabel.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:4],
            [emptyLabel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:14],
            [emptyLabel.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-14],
        ]];
        lastView = emptyLabel;
    } else {
        for (TodoItem *item in self.appleItems) {
            TodoRowView *row = [[TodoRowView alloc] initWithTodoItem:item delegate:self];
            [stack addSubview:row];
            [NSLayoutConstraint activateConstraints:@[
                [row.topAnchor constraintEqualToAnchor:lastView.bottomAnchor],
                [row.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
                [row.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
            ]];
            lastView = row;
        }
    }

    // ---- Separator ----
    SeparatorView *sep = [[SeparatorView alloc] init];
    [stack addSubview:sep];
    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:8],
        [sep.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:10],
        [sep.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-10],
    ]];
    lastView = sep;

    // ---- Lark Section ----
    SectionHeaderView *larkHeader = [[SectionHeaderView alloc] initWithIcon:@"📋"
                                                                      title:@"飞书待办"
                                                                      count:self.larkItems.count];
    [stack addSubview:larkHeader];
    [NSLayoutConstraint activateConstraints:@[
        [larkHeader.topAnchor constraintEqualToAnchor:lastView.bottomAnchor],
        [larkHeader.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [larkHeader.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
    ]];
    lastView = larkHeader;

    if (self.larkItems.count == 0) {
        NSTextField *emptyLabel = [NSTextField labelWithString:@"暂无飞书待办"];
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        emptyLabel.font = [NSFont systemFontOfSize:11.0];
        emptyLabel.textColor = [NSColor secondaryLabelColor];
        [stack addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [emptyLabel.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:4],
            [emptyLabel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:14],
        ]];
        lastView = emptyLabel;
    } else {
        for (TodoItem *item in self.larkItems) {
            TodoRowView *row = [[TodoRowView alloc] initWithTodoItem:item delegate:self];
            [stack addSubview:row];
            [NSLayoutConstraint activateConstraints:@[
                [row.topAnchor constraintEqualToAnchor:lastView.bottomAnchor],
                [row.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
                [row.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
            ]];
            lastView = row;
        }
    }

    // Pin bottom
    if (lastView) {
        [NSLayoutConstraint activateConstraints:@[
            [lastView.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor constant:-8],
        ]];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end

// ============================================================================
#pragma mark - Main
// ============================================================================

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
