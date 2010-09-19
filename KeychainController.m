/*
 Copyright © Roman Zechmeister, 2010
 
 Dieses Programm ist freie Software. Sie können es unter den Bedingungen 
 der GNU General Public License, wie von der Free Software Foundation 
 veröffentlicht, weitergeben und/oder modifizieren, entweder gemäß 
 Version 3 der Lizenz oder (nach Ihrer Option) jeder späteren Version.
 
 Die Veröffentlichung dieses Programms erfolgt in der Hoffnung, daß es Ihnen 
 von Nutzen sein wird, aber ohne irgendeine Garantie, sogar ohne die implizite 
 Garantie der Marktreife oder der Verwendbarkeit für einen bestimmten Zweck. 
 Details finden Sie in der GNU General Public License.
 
 Sie sollten ein Exemplar der GNU General Public License zusammen mit diesem 
 Programm erhalten haben. Falls nicht, siehe <http://www.gnu.org/licenses/>.
*/

#import "KeychainController.h"
#import "KeyInfo.h"
#import "ActionController.h"

//KeychainController kümmert sich um das anzeigen und Filtern der Schlüssel-Liste.


@implementation KeychainController

@synthesize filteredKeyList;
@synthesize filterStrings;
@synthesize keychain;
@synthesize userIDsSortDescriptors;
@synthesize subkeysSortDescriptors;
@synthesize keyInfosSortDescriptors;


NSLock *updateLock;

- (void)initKeychains {
	keychain = [[NSMutableDictionary alloc] initWithCapacity:10];
	filteredKeyList = [[NSMutableArray alloc] initWithCapacity:10];
}


- (void)asyncUpdateKeyInfos:(NSArray *)keyInfos {
	[NSThread detachNewThreadSelector:@selector(updateKeyInfos:) toTarget:self withObject:keyInfos];
}


- (void)updateKeyInfos:(NSArray *)keyInfos {
	if (![updateLock tryLock]) {
		return;
	}
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	KeyInfo *keyInfo;
	GPGKey *gpgKey, *secKey;
	NSString *fingerprint;
	
	@try {
		
		[gpgContext setKeyListMode:(GPGKeyListModeLocal | GPGKeyListModeSignatures)];
		
		if (keyInfos && [keyInfos count] > 0) { // Nur die übergebenene Schlüssel aktualisieren.
						
			NSMutableSet *processedKeyInfos = [NSMutableSet setWithCapacity:[keyInfos count]];
			NSMutableArray *keyInfosToUpdate = [NSMutableArray array];
			NSMutableArray *gpgKeysToUpdate = [NSMutableArray array];
			NSMutableArray *secKeysToUpdate = [NSMutableArray array];
			
			
			for (NSObject *aObject in keyInfos) {
				if ([aObject isKindOfClass:[KeyInfo class]]) {
					fingerprint = [[(KeyInfo *)aObject primaryKeyInfo] fingerprint];
				} else {
					fingerprint = [aObject description];
				}
				
				keyInfo = [keychain objectForKey:fingerprint];
				
				if (keyInfo && ![processedKeyInfos containsObject:keyInfo]) {
					[processedKeyInfos addObject:keyInfo];
					
					gpgKey = [gpgContext keyFromFingerprint:fingerprint secretKey:NO];
					secKey = [gpgContext keyFromFingerprint:fingerprint secretKey:YES];
					
					if (gpgKey) {
						[keyInfosToUpdate addObject:keyInfo];
						[gpgKeysToUpdate addObject:gpgKey];
						[secKeysToUpdate addObject:secKey ? secKey : gpgKey];
					} else {
						[keychain removeObjectForKey:fingerprint];
					}
					if ([keyInfosToUpdate count] > 0) {
						[self performSelectorOnMainThread:@selector(updateKeyInfosWithDict:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:keyInfosToUpdate, @"keyInfos", gpgKeysToUpdate, @"gpgKeys", secKeysToUpdate, @"secKeys", nil] waitUntilDone:YES];

					}
					[keyInfo updateFilterText];
				}
			}
			
		} else { // Den kompletten Schlüsselbund aktualisieren.
			NSArray *gpgKeyList;
			NSMutableDictionary *secKeyDict = [NSMutableDictionary dictionaryWithCapacity:1];
			
			gpgKeyList = [[gpgContext keyEnumeratorForSearchPattern:nil secretKeysOnly:NO] allObjects]; //Liste aller GPGKeys.
			NSEnumerator *secKeyEnum = [gpgContext keyEnumeratorForSearchPattern:nil secretKeysOnly:YES];
			
			while (secKey = [secKeyEnum nextObject]) {
				[secKeyDict setObject:secKey forKey:[secKey fingerprint]];
			}
			
			[self performSelectorOnMainThread:@selector(updateKeychain:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:gpgKeyList, @"gpgKeyList", secKeyDict, @"secKeyDict", nil] waitUntilDone:YES];
			
			
			NSEnumerator *keychainEnumerator;
			keychainEnumerator = [keychain objectEnumerator];
			while (keyInfo = [keychainEnumerator nextObject]) {
				[keyInfo updateFilterText];
			}
		}
		[self performSelectorOnMainThread:@selector(updateFilteredKeyList:) withObject:nil waitUntilDone:YES];
	} @catch (NSException * e) {
		NSLog(@"Fehler in updateKeyInfos: %@", [e reason]);
	} @finally {
		[pool drain];
		[updateLock unlock];
	}
}

- (void)updateKeyInfosWithDict:(NSDictionary *)aDict {
	NSArray *keyInfos = [aDict objectForKey:@"keyInfos"];
	NSArray *gpgKeys = [aDict objectForKey:@"gpgKeys"];
	NSArray *secKeys = [aDict objectForKey:@"secKeys"];
	GPGKey *gpgKey, *secKey;
	
	NSUInteger i, count = [keyInfos count];
	for (i = 0; i < count; i++) {
		gpgKey = [gpgKeys objectAtIndex:i];
		secKey = [secKeys objectAtIndex:i];
		[[keyInfos objectAtIndex:i] updateWithGPGKey:gpgKey secretKey:gpgKey == secKey ? nil : secKey];
	}
}



- (void)updateKeychain:(NSDictionary *)aDict { //Darf nur im Main-Thread laufen!
	
	NSArray *gpgKeyList = [aDict objectForKey:@"gpgKeyList"];
	NSDictionary *secKeyDict = [aDict objectForKey:@"secKeyDict"];
	
	KeyInfo *keyInfo;
	GPGKey *gpgKey, *secKey;
	NSArray *keysToRemove;
	NSString *fingerprint;
	NSMutableDictionary *oldKeys;
	
	
	oldKeys = [NSMutableDictionary dictionaryWithDictionary:keychain];
	for (gpgKey in gpgKeyList) {
		fingerprint = [gpgKey fingerprint];
		secKey = [secKeyDict objectForKey:fingerprint];
		if (keyInfo = [keychain objectForKey:fingerprint]) {
			[keyInfo updateWithGPGKey:gpgKey secretKey:secKey];
			[oldKeys removeObjectForKey:[gpgKey fingerprint]];
		} else {
			keyInfo = [KeyInfo keyInfoWithGPGKey:gpgKey secretKey:secKey];
			[keychain setObject:keyInfo forKey:[keyInfo fingerprint]];
		}
	}
	
	keysToRemove = [oldKeys allKeys];
	for (fingerprint in keysToRemove) {
		[keychain removeObjectForKey:fingerprint];
	}
	
}

- (IBAction)updateFilteredKeyList:(id)sender { //Darf nur im Main-Thread laufen!
	static BOOL isUpdating = NO;
	if (isUpdating) {return;}
	isUpdating = YES;
	
	NSMutableArray *keysToRemove;
	NSArray *myKeyList;
	KeyInfo *keyInfo;
	
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	[self willChangeValueForKey:@"filteredKeyList"];
	
	if ([sender isKindOfClass:[NSTextField class]]) {
		self.filterStrings = [[sender stringValue] componentsSeparatedByString:@" "];
	}	
	
	keysToRemove = [NSMutableArray arrayWithArray:filteredKeyList];
	
	myKeyList = [keychain allValues];
	for (keyInfo in myKeyList) {
		if ([self isKeyInfoPassingFilterTest:keyInfo]) {
			if ([keysToRemove containsObject:keyInfo]) {
				[keysToRemove removeObject:keyInfo];
			} else {
				[filteredKeyList addObject:keyInfo];
			}
		}
	}
	[filteredKeyList removeObjectsInArray:keysToRemove];
	[self didChangeValueForKey:@"filteredKeyList"];
	
	[numberOfKeysLabel setStringValue:[NSString stringWithFormat:localized(@"%i of %i keys listed"), [filteredKeyList count], [keychain count]]];
	
	[pool drain];
	isUpdating = NO;
}

- (BOOL)isKeyInfoPassingFilterTest:(KeyInfo *)keyInfo {
	if (showSecretKeysOnly && ![keyInfo isSecret]) {
		return NO;
	}
	if (filterStrings && [filterStrings count] > 0) {
		for (NSString *searchString in filterStrings) {
			if ([searchString length] > 0) {
				if ([[keyInfo textForFilter] rangeOfString:searchString options:NSCaseInsensitiveSearch].length == 0) {
					return NO;
				}
			}
		}
	}
	return YES;
}	

- (id)init {
	self = [super init];
	keychainController = self;
	return self;
}

- (void)awakeFromNib {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	
	if (![self initGPG]) {
		[NSApp terminate:nil]; 
	}

	[self initKeychains];
	
	NSSortDescriptor *indexSort = [[NSSortDescriptor alloc] initWithKey:@"index" ascending:YES];
	NSSortDescriptor *nameSort = [[NSSortDescriptor alloc] initWithKey:@"name" ascending:YES];
	NSArray *sortDesriptors = [NSArray arrayWithObject:indexSort];
	self.subkeysSortDescriptors = sortDesriptors;
	self.userIDsSortDescriptors = sortDesriptors;
	self.keyInfosSortDescriptors = [NSArray arrayWithObjects:indexSort, nameSort, nil];
	[indexSort release];
	[nameSort release];
	
	
	
	updateLock = [[NSLock alloc] init];
	[self updateKeyInfos:nil];
	
    [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(updateThread) userInfo:nil repeats:YES];
	
	[pool drain];
}

- (BOOL)initGPG {
	@try {
		NSArray *engines = [GPGEngine availableEngines];
		BOOL engineFound = NO;
		for (GPGEngine *engine in engines) {
			if ([[engine availableExecutablePaths] count] > 0) {
				engineFound = YES;
				GPG_PATH = [[engine executablePath] retain];
				break;
			}
		}
		if (!engineFound) {
			NSRunAlertPanel(localized(@"Error"), localized(@"GPGNotFound_Msg"), localized(@"Quit_Button"), nil, nil);
			return NO;
		}
		gpgContext = [[GPGContext alloc] init];
		[gpgContext keyEnumeratorForSearchPattern:@"" secretKeysOnly:YES];
		[gpgContext stopKeyEnumeration];
		if (runGPGCommand(nil, nil, nil, @"--gpgconf-test", nil) != 0) {
			NSRunAlertPanel(localized(@"Error"), localized(@"GPGNotValid_Msg"), localized(@"Quit_Button"), nil, nil);
			return NO;
		}
	}
	@catch (NSException * e) {
		NSRunAlertPanel(localized(@"Error"), localized(@"GPGNotValid_Msg"), localized(@"Quit_Button"), nil, nil);
		return NO;
	}
	return YES;
}


- (BOOL)showSecretKeysOnly {
    return showSecretKeysOnly;
}

- (void)setShowSecretKeysOnly:(BOOL)value {
    if (showSecretKeysOnly != value) {
        showSecretKeysOnly = value;
		[self updateFilteredKeyList:nil];
    }
}


- (void)updateThread {
	[self updateKeyInfos:nil]; //TODO: Nach Update an die alte Position scrollen und die die zuvor ausgewählten Schlüssel wieder auswählen.
}



@end


@implementation KeyAlgorithmTransformer
+ (Class)transformedValueClass { return [NSString class]; }
+ (BOOL)allowsReverseTransformation { return NO; }
- (id)transformedValue:(id)value {
	switch ([value integerValue]) {
		case GPG_RSAAlgorithm:
			return localized(@"GPG_RSAAlgorithm");
		case GPG_RSAEncryptOnlyAlgorithm:
			return localized(@"GPG_RSAEncryptOnlyAlgorithm");
		case GPG_RSASignOnlyAlgorithm:
			return localized(@"GPG_RSASignOnlyAlgorithm");
		case GPG_ElgamalEncryptOnlyAlgorithm:
			return localized(@"GPG_ElgamalEncryptOnlyAlgorithm");
		case GPG_DSAAlgorithm:
			return localized(@"GPG_DSAAlgorithm");
		case GPG_EllipticCurveAlgorithm:
			return localized(@"GPG_EllipticCurveAlgorithm");
		case GPG_ECDSAAlgorithm:
			return localized(@"GPG_ECDSAAlgorithm");
		case GPG_ElgamalAlgorithm:
			return localized(@"GPG_ElgamalAlgorithm");
		case GPG_DiffieHellmanAlgorithm:
			return localized(@"GPG_DiffieHellmanAlgorithm");
		default:
			return @"";
	}	
}

@end

@implementation GPGKeyStatusTransformer
+ (Class)transformedValueClass { return [NSString class]; }
+ (BOOL)allowsReverseTransformation { return NO; }
- (id)transformedValue:(id)value {
	NSMutableString *statusText = [NSMutableString stringWithCapacity:2];
	NSInteger intValue = [value integerValue];
	BOOL isOK = YES;
	if (intValue & GPGKeyStatus_Invalid) {
		[statusText appendFormat:@"%@", localized(@"Invalid")];
		isOK = NO;
	}
	if (intValue & GPGKeyStatus_Revoked) {
		[statusText appendFormat:@"%@%@", isOK ? @"" : @", ", localized(@"Revoked")];
		isOK = NO;
	}
	if (intValue & GPGKeyStatus_Expired) {
		[statusText appendFormat:@"%@%@", isOK ? @"" : @", ", localized(@"Expired")];
		isOK = NO;
	}
	if (intValue & GPGKeyStatus_Disabled) {
		[statusText appendFormat:@"%@%@", isOK ? @"" : @", ", localized(@"Disabled")];
		isOK = NO;
	}
	if (isOK) {
		[statusText setString:localized(@"Key_Is_OK")];
	}
	return [[statusText copy] autorelease];
}

@end


