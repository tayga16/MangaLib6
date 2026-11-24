// Exercise real worker decoding and cancellation, with full-resolution scans.
@interface ReaderTestConnection : NSObject
- (void)cancel;
@end
@implementation ReaderTestConnection
- (void)cancel {}
@end

@interface ReaderResponsivenessController : MangaLib6Controller {
    NSUInteger _completedDecodes;
    BOOL _workerDecoded;
}
- (void)runReaderChecks;
@end
@implementation ReaderResponsivenessController
- (void)refreshImageServers {}
- (void)prefetchPages {}
- (void)decodePage:(NSDictionary *)task {
    _workerDecoded = ![NSThread isMainThread];
    [super decodePage:task];
}
- (void)finishDecodedPage:(NSDictionary *)result {
    [super finishDecodedPage:result];
    _completedDecodes++;
}
- (void)waitForDecode {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (_imageDecodeCount && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    assert(!_imageDecodeCount);
}
- (void)runReaderChecks {
    [self loadView];
    UIWindow *window = [[UIWindow alloc] initWithFrame:self.view.bounds];
    window.rootViewController = self;
    [window makeKeyAndVisible];
    _screen = 2;
    _live = YES;
    _pages = [[NSArray alloc] initWithObjects:[NSDictionary dictionaryWithObject:@"/one.png" forKey:@"url"],
        [NSDictionary dictionaryWithObject:@"/two.png" forKey:@"url"], nil];
    [self setReaderFullscreen:YES];
    _pageView.hidden = NO;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1970, 2800), YES, 1);
    [[UIColor whiteColor] setFill];
    UIRectFill(CGRectMake(0, 0, 1970, 2800));
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, 600, 2800));
    NSData *png = [UIImagePNGRepresentation(UIGraphicsGetImageFromCurrentImageContext()) retain];
    UIGraphicsEndImageContext();
    assert([png length]);
    _imageConnection = (NSURLConnection *)[[ReaderTestConnection alloc] init];
    _imageTask = [[NSDictionary alloc] initWithObjectsAndKeys:@"image", @"kind", @0, @"page_index",
        [NSNumber numberWithUnsignedInteger:_readerGeneration], @"generation", nil];
    _imageURLs = [[NSArray alloc] initWithObjects:@"https://images.example.test/one.png", nil];
    _imageData = [png mutableCopy];
    [self connectionDidFinishLoading:_imageConnection];
    assert(_imageDecodeCount == 1 && !_image.image);
    // Controls remain usable before the worker returns its image.
    [self toggleReaderFullscreen:nil];
    assert(!_readerFullscreen);
    [self waitForDecode];
    assert(_workerDecoded && _completedDecodes == 1 && _image.image && !_imageTask);
    assert(CGImageGetWidth(_image.image.CGImage) == 1970 && CGImageGetHeight(_image.image.CGImage) == 2800);
    assert([self savedProgressForSlug:@"not-displayed"] == nil);
    UIImage *large = [_image.image retain];
    [_pageCache setObject:large forKey:@1];
    [self nextPage];
    assert(_pageIndex == 1 && _image.image && _pageView.zoomScale == 1);
    assert(![_pageView.layer animationForKey:@"pageTransition"]);
    assert([_pageCache count] == (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone ? 1 : 2));
    [_pageView setZoomScale:2 animated:NO];
    assert(_pageView.zoomScale == 2);
    [self previousPage];
    assert(_pageIndex == 0 && _pageView.zoomScale == 1);
    [self displayPageImage:large cacheHit:NO];
    // A result already being decoded must not resurrect a cancelled reader.
    _imageConnection = (NSURLConnection *)[[ReaderTestConnection alloc] init];
    _imageTask = [[NSDictionary alloc] initWithObjectsAndKeys:@"image", @"kind", @1, @"page_index",
        [NSNumber numberWithUnsignedInteger:_readerGeneration], @"generation", nil];
    _imageURLs = [[NSArray alloc] initWithObjects:@"https://images.example.test/two.png", nil];
    _imageData = [png mutableCopy];
    [self connectionDidFinishLoading:_imageConnection];
    [self resetPageBuffer];
    [self waitForDecode];
    assert(_completedDecodes == 2 && !_image.image && ![_pageCache count] && !_imageTask);
    // Memory pressure must remain respected after subsequent page turns.
    [self displayPageImage:large cacheHit:NO];
    [self didReceiveMemoryWarning];
    assert(_lowMemory);
    [self nextPage];
    assert(_lowMemory && [self bufferEnd] - _pageIndex == 1);
    [self resetPageBuffer];
    assert(_lowMemory);
    [large release];
    [png release];
    window.hidden = YES;
    window.rootViewController = nil;
    [window release];
    puts("PASS: background full-resolution decode, usable controls, page turns, zoom, bounded buffer, stale result cancellation, persistent memory-pressure fallback");
}
@end
