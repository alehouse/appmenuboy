//
//  AppMenu.m
//  AppMenu
//
//  Created by David Oster on 1/20/08.
//  Copyright 2008-2009 Google Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not
//  use this file except in compliance with the License.  You may obtain a copy
//  of the License at
// 
//  http://www.apache.org/licenses/LICENSE-2.0
// 
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
//  License for the specific language governing permissions and limitations under
//  the License.
//
// Purpose: in OS X 10.4, you could drag the Applications folder in Finder to
//    the Dock to get a poor man's "Start" menu. 
//    This function is broken in OS X 10.5.0. This app has a dock menu that shows
//    your applications. It also puts a copy in the menu bar, with small icons.
//
//
// Theory of operation:
//   applicationDidFinishLaunching: calls rebuildMenus, which:
//    * discards the contents of the array of KQueue listeners.
//    * rebuilds the hierarchical menu of apps in the menu bar.
//      (which, as a side-effect, rebuilds the array of KQueue listeners)
//    * copies that menu as the dock menu.
//  
// - (void)buildTree:(NSString *)path intoMenu:(NSMenu *)menu depth:(int)depth;
//   does the actual work of building a directory into a menu.
// It loops over all the files in the directory, for each file, categorizing, 
//    then dispatching to a handler.
//
// There are three handlers, each making a menu item:
// - (void)appBundle:(NSString *)file path:(NSString *)path into:(NSMutableArray *)items;
// - (void)carbonApp:(NSString *)file path:(NSString *)path into:(NSMutableArray *)items;
//
// Makes a sub menu menu item for following subfolders.
// - (void)subDir:(NSString *)file path:(NSString *)path into:(NSMutableArray *)items depth:(int)depth;
//
// The O.S. handles hard links and soft links automatically, but Finder Alias
//    Files require us to do some work. 
//
// The "depth" parameter artificially restricts the submenu tree to being at 
//    most N deep.

// DONE:
// * icon for this app.
// * If a subfolder contains only one app, then replace the subfolder by the app.
// * icons with sub menus
// * treat non-app subfolders as hierarchical menus. restrict depths
// * handle Finder Alias files.
// * when clicked, tell application "Finder" to open path
// * put copy of app menu on main menu bar
// 1.0.1 12/12/07
// * folder icons.
// * File menu removed
//  6/16/08
// * Changed format of Interface Builder file for also building on Tiger.
// 1.0.2 8/10/09
// * Listens for directory changes, and rebuild the menu automatically.
// * Uses the localized name from the en.lproj/InfoPlist.strings file.
// * Uses the localized name for folders.
// * Reports its version in the Finder about box.
// * Refactored to build a NSMutableArray, sort, build the menu from that
// * Added a BOOL preference, "ignoringParens", to skip parenthesized folders.
// 1.0.3 8/14/09
// * Refactored to do its work in a thread so U.I. doesn't block.
// * Says "Working…" while its working.
// * Add a BOOL preference dialog to set the ignoringParens preference.
// 1.0.4 8/21/09
// Well, that was a disaster. Now it is often hanging. Rewrite. Use a lock
// between the KQueue elements and the main thread at their only point of communication: the
// bool moreToDo

#import "AppMenu.h"
#import <Carbon/Carbon.h>
#import "GTMFileSystemKQueue.h" // see http://code.google.com/mac/
#import "NSString+ResolveAlias.h"

// usage:   DEBUGBLOCK{ NSLog(@"Debugging only code block here."); }
#if DEBUG
#define DEBUGBLOCK if(1)
#else
#define DEBUGBLOCK if(0)
#endif

@interface NSMenu(AppMenu)

- (void)removeAllItems;

- (void)resetFromArray:(NSArray *)array;

@end

@implementation NSMenu(AppMenu)

- (void)removeAllItems {
  int i, iCount = [self numberOfItems];
  for (i = iCount - 1;0 <= i; --i) {
    [self removeItemAtIndex:i];
  }
}

- (void)resetFromArray:(NSArray *)array {
  [self removeAllItems];
  NSEnumerator *items = [array objectEnumerator];
  NSMenuItem *item;
  while (nil != (item = [items nextObject])) {
    [self addItem:item];
  }
}

@end

@interface NSMenuItem(AppMenu)

- (NSComparisonResult)compareAsFinder:(NSMenuItem *)other;

@end

@implementation NSMenuItem(AppMenu)

- (NSComparisonResult)compareAsFinder:(NSMenuItem *)other {
  return [[self title] localizedCaseInsensitiveCompare:[other title]];
}

@end

typedef enum  {
  kIgnore,
  kAppBundle,
  kSubDir,
  kCarbonApp
} FileCategoryEnum;

@interface AppMenu(ForwardDeclarations)

// main routine of this program: loop over a directory building menus
- (void)buildTree:(NSString *)path into:(NSMutableArray *)items depth:(int)depth shouldListen:(BOOL)shouldListen;
- (void)buildTree:(NSString *)path intoMenu:(NSMenu *)menu depth:(int)depth shouldListen:(BOOL)shouldListen;

- (void)rebuildMenusInThread;
- (void)showIgnoringParentheses;

- (BOOL)testAndClearMoreToDo;
- (void)setMoreToDo:(BOOL)moreToDo;

- (GTMFileSystemKQueue *)kqueueForKey:(NSString *)key;
- (void)setKQueue:(GTMFileSystemKQueue *)kqueue forKey:(NSString *)key;
- (void)removeKQueueForKey:(NSString *)key;
@end

@implementation AppMenu

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  NSString *menuTitle = NSLocalizedString(@"Apps", @"");
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:menuTitle action:nil keyEquivalent:@""] autorelease];
  NSString *workingTitle = NSLocalizedString(@"Working", @"");
  NSMenuItem *workingItem = [[[NSMenuItem alloc] initWithTitle:workingTitle action:nil keyEquivalent:@""] autorelease];
  appMenu_ = [[NSMenu alloc] initWithTitle:menuTitle];
  [appMenu_ addItem:workingItem];
  [item setSubmenu:appMenu_];
  [[NSApp mainMenu] addItem:item];

  kqueuesLock_ = [[NSLock alloc] init];
  kqueues_ = [[NSMutableDictionary alloc] init];

  moreToDoLock_ = [[NSLock alloc] init];
  [self rebuildMenusInThread];
}

- (void)dealloc {
  [appMenu_ release];
  [kqueuesLock_ release];
  [kqueues_ release];
  [moreToDoLock_ release];
  [super dealloc];
}


// app will call this to get the dock menu.
- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
  return dockMenu_;
}

// Create a GTMFileSystemKQueue object for the path, and remember it in an array.
- (void)addKQueueForPath:(NSString *)fullPath {
  if (nil == [self kqueueForKey:fullPath]) {
    GTMFileSystemKQueue *kq = [[[GTMFileSystemKQueue alloc] 
        initWithPath:fullPath
           forEvents:kGTMFileSystemKQueueAllEvents
       acrossReplace:NO
              target:self
              action:@selector(fileSystemKQueue:events:)] autorelease];
    if (nil != kq && nil == [self kqueueForKey:[kq path]]) {
      [self setKQueue:kq forKey:[kq path]];
    }
  }
}

// Folder changed. Rebuild the menus in a worker thread.
- (void)fileSystemKQueue:(GTMFileSystemKQueue *)kq
                  events:(GTMFileSystemKQueueEvents)events {
  DEBUGBLOCK{ NSLog(@"%@ %d", kq, events); }
  if (events & (kGTMFileSystemKQueueRevokeEvent|kGTMFileSystemKQueueDeleteEvent|kGTMFileSystemKQueueRenameEvent)) {
    [self removeKQueueForKey:[kq path]];
  }
  [self rebuildMenusInThread];
}

// helper routine: give each item a small icon for app at fullPath.
- (void)setImagePath:(NSString *)fullPath forItem:(NSMenuItem *)item {
  NSWorkspace *ws = [NSWorkspace sharedWorkspace];
  NSImage *image = [ws iconForFile:fullPath];
  if (image) {
    [image setSize:NSMakeSize(16,16)];  // makes it small
    [item setImage:image];
  }
}

#pragma mark -
// Build menu item for an ordinary OS X app.
// 
- (void)appBundle:(NSString *)file path:(NSString *)fullPath into:(NSMutableArray *)items {
  NSString *trimmedFile = nil;

  CFStringRef displayName = NULL;
  // Prefer the localized name from the Info.plist.
  if (noErr == LSCopyDisplayNameForURL((CFURLRef) [NSURL fileURLWithPath:fullPath], &displayName) &&
    NULL != displayName) {
    trimmedFile = [(NSString *)displayName autorelease];
  }
  if (nil == trimmedFile) {
    // Should never happen because Launch Services should already have looked up the correct name.
    NSRange matchRange = [file rangeOfString:@".app" options:NSCaseInsensitiveSearch|NSBackwardsSearch|NSAnchoredSearch];
    if (0 != matchRange.length) {
      trimmedFile = [file substringToIndex:matchRange.location];
    }
  }
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:trimmedFile action:@selector(openAppItem:) keyEquivalent:@""] autorelease];
  [item setRepresentedObject:fullPath];
  [items addObject:item];
  [self setImagePath:fullPath forItem:item];
}

// Build menu item for a subdirectory
- (void)subDir:(NSString *)file path:(NSString *)fullPath  into:(NSMutableArray *)items depth:(int)depth shouldListen:(BOOL)shouldListen {
  NSMenu *subMenu = [[[NSMenu alloc] initWithTitle:file] autorelease];
  if (depth < 6) {  // limit recursion depth.
    [self buildTree:fullPath intoMenu:subMenu depth:1+depth shouldListen:shouldListen];
  }
  if (0 < [subMenu numberOfItems]) {
    NSMenuItem *item = nil;
    if (1 == [subMenu numberOfItems]) {
      item = [subMenu itemAtIndex:0];
      [[item retain] autorelease];
      [subMenu removeItemAtIndex:0];
    } else {
      CFStringRef displayName = NULL;
      if (noErr == LSCopyDisplayNameForURL((CFURLRef) [NSURL fileURLWithPath:fullPath], &displayName) &&
        NULL != displayName) {
        file = [(NSString *)displayName autorelease];
      }
      item = [[[NSMenuItem alloc] initWithTitle:file action:@selector(openAppItem:) keyEquivalent:@""] autorelease];
      [item setRepresentedObject:fullPath];
      [item setSubmenu:subMenu];
      [self setImagePath:fullPath forItem:item];
    }
    [items addObject:item];
  }
}

// Build menu item for an all in one file GUI app.
- (void)carbonApp:(NSString *)file path:(NSString *)fullPath into:(NSMutableArray *)items {
  NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:file action:@selector(openAppItem:) keyEquivalent:@""] autorelease];
  [item setRepresentedObject:fullPath];
  [items addObject:item];
  [self setImagePath:fullPath forItem:item];
}
#pragma mark -

// What kind of file system object is this? returns enum.
- (FileCategoryEnum)categorizeFile:(NSString *)file path:(NSString *)fullPath {
  if (nil == file || [file hasPrefix:@"."]) {
    return kIgnore;
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL isDirectory = NO;
  if ([fm fileExistsAtPath:fullPath isDirectory:&isDirectory] && 
          isDirectory) {
          
    NSString *trimmedFile = file;
    NSRange matchRange = [trimmedFile rangeOfString:@".app" options:NSCaseInsensitiveSearch|NSBackwardsSearch|NSAnchoredSearch];
    if (0 != matchRange.length) {
      return kAppBundle;
    }

    // a few early OS X apps don't end in a .app extension. Dig deeper for them.
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    if ([ws isFilePackageAtPath:fullPath]) {
      NSBundle *bundle = [NSBundle bundleWithPath:fullPath];
      NSDictionary *info = [bundle infoDictionary];
      if ([[info objectForKey:@"CFBundlePackageType"] isEqual:@"APPL"]) {
        return kAppBundle;
      }
    }
    if (isIgnoringParentheses_ && [file hasPrefix:@"("] && [file hasSuffix:@")"]) {
      return kIgnore;
    }
    return kSubDir;
  } else {
    NSDictionary *fileAttributes = [fm fileAttributesAtPath:fullPath traverseLink:YES];
    OSType typeCode = [fileAttributes fileHFSTypeCode];
    if (typeCode == 'APPL') {
      return kCarbonApp;
    }
  }
  return kIgnore;
}


// main routine of this program: loop over a directory building menu items into an array
- (void)buildTree:(NSString *)path into:(NSMutableArray *)items depth:(int)depth shouldListen:(BOOL)shouldListen {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *files = [fm directoryContentsAtPath:path];
  NSEnumerator *fileEnumerator = [files objectEnumerator];
  NSString *file;
  while (nil != (file = [fileEnumerator nextObject])) {
    NSString *fullPath = [path stringByAppendingPathComponent:file];
    if ([fullPath isAliasFile]) {
      fullPath = [fullPath resolveAliasFile];
    }
    switch ([self categorizeFile:file path:fullPath]) {
    case kAppBundle: [self appBundle:file path:fullPath into:items]; break;
    case kSubDir:    [self subDir:file path:fullPath into:items depth:depth + 1 shouldListen:shouldListen]; break;
    case kCarbonApp: [self carbonApp:file path:fullPath into:items];break;
    default:
    case kIgnore:    break;
    }
  }
}

// loop over a directory building menu
- (void)buildTree:(NSString *)path intoMenu:(NSMenu *)menu depth:(int)depth shouldListen:(BOOL)shouldListen {
  if (shouldListen) {
    [self performSelectorOnMainThread:@selector(addKQueueForPath:) withObject:path waitUntilDone:YES];
  }
  NSMutableArray *items = [NSMutableArray array];
  [self buildTree:path into:items depth:depth shouldListen:shouldListen];
  [items sortUsingSelector:@selector(compareAsFinder:)];
  [menu performSelectorOnMainThread:@selector(resetFromArray:) withObject:items waitUntilDone:YES];
}

// Do the actual work of rebuilding the menus in a worker thread.
- (void)rebuildMenus {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  DEBUGBLOCK{ NSLog(@"rebuildMenus"); }
  isIgnoringParentheses_ = [[NSUserDefaults standardUserDefaults] boolForKey:@"ignoringParens"];
  [kqueues_ performSelectorOnMainThread:@selector(removeAllObjects) withObject:nil waitUntilDone:YES];
  [self buildTree:@"/Applications" intoMenu:appMenu_ depth:0 shouldListen:YES];
  [self buildTree:@"/Applications" intoMenu:dockMenu_ depth:0 shouldListen:NO];
  [self performSelectorOnMainThread:@selector(scheduleCheckForMore) withObject:nil waitUntilDone:NO];
  [pool drain];
}

// Up in the main event loop, on the main thread, check if the KQueue fired while we were working.
- (void)scheduleCheckForMore {
  [self performSelector:@selector(checkForMore) withObject:nil afterDelay:0.25];
}

// if the KQueue fired while we were working, do it again.
- (void)checkForMore {
  if ([self testAndClearMoreToDo]) {
    [self rebuildMenusInThread];
  }
}

// Rebuild the menus in a worker thread.
- (void)rebuildMenusInThread {
  [NSThread detachNewThreadSelector:@selector(rebuildMenus) toTarget:self withObject:nil];
}

#pragma mark -

- (void)openAppItem:(id)sender {
  NSWorkspace *ws = [NSWorkspace sharedWorkspace];
  NSString *path = [sender representedObject];
  if (path) {
    [ws openFile:path];
  }
}

- (IBAction)showPreferencesPanel:(id)sender {
  if ([preferencesWindow_ isVisible]) {
    [preferencesWindow_ orderOut:self];
  }else {
    [self showIgnoringParentheses];
    [preferencesWindow_ makeKeyAndOrderFront:self];
  }
}

- (IBAction)toggleIgnoringParentheses:(id)sender {
  isIgnoringParentheses_ = !isIgnoringParentheses_;
  [[NSUserDefaults standardUserDefaults] setBool:isIgnoringParentheses_ forKey:@"ignoringParens"];
  [self rebuildMenusInThread];
}

- (void)showIgnoringParentheses {
  isIgnoringParentheses_ = [[NSUserDefaults standardUserDefaults] boolForKey:@"ignoringParens"];
  [ignoringParentheses_ setIntValue:isIgnoringParentheses_];
}

- (BOOL)testAndClearMoreToDo {
  [moreToDoLock_ lock];
  BOOL moreToDo = moreToDo_;
  moreToDo_ = NO;
  [moreToDoLock_ unlock];
  return moreToDo;
}

- (void)setMoreToDo:(BOOL)moreToDo {
  [moreToDoLock_ lock];
  moreToDo_ = moreToDo;
  [moreToDoLock_ unlock];
}


- (GTMFileSystemKQueue *)kqueueForKey:(NSString *)key {
  [kqueuesLock_ lock];
  GTMFileSystemKQueue *kqueue = [kqueues_ objectForKey:key];
  [kqueuesLock_ unlock];
  return kqueue;
}

- (void)setKQueue:(GTMFileSystemKQueue *)kqueue forKey:(NSString *)key {
  [kqueuesLock_ lock];
  [kqueues_ setObject:kqueue forKey:key];
  [kqueuesLock_ unlock];
}

- (void)removeKQueueForKey:(NSString *)key {
  [kqueuesLock_ lock];
  [kqueues_ removeObjectForKey:key];
  [kqueuesLock_ unlock];
}

@end
// The following was documented as putting an icon in a dock menu item, but I couldn't get it to work:
//http://developer.apple.com/documentation/Carbon/Conceptual/customizing_docktile/tasks/chapter_3_section_5.html
//SetMenuItemIconHandle (myMenu,  // <- menu ref
//                        2,  // <- ones based index.
//                        kMenuIconResourceType,
//                        (Handle) CFSTR("mySpecialIcon.icns") ); // normally a partial path to a .icns file.
//example: (doesn't work)
//MenuRef menu = GetApplicationDockTileMenu();
//SetMenuItemIconHandle(menu,  // <- menu ref
//                        CountMenuItems(menu),  // <- ones based index.
//                        kMenuIconResourceType,
//                        (Handle) CFSTR("/Applications/Address Book.app/Contents/Resources/AddressBook.icns") ); 