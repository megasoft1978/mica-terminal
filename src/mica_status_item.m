#import "mica_status_item.h"

@interface MicaStatusItem ()
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, copy) NSMenu *(^menuBuilder)(void);
@end

@implementation MicaStatusItem
- (BOOL)isEnabled { return self.statusItem != nil; }
- (void)enableWithMenuBuilder:(NSMenu *(^)(void))builder {
    if (!self.statusItem) {
        self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Mica"];
        menu.delegate = self;
        self.statusItem.menu = menu;
    }
    self.menuBuilder = builder;
}
- (void)disable {
    if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
    self.statusItem = nil;
    self.menuBuilder = nil;
}
- (void)updateTitle:(NSString *)title accessibilityLabel:(NSString *)label {
    // Per-second refreshes touch the button only; menu contents are refreshed on open.
    self.statusItem.button.title = title;
    self.statusItem.button.accessibilityLabel = label;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (!self.menuBuilder) return;
    NSMenu *fresh = self.menuBuilder();
    // Keep the installed menu/delegate and replace rows only when the user opens it.
    [menu removeAllItems];
    for (NSMenuItem *item in fresh.itemArray) [menu addItem:[item copy]];
}
@end
