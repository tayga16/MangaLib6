#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *ChapterDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256([data bytes], (CC_LONG)[data length], digest);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
static NSString *ChapterKey(NSString *slug, NSDictionary *chapter) {
    NSArray *parts = [NSArray arrayWithObjects:slug ?: @"", [[chapter objectForKey:@"volume"] description] ?: @"",
        [[chapter objectForKey:@"number"] description] ?: @"", nil];
    return ChapterDigest([NSJSONSerialization dataWithJSONObject:parts options:0 error:NULL]);
}

// API metadata may contain JSON nulls, which property lists cannot store.
static id ChapterMetadata(id value) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (id key in value) if ([value objectForKey:key] != [NSNull null])
            [result setObject:ChapterMetadata([value objectForKey:key]) forKey:key];
        return result;
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id item in value) [result addObject:item == [NSNull null] ? @"" : ChapterMetadata(item)];
        return result;
    }
    return value;
}

@interface MangaLib6Downloads : NSObject {
    NSString *_root;
}
- (id)initWithRoot:(NSString *)root;
- (NSMutableDictionary *)entry:(NSString *)key;
- (NSArray *)entries;
- (BOOL)complete:(NSDictionary *)item;
- (NSUInteger)count:(NSDictionary *)item;
- (BOOL)hasPage:(NSInteger)index entry:(NSDictionary *)item;
- (NSData *)page:(NSInteger)index entry:(NSDictionary *)item;
- (NSMutableDictionary *)prepare:(NSDictionary *)manga chapter:(NSDictionary *)chapter pages:(NSArray *)pages;
- (BOOL)savePage:(NSData *)data index:(NSInteger)index entry:(NSMutableDictionary *)item;
- (BOOL)finish:(NSMutableDictionary *)item;
- (BOOL)remove:(NSString *)key;
@end

@implementation MangaLib6Downloads
- (id)initWithRoot:(NSString *)root { if ((self = [super init])) _root = [root copy]; return self; }
- (NSString *)folder:(NSString *)key {
    if ([key length] != 64 || [key rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return nil;
    return [_root stringByAppendingPathComponent:key];
}
- (NSString *)file:(NSInteger)index entry:(NSDictionary *)item {
    return [[self folder:[item objectForKey:@"id"]] stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.page", (long)index]];
}
- (BOOL)save:(NSDictionary *)item {
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:item format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
    NSString *folder = [self folder:[item objectForKey:@"id"]];
    return data && folder && [data writeToFile:[folder stringByAppendingPathComponent:@"chapter.plist"] options:NSDataWritingAtomic error:NULL];
}
- (NSMutableDictionary *)entry:(NSString *)key {
    NSString *folder = [self folder:key]; if (!folder) return nil;
    NSString *path = [folder stringByAppendingPathComponent:@"chapter.plist"];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (!attributes || [attributes fileSize] > 2 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id item = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL] : nil;
    if (![item isKindOfClass:[NSMutableDictionary class]] || ![[item objectForKey:@"id"] isEqual:key] ||
        ![[item objectForKey:@"manga"] isKindOfClass:[NSDictionary class]] ||
        ![[item objectForKey:@"chapter"] isKindOfClass:[NSDictionary class]] ||
        ![[[item objectForKey:@"manga"] objectForKey:@"slug_url"] isKindOfClass:[NSString class]] ||
        ![ChapterKey([[item objectForKey:@"manga"] objectForKey:@"slug_url"], [item objectForKey:@"chapter"]) isEqual:key]) return nil;
    for (NSString *field in [NSArray arrayWithObjects:@"pages", @"sizes", @"hashes", nil])
        if (![[item objectForKey:field] isKindOfClass:[NSArray class]]) return nil;
    NSUInteger count = [[item objectForKey:@"pages"] count];
    if (!count || [[item objectForKey:@"sizes"] count] != count || [[item objectForKey:@"hashes"] count] != count ||
        ![[item objectForKey:@"complete"] isKindOfClass:[NSNumber class]] ||
        ![[item objectForKey:@"saved_at"] isKindOfClass:[NSNumber class]]) return nil;
    for (NSUInteger i = 0; i < count; i++) {
        id page = [[item objectForKey:@"pages"] objectAtIndex:i];
        id size = [[item objectForKey:@"sizes"] objectAtIndex:i], hash = [[item objectForKey:@"hashes"] objectAtIndex:i];
        if (![page isKindOfClass:[NSDictionary class]] || ![[page objectForKey:@"url"] isKindOfClass:[NSString class]] ||
            ![[page objectForKey:@"url"] length] || ![size isKindOfClass:[NSNumber class]] || [size longLongValue] < 0 ||
            [size unsignedLongLongValue] > 20 * 1024 * 1024 || ![hash isKindOfClass:[NSString class]]) return nil;
    }
    return item;
}
- (NSArray *)entries {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *key in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_root error:NULL]) {
        NSDictionary *item = [self entry:key]; if (item) [items addObject:item];
    }
    return [items sortedArrayUsingDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:@"saved_at" ascending:NO]]];
}
- (BOOL)hasPage:(NSInteger)index entry:(NSDictionary *)item {
    NSArray *sizes = [item objectForKey:@"sizes"];
    if (index < 0 || index >= (NSInteger)[sizes count]) return NO;
    id size = [sizes objectAtIndex:index];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[self file:index entry:item] error:NULL];
    return [size isKindOfClass:[NSNumber class]] && [size unsignedLongLongValue] > 0 &&
        [[attributes fileType] isEqual:NSFileTypeRegular] && [attributes fileSize] == [size unsignedLongLongValue];
}
- (NSUInteger)count:(NSDictionary *)item {
    NSUInteger count = 0;
    for (NSInteger index = 0; index < (NSInteger)[[item objectForKey:@"pages"] count]; index++)
        if ([self hasPage:index entry:item]) count++;
    return count;
}
- (BOOL)complete:(NSDictionary *)item {
    return item && [[item objectForKey:@"complete"] boolValue] && [self count:item] == [[item objectForKey:@"pages"] count];
}
- (NSData *)page:(NSInteger)index entry:(NSDictionary *)item {
    if (![self hasPage:index entry:item] || [[[item objectForKey:@"sizes"] objectAtIndex:index] unsignedLongLongValue] > 20 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[self file:index entry:item]];
    return data && [ChapterDigest(data) isEqual:[[item objectForKey:@"hashes"] objectAtIndex:index]] ? data : nil;
}
- (NSMutableDictionary *)prepare:(NSDictionary *)manga chapter:(NSDictionary *)chapter pages:(NSArray *)pages {
    if (![pages count]) return nil;
    for (id page in pages) if (![page isKindOfClass:[NSDictionary class]] ||
        ![[page objectForKey:@"url"] isKindOfClass:[NSString class]] || ![[page objectForKey:@"url"] length]) return nil;
    manga = ChapterMetadata(manga); chapter = ChapterMetadata(chapter); pages = ChapterMetadata(pages);
    NSString *key = ChapterKey([manga objectForKey:@"slug_url"], chapter);
    NSMutableDictionary *item = [self entry:key];
    if ([[item objectForKey:@"pages"] isEqual:pages]) {
        // Repair a partial download before resuming, including same-size corruption.
        for (NSInteger i = 0; i < (NSInteger)[pages count]; i++) {
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            BOOL valid = [self page:i entry:item] != nil;
            [pool drain];
            if (!valid) {
                [[item objectForKey:@"sizes"] replaceObjectAtIndex:i withObject:[NSNumber numberWithInt:0]];
                [[item objectForKey:@"hashes"] replaceObjectAtIndex:i withObject:@""];
                [item setObject:[NSNumber numberWithBool:NO] forKey:@"complete"];
            }
        }
        return [self save:item] ? item : nil;
    }
    if (![self remove:key]) return nil;
    NSString *folder = [self folder:key];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    NSMutableArray *sizes = [NSMutableArray array], *hashes = [NSMutableArray array];
    for (NSUInteger i = 0; i < [pages count]; i++) { [sizes addObject:[NSNumber numberWithInt:0]]; [hashes addObject:@""]; }
    item = [NSMutableDictionary dictionaryWithObjectsAndKeys:key, @"id", manga, @"manga", chapter, @"chapter", pages, @"pages",
        sizes, @"sizes", hashes, @"hashes", [NSNumber numberWithBool:NO], @"complete", [NSNumber numberWithDouble:
        [[NSDate date] timeIntervalSince1970]], @"saved_at", nil];
    return [self save:item] ? item : nil;
}
- (BOOL)savePage:(NSData *)data index:(NSInteger)index entry:(NSMutableDictionary *)item {
    if (![data length] || [data length] > 20 * 1024 * 1024 || index < 0 || index >= (NSInteger)[[item objectForKey:@"pages"] count]) return NO;
    if (![data writeToFile:[self file:index entry:item] options:NSDataWritingAtomic error:NULL]) return NO;
    [[item objectForKey:@"sizes"] replaceObjectAtIndex:index withObject:[NSNumber numberWithUnsignedInteger:[data length]]];
    [[item objectForKey:@"hashes"] replaceObjectAtIndex:index withObject:ChapterDigest(data)];
    [item setObject:[NSNumber numberWithBool:NO] forKey:@"complete"];
    return [self save:item];
}
- (BOOL)finish:(NSMutableDictionary *)item {
    if (!item || ![[item objectForKey:@"pages"] count]) return NO;
    for (NSInteger index = 0; index < (NSInteger)[[item objectForKey:@"pages"] count]; index++) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        BOOL valid = [self page:index entry:item] != nil;
        [pool drain];
        if (!valid) return NO;
    }
    [item setObject:[NSNumber numberWithBool:YES] forKey:@"complete"];
    if ([self save:item]) return YES;
    [item setObject:[NSNumber numberWithBool:NO] forKey:@"complete"]; return NO;
}
- (BOOL)remove:(NSString *)key {
    NSString *folder = [self folder:key]; if (!folder) return NO;
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:folder]) return YES;
    // Chapter directories are flat. Remove their files before the directory;
    // this also works on runtimes whose removeItem only handles empty folders.
    NSArray *files = [manager contentsOfDirectoryAtPath:folder error:NULL];
    if (!files) return NO;
    for (NSString *name in files)
        if (![manager removeItemAtPath:[folder stringByAppendingPathComponent:name] error:NULL]) return NO;
    return [manager removeItemAtPath:folder error:NULL];
}
- (void)dealloc { [_root release]; [super dealloc]; }
@end
