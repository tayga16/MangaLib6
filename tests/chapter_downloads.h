// Included by reading_progress.m: disk persistence and the real offline reader.
@interface DownloadTestController : MangaLib6Controller
- (void)runDownloadChecks:(BOOL)verify;
- (void)waitForOfflinePage;
@end
@implementation DownloadTestController
- (void)refreshImageServers {}
- (void)waitForOfflinePage {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (_imageDecodeCount && [deadline timeIntervalSinceNow] > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(!_imageDecodeCount);
}
- (void)loadResumeCoverForSlug:(NSString *)slug progress:(NSDictionary *)progress {}
- (void)work:(NSDictionary *)task { assert(!"Offline reader attempted a network request"); }
- (void)startImageDownload:(NSDictionary *)task {
    assert([[_imageServers objectAtIndex:0] isKindOfClass:[NSDictionary class]]);
    assert(!_imageTask);
    _imageTask = [task copy];
}
- (void)runDownloadChecks:(BOOL)verify {
    [self loadView];
    [_downloads release];
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    _downloads = [[MangaLib6Downloads alloc] initWithRoot:[documents stringByAppendingPathComponent:@"DownloadTests"]];
    NSDictionary *manga = [NSDictionary dictionaryWithObjectsAndKeys:@"offline-test", @"slug_url", @"Offline Manga", @"name", nil];
    NSDictionary *first = [NSDictionary dictionaryWithObjectsAndKeys:@"1", @"volume", @"9.5", @"number", nil];
    NSDictionary *second = [NSDictionary dictionaryWithObjectsAndKeys:@"2", @"volume", @"10", @"number", nil];
    NSArray *pages = [NSArray arrayWithObjects:[NSDictionary dictionaryWithObject:@"/one.png" forKey:@"url"],
        [NSDictionary dictionaryWithObject:@"/two.png" forKey:@"url"], nil];
    NSString *key = ChapterKey(@"offline-test", first);
    NSData *png = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Icon" ofType:@"png"]];
    assert([png length]);
    if (!verify) {
        assert([_downloads remove:key]);
        assert([_downloads remove:ChapterKey(@"offline-test", second)]);
        NSMutableDictionary *entry = [_downloads prepare:manga chapter:first pages:pages];
        assert(entry && ![_downloads complete:entry]);
        assert([_downloads savePage:png index:0 entry:entry]);
        entry = [_downloads entry:key];
        assert([_downloads count:entry] == 1 && ![_downloads complete:entry]);
        assert(![_downloads finish:entry]);
        // Resume through the actual controller, using captured image responses.
        _imageServers = [[NSArray alloc] initWithObjects:[NSDictionary dictionary], nil];
        [self setItems:[NSArray arrayWithObjects:first, second, nil] screen:1];
        _mangaInfo = [manga copy]; _slug = [@"offline-test" copy];
        _chapter = [first copy]; _pages = [pages copy]; _screen = 2;
        [self setPageImage:[UIImage imageWithData:png]];
        [self setReaderFullscreen:YES];
        assert(_readerFullscreen && CGRectEqualToRect(_contentView.frame, self.view.bounds));
        assert(_previous.hidden && _next.hidden && _readerDownloadButton.hidden && !_readerInfo.hidden);
        [self toggleReaderFullscreen:nil];
        assert(!_readerFullscreen && !_readerDownloadButton.hidden && !_previous.hidden);
        assert(CGRectEqualToRect(_contentView.frame, _normalContentFrame) && _image.image);
        [self downloadCurrentChapter];
        assert(_downloading && [[_imageTask objectForKey:@"page_index"] integerValue] == 1);
        assert([[_downloadButton titleForState:UIControlStateNormal] isEqual:@"Загрузки"]);
        assert([[_readerDownloadButton titleForState:UIControlStateNormal] isEqual:@"Отмена скачивания"]);
        _imageData = [png mutableCopy];
        [self completeImageDownload:[UIImage imageWithData:png] error:nil];
        [self downloadNextPage];
        assert(!_downloading && [_downloads complete:[_downloads entry:key]]);
        // Cancelling a pending response cannot add a saved page.
        entry = [_downloads prepare:manga chapter:second pages:pages];
        [self downloadChapter:second manga:manga];
        NSUInteger generation = _downloadGeneration;
        [self pauseChapterDownload:nil];
        assert(!_downloading && _downloadGeneration != generation && !_imageTask);
        assert([_downloads count:[_downloads entry:ChapterKey(@"offline-test", second)]] == 0);
        // Resume repairs a corrupt file even when its byte length is unchanged.
        NSMutableData *bad = [png mutableCopy];
        ((unsigned char *)[bad mutableBytes])[0] ^= 1;
        NSString *path = [[documents stringByAppendingPathComponent:@"DownloadTests"] stringByAppendingPathComponent:
            [key stringByAppendingPathComponent:@"0.page"]];
        assert([bad writeToFile:path atomically:YES]); [bad release];
        assert(![_downloads page:0 entry:[_downloads entry:key]]);
        entry = [_downloads prepare:manga chapter:first pages:pages];
        assert(![_downloads hasPage:0 entry:entry] && [_downloads hasPage:1 entry:entry]);
        assert([_downloads savePage:png index:0 entry:entry] && [_downloads finish:entry]);
        entry = [_downloads prepare:manga chapter:second pages:pages];
        assert([_downloads savePage:png index:0 entry:entry] && [_downloads savePage:png index:1 entry:entry]);
        assert([_downloads finish:entry]);
        assert(![_downloads remove:@"../escape"]);
        assert(![_downloads prepare:manga chapter:first pages:[NSArray arrayWithObject:[NSDictionary dictionary]]]);
        // Nullable API fields must round-trip through the native plist store.
        NSMutableDictionary *nullable = [manga mutableCopy];
        [nullable setObject:[NSNull null] forKey:@"cover"];
        [nullable setObject:[NSArray arrayWithObject:[NSNull null]] forKey:@"authors"];
        NSDictionary *scratch = [NSDictionary dictionaryWithObjectsAndKeys:@"3", @"volume", @"1", @"number", nil];
        NSString *scratchKey = ChapterKey(@"offline-test", scratch);
        assert([_downloads remove:scratchKey]);
        entry = [_downloads prepare:nullable chapter:scratch pages:pages]; [nullable release];
        assert(entry && [_downloads entry:scratchKey]);
        assert(![[entry objectForKey:@"manga"] objectForKey:@"cover"]);
        assert([_downloads savePage:png index:0 entry:entry]);
        NSArray *changed = [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:@"/changed.png" forKey:@"url"]];
        entry = [_downloads prepare:manga chapter:scratch pages:changed];
        assert(entry && [_downloads count:entry] == 0 && [[entry objectForKey:@"pages"] count] == 1);
        assert([_downloads remove:scratchKey] && ![_downloads entry:scratchKey]);
    }
    [self showDownloads];
    assert(_screen == 4 && [_items count] == 2);
    [self openDownloaded:[_downloads entry:key] page:1];
    [self waitForOfflinePage];
    assert(_screen == 2 && _offlineChapter && _downloadsReader && _image.image && _pageIndex == 1);
    assert(_readerFullscreen == (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone));
    [self setReaderFullscreen:YES];
    assert(_readerFullscreen && _image.image && _pageIndex == 1 && !_readerInfo.hidden);
    [self toggleReaderFullscreen:nil];
    assert(!_readerFullscreen && _image.image && _pageIndex == 1 && !_readerDownloadButton.enabled);
    [_pageView setZoomScale:2 animated:NO];
    [self updatePageControls];
    assert(_pageView.zoomScale == 2);
    [self setReaderFullscreen:YES];
    assert([_status.text rangeOfString:@"Без интернета"].location != NSNotFound);
    assert([self nextChapter] && [[self nextChapter] isEqual:second]);
    [self nextPage];
    [self waitForOfflinePage];
    assert(_offlineChapter && _pageIndex == 0 && [_chapter isEqual:second] && _image.image);
    assert(_readerFullscreen && CGRectEqualToRect(_pageView.frame, self.view.bounds));
    [self goBack];
    assert(_screen == 4 && !_offlineChapter && !_readerFullscreen && _readerInfo.hidden);
    [self continueReading];
    [self waitForOfflinePage];
    assert(_screen == 2 && _offlineChapter && [_chapter isEqual:second]);
    if (!verify) {
        // Fast turns must finish on the latest page, with just one worker active.
        [self showPage];
        assert(_imageDecodeCount == 1 && !_image.image);
        [self nextPage];
        [self previousPage];
        assert(_imageDecodeCount == 1 && _pageIndex == 0);
        [self waitForOfflinePage];
        assert(_image.image && _pageIndex == 0);
        assert([[[self savedProgressForSlug:@"offline-test"] objectForKey:@"page_index"] integerValue] == 0);
        // Leaving during decoding cannot restore an image on the downloads screen.
        [self showPage];
        [self goBack];
        [self waitForOfflinePage];
        assert(_screen == 4 && !_offlineChapter && !_image.image);
        [self continueReading];
        [self waitForOfflinePage];
        assert(_screen == 2 && _offlineChapter && _image.image && _pageIndex == 0);
        puts("PASS: offline background decoding, rapid turns, cancellation on exit, saved latest position");
    }
    puts("PASS: fullscreen layout, controls toggle, download button, zoom, fullscreen next chapter and return");
    puts(verify ? "PASS: downloaded chapters survive relaunch and read offline" :
        "PASS: partial downloads, controller resume/cancel, corruption repair, offline reader, next chapter, saved position");
}
@end
