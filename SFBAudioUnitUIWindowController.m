/*
 *  Copyright (C) 2007 - 2009 Stephen F. Booth <me@sbooth.org>
 *  All Rights Reserved
 */

#import "SFBAudioUnitUIWindowController.h"
#import "SFBAudioUnitUISaveAUPresetSheet.h"

#include <CoreAudioKit/CoreAudioKit.h>
#include <AudioUnit/AUCocoaUIView.h>

// ========================================
// Toolbar item identifiers
// ========================================
static NSString * const AudioUnitUIToolbarIdentifier					= @"org.sbooth.AudioUnitUI.Toolbar";
static NSString * const PresetDrawerToolbarItemIdentifier				= @"org.sbooth.AudioUnitUI.Toolbar.PresetDrawer";
static NSString * const SavePresetToolbarItemIdentifier					= @"org.sbooth.AudioUnitUI.Toolbar.SavePreset";
static NSString * const BypassEffectToolbarItemIdentifier				= @"org.sbooth.AudioUnitUI.Toolbar.BypassEffect";
static NSString * const ExportPresetToolbarItemIdentifier				= @"org.sbooth.AudioUnitUI.Toolbar.ExportPreset";
static NSString * const ImportPresetToolbarItemIdentifier				= @"org.sbooth.AudioUnitUI.Toolbar.ImportPreset";

@interface SFBAudioUnitUIWindowController (NotificationManagerMethods)
- (void) auViewFrameDidChange:(NSNotification *)notification;
@end

@interface SFBAudioUnitUIWindowController (PanelCallbacks)
- (void) savePresetToFileSavePanelDidEnd:(NSSavePanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void) loadPresetFromFileOpenPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo;
- (void) savePresetSaveAUPresetSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo;
@end

@interface SFBAudioUnitUIWindowController (Private)
- (void) updateAudioUnitNameAndManufacturer;
- (NSArray *) localPresets;
- (NSArray *) userPresets;
- (NSArray *) presetsForDomain:(short)domain;
- (void) scanPresets;
- (void) updatePresentPresetName;
- (void) updateBypassEffectToolbarItem;
- (void) notifyAUListenersOfParameterChanges;
- (void) startListeningForParameterChangesOnAudioUnit:(AudioUnit)audioUnit;
- (void) stopListeningForParameterChangesOnAudioUnit:(AudioUnit)audioUnit;
- (BOOL) hasCocoaView;
- (NSView *) getCocoaView;
@end

// ========================================
// AUEventListener callbacks
// ========================================
static void 
myAUEventListenerProc(void						*inCallbackRefCon,
					  void						*inObject,
					  const AudioUnitEvent		*inEvent,
					  UInt64					inEventHostTime,
					  Float32					inParameterValue)
{
	SFBAudioUnitUIWindowController *myself = (SFBAudioUnitUIWindowController *)inCallbackRefCon;
	
	if(kAudioUnitEvent_PropertyChange == inEvent->mEventType) {
		switch(inEvent->mArgument.mProperty.mPropertyID) {
			case kAudioUnitProperty_BypassEffect:		[myself updateBypassEffectToolbarItem];			break;
			case kAudioUnitProperty_PresentPreset:		[myself updatePresentPresetName];				break;
		}
	}
}

@implementation SFBAudioUnitUIWindowController

- (id) init
{
	if((self = [super initWithWindowNibName:@"SFBAudioUnitUIWindow"])) {
		_presetsTree = [[NSMutableArray alloc] init];
		
		OSStatus err = AUEventListenerCreate(myAUEventListenerProc,
											 self,
											 CFRunLoopGetCurrent(),
											 kCFRunLoopDefaultMode,
											 0.1,
											 0.1,
											 &_auEventListener);
		if(noErr != err) {
			[self release];
			return nil;
		}		
	}
	return self;
}

- (void) dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self 
													name:NSViewFrameDidChangeNotification 
												  object:_auView];

	if(NULL != _audioUnit)
		[self stopListeningForParameterChangesOnAudioUnit:_audioUnit];

	OSStatus err = AUListenerDispose(_auEventListener);
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AUListenerDispose failed: %i", err);
	
	[_auNameAndManufacturer release], _auNameAndManufacturer = nil;
	[_auManufacturer release], _auManufacturer = nil;
	[_auName release], _auName = nil;
	[_auPresentPresetName release], _auPresentPresetName = nil;

	[_auView release], _auView = nil;
	[_presetsTree release], _presetsTree = nil;
	
	_audioUnit = NULL;
	
	[super dealloc];
}

- (void) awakeFromNib
{
	// Setup the toolbar
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:AudioUnitUIToolbarIdentifier];
    
    [toolbar setAllowsUserCustomization:NO];
    [toolbar setDelegate:self];
	
    [[self window] setToolbar:[toolbar autorelease]];
}

- (AudioUnit) audioUnit
{
	return _audioUnit;
}

- (void) setAudioUnit:(AudioUnit)audioUnit
{
	NSParameterAssert(NULL != audioUnit);
	
	if(audioUnit == [self audioUnit])
		return;
	
	// Unregister for all notifications and AUEvents for the current AudioUnit
	if(_auView)
		[[NSNotificationCenter defaultCenter] removeObserver:self 
														name:NSViewFrameDidChangeNotification 
													  object:_auView];
	
	if(NULL != _audioUnit)
		[self stopListeningForParameterChangesOnAudioUnit:_audioUnit];

	// Update the AU
	_audioUnit = audioUnit;

	[[self window] setContentView:nil];
	[_auView release], _auView = nil;

	// Determine if there is a Cocoa view for this AU
	if([self hasCocoaView])
		_auView = [[self getCocoaView] retain];
	else
		_auView = [[AUGenericView alloc] initWithAudioUnit:audioUnit
											  displayFlags:(AUViewTitleDisplayFlag | AUViewPropertiesDisplayFlag | AUViewParametersDisplayFlag)];
//	[_auView setShowsExpertParameters:YES];

	NSRect oldFrameRect = [[self window] frame];
	NSRect newFrameRect = [[self window] frameRectForContentRect:[_auView frame]];
	
	newFrameRect.origin.x = oldFrameRect.origin.x + (oldFrameRect.size.width - newFrameRect.size.width);
	newFrameRect.origin.y = oldFrameRect.origin.y + (oldFrameRect.size.height - newFrameRect.size.height);
	
	[[self window] setFrame:newFrameRect display:YES];
	[[self window] setContentView:_auView];
	
	// Register for notifications and AUEvents for the new AudioUnit
	[[NSNotificationCenter defaultCenter] addObserver:self 
											 selector:@selector(auViewFrameDidChange:) 
												 name:NSViewFrameDidChangeNotification 
											   object:_auView];
	
	[self startListeningForParameterChangesOnAudioUnit:_audioUnit];

	// Scan the presets for the new AudioUnit
	[self updateAudioUnitNameAndManufacturer];
	[self scanPresets];
		
	// Synchronize UI to AudioUnit state
	[self updatePresentPresetName];
	[self updateBypassEffectToolbarItem];

	// Set the window title to the name of the AudioUnit
	[[self window] setTitle:_auName];
}

- (IBAction) savePreset:(id)sender
{
	SFBAudioUnitUISaveAUPresetSheet *saveAUPresetSheet = [[SFBAudioUnitUISaveAUPresetSheet alloc] init];
	
	[saveAUPresetSheet setPresetName:_auPresentPresetName];
	
	[[NSApplication sharedApplication] beginSheet:[saveAUPresetSheet sheet] 
								   modalForWindow:[self window] 
									modalDelegate:self 
								   didEndSelector:@selector(savePresetSaveAUPresetSheetDidEnd:returnCode:contextInfo:) 
									  contextInfo:saveAUPresetSheet];
}

- (IBAction) toggleBypassEffect:(id)sender
{
	UInt32 bypassEffect = NO;
	UInt32 dataSize = sizeof(bypassEffect);
	
	ComponentResult err = AudioUnitGetProperty([self audioUnit], 
											   kAudioUnitProperty_BypassEffect,
											   kAudioUnitScope_Global, 
											   0, 
											   &bypassEffect,
											   &dataSize);
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AudioUnitGetProperty(kAudioUnitProperty_BypassEffect) failed: %i", err);
	
	bypassEffect = ! bypassEffect;
	
	err = AudioUnitSetProperty([self audioUnit], 
							   kAudioUnitProperty_BypassEffect,
							   kAudioUnitScope_Global, 
							   0, 
							   &bypassEffect, 
							   sizeof(bypassEffect));
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AudioUnitSetProperty(kAudioUnitProperty_BypassEffect) failed: %i", err);
	
	[self notifyAUListenersOfParameterChanges];
}

- (IBAction) savePresetToFile:(id)sender
{
	NSSavePanel *savePanel = [NSSavePanel savePanel];
	
	[savePanel setAllowedFileTypes:[NSArray arrayWithObject:@"aupreset"]];
	
	[savePanel beginSheetForDirectory:nil 
								 file:nil
					   modalForWindow:[self window]
						modalDelegate:self
					   didEndSelector:@selector(savePresetToFileSavePanelDidEnd:returnCode:contextInfo:)
						  contextInfo:nil];
}

- (IBAction) loadPresetFromFile:(id)sender
{
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	
	[openPanel setCanChooseFiles:YES];
	[openPanel setCanChooseDirectories:NO];
	
	[openPanel beginSheetForDirectory:nil 
								 file:nil
								types:[NSArray arrayWithObject:@"aupreset"]
					   modalForWindow:[self window]
						modalDelegate:self
					   didEndSelector:@selector(loadPresetFromFileOpenPanelDidEnd:returnCode:contextInfo:)
						  contextInfo:nil];	
}

- (void) loadFactoryPresetNumber:(NSNumber *)presetNumber presetName:(NSString *)presetName
{
	NSParameterAssert(nil != presetNumber);
	NSParameterAssert(0 <= [presetNumber intValue]);

	AUPreset preset;
	preset.presetNumber = (SInt32)[presetNumber intValue];
	preset.presetName = (CFStringRef)presetName;
	
	ComponentResult err = AudioUnitSetProperty([self audioUnit], 
											   kAudioUnitProperty_PresentPreset,
											   kAudioUnitScope_Global, 
											   0, 
											   &preset, 
											   sizeof(preset));
	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: AudioUnitSetProperty(kAudioUnitProperty_PresentPreset) failed: %i", err);
		return;
	}
	
	[self notifyAUListenersOfParameterChanges];
}

- (void) loadCustomPresetFromURL:(NSURL *)presetURL
{
	NSParameterAssert(nil != presetURL);

	NSError *error = nil;
	NSData *xmlData = [NSData dataWithContentsOfURL:presetURL options:NSUncachedRead error:&error];
	
	if(nil == xmlData) {
		NSLog(@"SFBAudioUnitUI: Unable to load preset from %@ (%@)", presetURL, error);
		return;
	}
	
	NSString *errorString = nil;
	NSPropertyListFormat plistFormat = NSPropertyListXMLFormat_v1_0;
	id classInfoPlist = [NSPropertyListSerialization propertyListFromData:xmlData 
														 mutabilityOption:NSPropertyListImmutable 
																   format:&plistFormat 
														 errorDescription:&errorString];
	
	if(nil != classInfoPlist) {
		ComponentResult err = AudioUnitSetProperty([self audioUnit],
												   kAudioUnitProperty_ClassInfo, 
												   kAudioUnitScope_Global, 
												   0, 
												   &classInfoPlist, 
												   sizeof(classInfoPlist));
		if(noErr != err) {
			NSLog(@"SFBAudioUnitUI: AudioUnitSetProperty(kAudioUnitProperty_ClassInfo) failed: %i", err);
			return;
		}
		
		[self notifyAUListenersOfParameterChanges];
	}
	else
		NSLog(@"SFBAudioUnitUI: Unable to create property list for AU class info: %@", errorString);
}

- (void) saveCustomPresetToURL:(NSURL *)presetURL presetName:(NSString *)presetName
{
	NSParameterAssert(nil != presetURL);

	// First set the preset's name
	if(nil == presetName)
		presetName = [[[presetURL path] lastPathComponent] stringByDeletingPathExtension];
	
	AUPreset preset;
	preset.presetNumber = -1;
	preset.presetName = (CFStringRef)presetName;
	
	ComponentResult err = AudioUnitSetProperty([self audioUnit], 
											   kAudioUnitProperty_PresentPreset,
											   kAudioUnitScope_Global, 
											   0, 
											   &preset, 
											   sizeof(preset));
	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: AudioUnitSetProperty(kAudioUnitProperty_PresentPreset) failed: %i", err);
		return;
	}
	
	id classInfoPlist = NULL;
	UInt32 dataSize = sizeof(classInfoPlist);
	
	err = AudioUnitGetProperty([self audioUnit],
							   kAudioUnitProperty_ClassInfo, 
							   kAudioUnitScope_Global, 
							   0, 
							   &classInfoPlist, 
							   &dataSize);
	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: AudioUnitGetProperty(kAudioUnitProperty_ClassInfo) failed: %i", err);
		return;
	}
	
	NSString *errorString = nil;
	NSData *xmlData = [NSPropertyListSerialization dataFromPropertyList:classInfoPlist format:NSPropertyListXMLFormat_v1_0 errorDescription:&errorString];

	if(nil == xmlData) {
		NSLog(@"SFBAudioUnitUI: Unable to create property list from AU class info: %@", errorString);
		[errorString release];
		return;
	}
	
	// Create the directory structure if required
	NSString *presetPath = [[presetURL path] stringByDeletingLastPathComponent];
	if(![[NSFileManager defaultManager] fileExistsAtPath:presetPath]) {
		NSError *error = nil;
		BOOL dirStructureCreated = [[NSFileManager defaultManager] createDirectoryAtPath:presetPath withIntermediateDirectories:YES attributes:nil error:&error];
		if(!dirStructureCreated) {
			NSLog(@"SFBAudioUnitUI: Unable to create directories for %@", presetURL);
			return;
		}
	}
	
	BOOL presetSaved = [xmlData writeToURL:presetURL atomically:YES];
	if(!presetSaved) {
		NSLog(@"SFBAudioUnitUI: Unable to save preset to %@", presetURL);
		return;
	}

	[self notifyAUListenersOfParameterChanges];
}

- (void) selectPresetNumber:(NSNumber *)presetNumber presetName:(NSString *)presetName presetPath:(NSString *)presetPath
{
	// NSNull indicates a preset category that cannot be double-clicked
	if(nil == presetNumber || [NSNull null] == (id)presetNumber) {
		NSBeep();
		return;
	}
	
	if(-1 == [presetNumber intValue])
		[self loadCustomPresetFromURL:[NSURL fileURLWithPath:presetPath]];
	else
		[self loadFactoryPresetNumber:presetNumber presetName:presetName];
}

#pragma mark NSToolbar Delegate Methods

- (NSToolbarItem *) toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag 
{
    NSToolbarItem *toolbarItem = nil;
    
	NSBundle *myBundle = [NSBundle bundleForClass:[self class]];
	
    if([itemIdentifier isEqualToString:PresetDrawerToolbarItemIdentifier]) {
        toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];

		NSString *imagePath = [myBundle pathForResource:@"ToggleAUPresetDrawerToolbarImage" ofType:@"tiff"];
		NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];
		
		[toolbarItem setLabel:NSLocalizedStringFromTable(@"Presets", @"AudioUnitUI", @"")];
		[toolbarItem setPaletteLabel:NSLocalizedStringFromTable(@"Presets", @"AudioUnitUI", @"")];
		[toolbarItem setToolTip:NSLocalizedStringFromTable(@"Show or hide the presets drawer", @"AudioUnitUI", @"")];
		[toolbarItem setImage:image];
		
		[toolbarItem setTarget:_presetsDrawer];
		[toolbarItem setAction:@selector(toggle:)];
	}
    else if([itemIdentifier isEqualToString:SavePresetToolbarItemIdentifier]) {
        toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];

		NSString *imagePath = [myBundle pathForResource:@"SaveAUPresetToolbarImage" ofType:@"png"];
		NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];

		[toolbarItem setLabel:NSLocalizedStringFromTable(@"Save Preset", @"AudioUnitUI", @"")];
		[toolbarItem setPaletteLabel:NSLocalizedStringFromTable(@"Save Preset", @"AudioUnitUI", @"")];
		[toolbarItem setToolTip:NSLocalizedStringFromTable(@"Save the current settings as a preset", @"AudioUnitUI", @"")];
		[toolbarItem setImage:image];

		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(savePreset:)];
	}
	else if([itemIdentifier isEqualToString:BypassEffectToolbarItemIdentifier]) {
        toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];

		NSString *imagePath = [myBundle pathForResource:@"BypassAUToolbarImage" ofType:@"png"];
		NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];

		[toolbarItem setLabel:NSLocalizedStringFromTable(@"Bypass", @"AudioUnitUI", @"")];
		[toolbarItem setPaletteLabel:NSLocalizedStringFromTable(@"Bypass", @"AudioUnitUI", @"")];
		[toolbarItem setToolTip:NSLocalizedStringFromTable(@"Toggle whether the AudioUnit is bypassed", @"AudioUnitUI", @"")];
		[toolbarItem setImage:image];
		
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(toggleBypassEffect:)];
	}
	else if([itemIdentifier isEqualToString:ImportPresetToolbarItemIdentifier]) {
        toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];

		NSString *imagePath = [myBundle pathForResource:@"ImportAUPresetToolbarImage" ofType:@"png"];
		NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];

		[toolbarItem setLabel:NSLocalizedStringFromTable(@"Import Preset", @"AudioUnitUI", @"")];
		[toolbarItem setPaletteLabel:NSLocalizedStringFromTable(@"Import Preset", @"AudioUnitUI", @"")];
		[toolbarItem setToolTip:NSLocalizedStringFromTable(@"Import settings from a preset file", @"AudioUnitUI", @"")];
		[toolbarItem setImage:image];
		
		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(loadPresetFromFile:)];
	}
    else if([itemIdentifier isEqualToString:ExportPresetToolbarItemIdentifier]) {
        toolbarItem = [[[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier] autorelease];

		NSString *imagePath = [myBundle pathForResource:@"ExportAUPresetToolbarImage" ofType:@"png"];
		NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];

		[toolbarItem setLabel:NSLocalizedStringFromTable(@"Export Preset", @"AudioUnitUI", @"")];
		[toolbarItem setPaletteLabel:NSLocalizedStringFromTable(@"Export Preset", @"AudioUnitUI", @"")];
		[toolbarItem setToolTip:NSLocalizedStringFromTable(@"Export the current settings to a preset file", @"AudioUnitUI", @"")];
		[toolbarItem setImage:image];

		[toolbarItem setTarget:self];
		[toolbarItem setAction:@selector(savePresetToFile:)];
	}
	
    return toolbarItem;
}

- (NSArray *) toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar 
{
    return [NSArray arrayWithObjects:
			PresetDrawerToolbarItemIdentifier, 
			SavePresetToolbarItemIdentifier, 
			NSToolbarSpaceItemIdentifier, 
			BypassEffectToolbarItemIdentifier,
			NSToolbarFlexibleSpaceItemIdentifier,
			ImportPresetToolbarItemIdentifier, 
			ExportPresetToolbarItemIdentifier, 
			nil];
}

- (NSArray *) toolbarAllowedItemIdentifiers:(NSToolbar *) toolbar 
{
    return [NSArray arrayWithObjects:
			PresetDrawerToolbarItemIdentifier, 
			SavePresetToolbarItemIdentifier, 
			BypassEffectToolbarItemIdentifier,
			ImportPresetToolbarItemIdentifier, 
			ExportPresetToolbarItemIdentifier, 
			NSToolbarSeparatorItemIdentifier, 
			NSToolbarSpaceItemIdentifier, 
			NSToolbarFlexibleSpaceItemIdentifier,
			NSToolbarCustomizeToolbarItemIdentifier, 
			nil];
}

- (NSArray *) toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar
{
    return [NSArray arrayWithObject:BypassEffectToolbarItemIdentifier];
}

@end

@implementation SFBAudioUnitUIWindowController (NotificationManagerMethods)

- (void) auViewFrameDidChange:(NSNotification *)notification
{
	NSParameterAssert(_auView == [notification object]);
	
	NSView		*view		= _auView;
	NSWindow	*window		= [self window];
	
	[[NSNotificationCenter defaultCenter] removeObserver:self 
													name:NSViewFrameDidChangeNotification 
												  object:view];
	
	NSSize oldContentSize	= [window contentRectForFrameRect:[window frame]].size;
	NSSize newContentSize	= [view frame].size;
	NSRect windowFrame		= [window frame];
	
	float dy = oldContentSize.height - newContentSize.height;
	float dx = oldContentSize.width - newContentSize.width;
	
	windowFrame.origin.y		+= dy;
	windowFrame.origin.x		+= dx;
	windowFrame.size.height		-= dy;
	windowFrame.size.width		-= dx;
	
	[window setFrame:windowFrame display:YES];
	
	[[NSNotificationCenter defaultCenter] addObserver:self 
											 selector:@selector(auViewFrameDidChange:) 
												 name:NSViewFrameDidChangeNotification 
											   object:view];
}

@end

@implementation SFBAudioUnitUIWindowController (PanelCallbacks)

- (void) savePresetToFileSavePanelDidEnd:(NSSavePanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	if(NSCancelButton == returnCode)
		return;

	[self saveCustomPresetToURL:[panel URL] presetName:nil];
}

- (void) loadPresetFromFileOpenPanelDidEnd:(NSOpenPanel *)panel returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	if(NSCancelButton == returnCode)
		return;
	
	[self loadCustomPresetFromURL:[[panel URLs] lastObject]];
}

- (void) savePresetSaveAUPresetSheetDidEnd:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
	SFBAudioUnitUISaveAUPresetSheet *saveAUPresetSheet = (SFBAudioUnitUISaveAUPresetSheet *)contextInfo;
	
	[sheet orderOut:self];
	[saveAUPresetSheet autorelease];
	
	if(NSOKButton == returnCode) {
		int domain;
		switch([saveAUPresetSheet presetDomain]) {
			case kAudioUnitPresetDomain_User:		domain = kUserDomain;			break;
			case kAudioUnitPresetDomain_Local:		domain = kLocalDomain;			break;
			default:								domain = kUserDomain;			break;
		}
		
		FSRef presetFolderRef;
		OSErr err = FSFindFolder(domain, kAudioPresetsFolderType, kDontCreateFolder, &presetFolderRef);
		if(noErr != err)
			NSLog(@"SFBAudioUnitUI: FSFindFolder(kAudioPresetsFolderType) failed: %i", err);
		
		NSURL *presetsFolderURL = (NSURL *)CFURLCreateFromFSRef(kCFAllocatorSystemDefault, &presetFolderRef);
		if(nil == presetsFolderURL) {
			NSLog(@"SFBAudioUnitUI: CFURLCreateFromFSRef failed");
			return;
		}
		
		NSString *presetName = [saveAUPresetSheet presetName];
		NSArray *pathComponents = [NSArray arrayWithObjects:[presetsFolderURL path], _auManufacturer, _auName, presetName, nil];
		NSString *auPresetPath = [[[NSString pathWithComponents:pathComponents] stringByAppendingPathExtension:@"aupreset"] stringByStandardizingPath];
		
		[self saveCustomPresetToURL:[NSURL fileURLWithPath:auPresetPath] presetName:presetName];
		
		[self scanPresets];
		
		[presetsFolderURL release];
	}
}

@end

@implementation SFBAudioUnitUIWindowController (Private)

- (void) updateAudioUnitNameAndManufacturer
{
	[_auNameAndManufacturer release], _auNameAndManufacturer = nil;
	[_auManufacturer release], _auManufacturer = nil;
	[_auName release], _auName = nil;
	
	ComponentDescription cd;
	Handle componentNameHandle = NewHandle(sizeof(void *));
	if(NULL == componentNameHandle) {
		NSLog(@"SFBAudioUnitUI: NewHandle failed");	
		return;
	}

	OSErr err = GetComponentInfo((Component)[self audioUnit], &cd, componentNameHandle, NULL, NULL);
	if(noErr == err) {
		_auNameAndManufacturer = (NSString *)CFStringCreateWithPascalString(kCFAllocatorDefault, (ConstStr255Param)(*componentNameHandle), kCFStringEncodingUTF8);
		unsigned int index = [_auNameAndManufacturer rangeOfString:@":" options:NSLiteralSearch].location;
		if(NSNotFound != index) {
			_auManufacturer = [[_auNameAndManufacturer substringToIndex:index] copy];
			
			// Skip colon
			++index;
			
			// Skip whitespace
			NSCharacterSet *whitespaceCharacters = [NSCharacterSet whitespaceCharacterSet];
			while([whitespaceCharacters characterIsMember:[_auNameAndManufacturer characterAtIndex:index]])
				++index;
			
			_auName = [[_auNameAndManufacturer substringFromIndex:index] copy];			
		}
	}
	else
		NSLog(@"SFBAudioUnitUI: GetComponentInfo failed: %i", err);
	
	DisposeHandle(componentNameHandle);
}

- (void) scanPresets
{
	NSArray		*factoryPresets		= nil;
	UInt32		dataSize			= sizeof(factoryPresets);
	
	ComponentResult err = AudioUnitGetProperty([self audioUnit], 
											   kAudioUnitProperty_FactoryPresets,
											   kAudioUnitScope_Global, 
											   0, 
											   &factoryPresets, 
											   &dataSize);
	// Delay error checking
	
	[self willChangeValueForKey:@"presetsTree"];

	[_presetsTree removeAllObjects];
	
	NSMutableArray *factoryPresetsArray = [NSMutableArray array];
	
	if(noErr == err) {
		for(NSUInteger i = 0; i < [factoryPresets count]; ++i) {
			AUPreset *preset = (AUPreset *)[factoryPresets objectAtIndex:i];
			NSNumber *presetNumber = [NSNumber numberWithInt:preset->presetNumber];
			NSString *presetName = [(NSString *)preset->presetName copy];
			
			[factoryPresetsArray addObject:[NSDictionary dictionaryWithObjectsAndKeys:presetNumber, @"presetNumber", presetName, @"presetName", [NSNull null], @"presetPath", [NSNull null], @"children", nil]];

			[presetName release];
		}
	}
	else
		NSLog(@"SFBAudioUnitUI: AudioUnitGetProperty(kAudioUnitProperty_FactoryPresets) failed: %i", err);	

	if([factoryPresetsArray count])
		[_presetsTree addObject:[NSDictionary dictionaryWithObjectsAndKeys:factoryPresetsArray, @"children", NSLocalizedStringFromTable(@"Factory", @"AudioUnitUI", @""), @"presetName", [NSNull null], @"presetNumber", [NSNull null], @"presetPath", nil]];
	
	NSArray *localPresetsArray = [self localPresets];
	if([localPresetsArray count])
		[_presetsTree addObject:[NSDictionary dictionaryWithObjectsAndKeys:localPresetsArray, @"children", NSLocalizedStringFromTable(@"Local", @"AudioUnitUI", @""), @"presetName", [NSNull null], @"presetNumber", [NSNull null], @"presetPath", nil]];

	NSArray *userPresetsArray = [self userPresets];
	if([userPresetsArray count])
		[_presetsTree addObject:[NSDictionary dictionaryWithObjectsAndKeys:userPresetsArray, @"children", NSLocalizedStringFromTable(@"User", @"AudioUnitUI", @""), @"presetName", [NSNull null], @"presetNumber", [NSNull null], @"presetPath", nil]];
	
	[self didChangeValueForKey:@"presetsTree"];
	
	[factoryPresets release];
}

- (NSArray *) localPresets
{
	return [self presetsForDomain:kLocalDomain];
}

- (NSArray *) userPresets
{
	return [self presetsForDomain:kUserDomain];
}

- (NSArray *) presetsForDomain:(short)domain
{
	FSRef presetFolderRef;
	OSErr err = FSFindFolder(domain, kAudioPresetsFolderType, kDontCreateFolder, &presetFolderRef);
	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: FSFindFolder(kAudioPresetsFolderType) failed: %i", err);	
		return nil;
	}
	
	NSURL *presetsFolderURL = (NSURL *)CFURLCreateFromFSRef(kCFAllocatorSystemDefault, &presetFolderRef);
	if(nil == presetsFolderURL) {
		NSLog(@"SFBAudioUnitUI: CFURLCreateFromFSRef failed");	
		return nil;
	}

	NSArray *pathComponents = [NSArray arrayWithObjects:[presetsFolderURL path], _auManufacturer, _auName, nil];
	NSString *auPresetsPath = [[NSString pathWithComponents:pathComponents] stringByStandardizingPath];

	NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:auPresetsPath];
	NSString *path = nil;
	NSMutableArray *result = [[NSMutableArray alloc] init];
	
	while((path = [enumerator nextObject])) {
		// Skip files that aren't AU presets
		if(NO == [[path pathExtension] isEqualToString:@"aupreset"])
			continue;
		
		NSNumber *presetNumber = [NSNumber numberWithInt:-1];
		NSString *presetName = [[path lastPathComponent] stringByDeletingPathExtension];
		NSString *presetPath = [auPresetsPath stringByAppendingPathComponent:path];
		
		[result addObject:[NSDictionary dictionaryWithObjectsAndKeys:presetNumber, @"presetNumber", presetName, @"presetName", presetPath, @"presetPath", [NSNull null], @"children", nil]];
	}
	
	[presetsFolderURL release];
	
	return [result autorelease];
}

- (void) updatePresentPresetName
{
	AUPreset preset;
	UInt32 dataSize = sizeof(preset);
	
	ComponentResult err = AudioUnitGetProperty([self audioUnit], 
											   kAudioUnitProperty_PresentPreset,
											   kAudioUnitScope_Global, 
											   0, 
											   &preset,
											   &dataSize);
	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: AudioUnitGetProperty(kAudioUnitProperty_PresentPreset) failed: %i", err);	
		return;
	}

	[self willChangeValueForKey:@"auPresentPresetName"];
	
	[_auPresentPresetName release];
	_auPresentPresetName = (NSString *)preset.presetName;
	
	[self didChangeValueForKey:@"auPresentPresetName"];
}

- (void) updateBypassEffectToolbarItem
{
	UInt32 bypassEffect = NO;
	UInt32 dataSize = sizeof(bypassEffect);
	
	ComponentResult err = AudioUnitGetProperty([self audioUnit], 
											   kAudioUnitProperty_BypassEffect,
											   kAudioUnitScope_Global, 
											   0, 
											   &bypassEffect,
											   &dataSize);
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AudioUnitGetProperty(kAudioUnitProperty_BypassEffect) failed: %i", err);	
		
	if(bypassEffect)
		[[[self window] toolbar] setSelectedItemIdentifier:BypassEffectToolbarItemIdentifier];
	else
		[[[self window] toolbar] setSelectedItemIdentifier:nil];
}

- (void) notifyAUListenersOfParameterChanges
{
	AudioUnitParameter changedUnit;
	changedUnit.mAudioUnit = [self audioUnit];
	changedUnit.mParameterID = kAUParameterListener_AnyParameter;

	OSStatus err = AUParameterListenerNotify(NULL, NULL, &changedUnit);
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AUParameterListenerNotify failed: %i", err);
}

- (void) startListeningForParameterChangesOnAudioUnit:(AudioUnit)audioUnit
{
	NSParameterAssert(NULL != audioUnit);

	AudioUnitEvent propertyEvent;
    propertyEvent.mEventType = kAudioUnitEvent_PropertyChange;
    propertyEvent.mArgument.mProperty.mAudioUnit = audioUnit;
    propertyEvent.mArgument.mProperty.mPropertyID = kAudioUnitProperty_BypassEffect;
    propertyEvent.mArgument.mProperty.mScope = kAudioUnitScope_Global;
    propertyEvent.mArgument.mProperty.mElement = 0;
	
	OSStatus err = AUEventListenerAddEventType(_auEventListener, NULL, &propertyEvent);	
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AUEventListenerAddEventType(kAudioUnitProperty_BypassEffect) failed: %i", err);	

    propertyEvent.mEventType = kAudioUnitEvent_PropertyChange;
    propertyEvent.mArgument.mProperty.mAudioUnit = audioUnit;
    propertyEvent.mArgument.mProperty.mPropertyID = kAudioUnitProperty_PresentPreset;
    propertyEvent.mArgument.mProperty.mScope = kAudioUnitScope_Global;
    propertyEvent.mArgument.mProperty.mElement = 0;
	
	err = AUEventListenerAddEventType(_auEventListener, NULL, &propertyEvent);	
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AUEventListenerAddEventType(kAudioUnitProperty_PresentPreset) failed: %i", err);	
}

- (void) stopListeningForParameterChangesOnAudioUnit:(AudioUnit)audioUnit
{
	NSParameterAssert(NULL != audioUnit);

	AudioUnitEvent propertyEvent;
    propertyEvent.mEventType = kAudioUnitEvent_PropertyChange;
    propertyEvent.mArgument.mProperty.mAudioUnit = audioUnit;
    propertyEvent.mArgument.mProperty.mPropertyID = kAudioUnitProperty_BypassEffect;
    propertyEvent.mArgument.mProperty.mScope = kAudioUnitScope_Global;
    propertyEvent.mArgument.mProperty.mElement = 0;
	
	OSStatus err = AUEventListenerRemoveEventType(_auEventListener, NULL, &propertyEvent);	
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AUEventListenerRemoveEventType(kAudioUnitProperty_BypassEffect) failed: %i", err);	
	
    propertyEvent.mEventType = kAudioUnitEvent_PropertyChange;
    propertyEvent.mArgument.mProperty.mAudioUnit = audioUnit;
    propertyEvent.mArgument.mProperty.mPropertyID = kAudioUnitProperty_PresentPreset;
    propertyEvent.mArgument.mProperty.mScope = kAudioUnitScope_Global;
    propertyEvent.mArgument.mProperty.mElement = 0;
	
	err = AUEventListenerRemoveEventType(_auEventListener, NULL, &propertyEvent);	
	if(noErr != err)
		NSLog(@"SFBAudioUnitUI: AUEventListenerRemoveEventType(kAudioUnitProperty_PresentPreset) failed: %i", err);	
}

- (BOOL) hasCocoaView
{
	UInt32 dataSize = 0;
	Boolean writable = 0;
	
	ComponentResult err = AudioUnitGetPropertyInfo([self audioUnit],
												   kAudioUnitProperty_CocoaUI, 
												   kAudioUnitScope_Global,
												   0, 
												   &dataSize, 
												   &writable);

	return (0 < dataSize && noErr == err);
}

- (NSView *) getCocoaView
{
	NSView *theView = nil;
	UInt32 dataSize = 0;
	Boolean writable = 0;

	ComponentResult err = AudioUnitGetPropertyInfo([self audioUnit],
												   kAudioUnitProperty_CocoaUI, 
												   kAudioUnitScope_Global, 
												   0,
												   &dataSize,
												   &writable);

	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: AudioUnitGetPropertyInfo(kAudioUnitProperty_CocoaUI) failed: %i", err);
		return nil;
	}

	// If we have the property, then allocate storage for it.
	AudioUnitCocoaViewInfo *cocoaViewInfo = (AudioUnitCocoaViewInfo*) malloc(dataSize);
	err = AudioUnitGetProperty([self audioUnit], 
							   kAudioUnitProperty_CocoaUI, 
							   kAudioUnitScope_Global, 
							   0, 
							   cocoaViewInfo, 
							   &dataSize);

	if(noErr != err) {
		NSLog(@"SFBAudioUnitUI: AudioUnitGetProperty(kAudioUnitProperty_CocoaUI) failed: %i", err);
		return nil;
	}
	
	// Extract useful data.
	unsigned	numberOfClasses		= (dataSize - sizeof(CFURLRef)) / sizeof(CFStringRef);
	NSString	*viewClassName		= (NSString *)(cocoaViewInfo->mCocoaAUViewClass[0]);
	NSString	*path				= (NSString *)(CFURLCopyPath(cocoaViewInfo->mCocoaAUViewBundleLocation));
	NSBundle	*viewBundle			= [NSBundle bundleWithPath:[path autorelease]];
	Class		viewClass			= [viewBundle classNamed:viewClassName];

	if([viewClass conformsToProtocol:@protocol(AUCocoaUIBase)]) {
		id factory = [[[viewClass alloc] init] autorelease];
		theView = [factory uiViewForAudioUnit:[self audioUnit] withSize:NSZeroSize];
	}

	// Delete the cocoa view info stuff.
	if(cocoaViewInfo) {
		for(unsigned i = 0; i < numberOfClasses; ++i)
			CFRelease(cocoaViewInfo->mCocoaAUViewClass[i]);

		CFRelease(cocoaViewInfo->mCocoaAUViewBundleLocation);
		free(cocoaViewInfo);
	}

	return theView;
}

@end