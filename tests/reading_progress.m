// Run as a console entry point in an iOS app bundle with UIKit available.
#define main MangaLib6ApplicationMain
#import "../src/main.m"
#undef main
#include <assert.h>
#include <stdio.h>
#include <string.h>
#import "chapter_downloads.h"

@interface ProgressTestController : MangaLib6Controller {
    NSDictionary *_lastTask;
}
- (void)runChecks;
- (void)checkPersistedProgress;
- (void)runSearchHistoryChecks;
@end

@implementation ProgressTestController
- (void)start:(NSDictionary *)task {
    [_lastTask release];
    _lastTask = [task copy];
    _busy = YES;
}
- (void)prefetchPages {}
- (void)loadCover {}
- (void)refreshImageServers {}
- (void)checkPersistedProgress {
    _readingProgress = [[NSMutableDictionary alloc] initWithDictionary:
        [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MangaLib6ReadingProgress"]];
    NSDictionary *first = [self savedProgressForSlug:@"test-manga"];
    NSDictionary *second = [self savedProgressForSlug:@"another-manga"];
    assert(first && second);
    assert([[first objectForKey:@"number"] isEqual:@"9.5"]);
    assert([[first objectForKey:@"page_index"] integerValue] == 0);
    assert([[second objectForKey:@"page_index"] integerValue] == 0);
    assert([[self resumeSlug] isEqual:@"another-manga"]);
    [self loadView];
    assert(_showingSearchHistory && !_busy && !_lastTask);
    assert([_query.text isEqual:@""]);
    assert([_searchHistory count] == 2);
    assert([[_searchHistory objectAtIndex:0] isEqual:@"Наруто"]);
    assert([[_searchHistory objectAtIndex:1] isEqual:@"Bleach"]);
    puts("PASS: reading progress survives a separate application launch");
    puts("PASS: search history survives relaunch without an automatic search");
}
- (void)runChecks {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:SearchHistoryKey];
    ProgressTestController *startup = [[ProgressTestController alloc] init];
    [startup loadView];
    assert(startup->_showingSearchHistory && !startup->_busy && !startup->_lastTask);
    assert([startup->_query.text isEqual:@""]);
    assert(![startup->_searchHistory count]);
    assert([startup->_status.text rangeOfString:@"пока пуста"].location != NSNotFound);
    [startup release];
    self.view = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 768, 1024)] autorelease];
    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 768, 808)];
    _readingProgress = [[NSMutableDictionary alloc] init];
    _pageCache = [[NSMutableDictionary alloc] init];
    _pageErrors = [[NSMutableDictionary alloc] init];
    _image = [[UIImageView alloc] init];
    _pageView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, 768, 748)];
    _status = [[UILabel alloc] init];
    _table = [[UITableView alloc] initWithFrame:_contentView.bounds];
    _infoView = [[UIScrollView alloc] initWithFrame:_contentView.bounds];
    _cover = [[UIImageView alloc] init];
    _coverStatus = [[UILabel alloc] init];
    _query = [[UITextField alloc] init];
    _previous = [UIButton buttonWithType:UIButtonTypeCustom];
    _next = [UIButton buttonWithType:UIButtonTypeCustom];
    [self createResumePanel];
    _live = YES;
    _screen = 2;
    _slug = [@"test-manga" copy];
    _mangaInfo = [[NSDictionary alloc] initWithObjectsAndKeys:@"Test Manga", @"name", nil];
    // Fractional chapter numbers and volume boundaries must survive resume.
    NSDictionary *first = [NSDictionary dictionaryWithObjectsAndKeys:@"1", @"volume", @"9.5", @"number", nil];
    NSDictionary *second = [NSDictionary dictionaryWithObjectsAndKeys:@"2", @"volume", @"10", @"number", nil];
    _items = [[NSArray alloc] initWithObjects:first, second, nil];
    _chapters = [_items copy];
    _chapter = [first copy];
    NSDictionary *page = [NSDictionary dictionaryWithObject:@"/test.png" forKey:@"url"];
    _pages = [[NSArray alloc] initWithObjects:page, page, page, nil];
    _image.image = [UIImage imageNamed:@"Icon.png"];
    assert(_image.image);
    _pageIndex = 1;
    [self flushReadingProgress];
    NSDictionary *saved = [self savedProgressForSlug:_slug];
    assert([[saved objectForKey:@"page_index"] integerValue] == 1);
    assert([[saved objectForKey:@"number"] isEqual:@"9.5"]);
    assert([[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MangaLib6ReadingProgress"] objectForKey:_slug]);

    // Restore the property list, rather than relying on the in-memory objects.
    NSMutableDictionary *restored = [[NSMutableDictionary alloc] initWithDictionary:
        [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MangaLib6ReadingProgress"]];
    [_readingProgress release];
    _readingProgress = restored;
    assert([[self resumeSlug] isEqual:_slug]);
    _image.image = nil;
    _pageIndex = 2;
    [self flushReadingProgress];
    assert([[[self savedProgressForSlug:_slug] objectForKey:@"page_index"] integerValue] == 1);

    _screen = 1;
    [self updateResumeButton];
    assert(!_resumePanel.hidden);
    assert(_table.tableHeaderView == _resumePanel);
    assert([_resumeName.text isEqual:@"Test Manga"]);
    assert([_resumeDetails.text rangeOfString:@"Глава 9.5"].location != NSNotFound);
    assert(fabs(_resumeProgress.progress - 2.0 / 3) < 0.01);
    [self continueReading];
    assert([[_lastTask objectForKey:@"chapter"] isEqual:first]);
    assert([[_lastTask objectForKey:@"resume_page"] integerValue] == 1);
    _busy = NO;
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", @"Network error", @"error", nil]];
    assert([[[self savedProgressForSlug:_slug] objectForKey:@"page_index"] integerValue] == 1);

    // Clamp an old saved page when a chapter becomes shorter.
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", first, @"chapter",
        [NSArray arrayWithObject:page], @"value", [NSNumber numberWithInteger:8], @"resume_page", nil]];
    assert(_pageIndex == 0);
    assert([[[self savedProgressForSlug:_slug] objectForKey:@"page_index"] integerValue] == 1);
    [self displayPageImage:[UIImage imageNamed:@"Icon.png"] cacheHit:NO];
    assert([[[self savedProgressForSlug:_slug] objectForKey:@"page_index"] integerValue] == 0);
    assert([self nextChapter] == second);
    [self updatePageControls];
    assert(_next.enabled && !_previous.enabled);
    assert([_status.text rangeOfString:@"Прямой API: страница 1/1. Буфер: 0/1. Назад: 0"].location != NSNotFound);

    // Continue from search after relaunch, including failure of optional metadata.
    _screen = 0;
    [self continueReading];
    assert([[_lastTask objectForKey:@"kind"] isEqual:@"title"]);
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"title", @"kind", @"Metadata unavailable", @"error", nil]];
    assert([[_lastTask objectForKey:@"kind"] isEqual:@"chapters"]);
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"chapters", @"kind",
        [NSArray arrayWithObjects:first, second, nil], @"value", nil]];
    assert([[_lastTask objectForKey:@"chapter"] isEqual:first]);
    assert([[_lastTask objectForKey:@"resume_page"] integerValue] == 0);
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", first, @"chapter",
        [NSArray arrayWithObject:page], @"value", [NSNumber numberWithInteger:0], @"resume_page", nil]];
    [self displayPageImage:[UIImage imageNamed:@"Icon.png"] cacheHit:NO];

    // Saving another manga must not erase the first.
    [_slug release];
    _slug = [@"another-manga" copy];
    [self flushReadingProgress];
    assert([self savedProgressForSlug:@"test-manga"]);
    assert([self savedProgressForSlug:@"another-manga"]);
    _screen = 0;
    assert([[self resumeSlug] isEqual:@"another-manga"]);

    // Missing chapters leave saved progress intact and allow another selection.
    _screen = 1;
    [_items release];
    _items = [[NSArray alloc] initWithObjects:second, nil];
    [self resumeSavedChapter];
    assert(!_busy && !_resumeRequested);
    assert([self savedProgressForSlug:_slug]);
    assert([_status.text rangeOfString:@"недоступна"].location != NSNotFound);
    [_chapter release];
    _chapter = [second copy];
    _screen = 2;
    [self updatePageControls];
    assert(!_next.enabled && !_previous.enabled);

    // Inspect the actual animations attached to a visible layer.
    UIWindow *window = [[UIWindow alloc] initWithFrame:self.view.bounds];
    window.rootViewController = self;
    [self.view addSubview:_contentView];
    [_contentView addSubview:_pageView];
    [window makeKeyAndVisible];
    _screen = 0;
    [self animateNavigationToScreen:3];
    CATransition *transition = (CATransition *)[_contentView.layer animationForKey:@"navigation"];
    assert([transition.type isEqual:kCATransitionPush]);
    assert([transition.subtype isEqual:kCATransitionFromRight]);
    _screen = 2;
    [self animateNavigationToScreen:1];
    transition = (CATransition *)[_contentView.layer animationForKey:@"navigation"];
    assert([transition.subtype isEqual:kCATransitionFromLeft]);
    _image.image = [UIImage imageNamed:@"Icon.png"];
    _pageDirection = 1;
    [self transitionToPageImage:nil];
    transition = (CATransition *)[_pageView.layer animationForKey:@"pageTransition"];
    assert([transition.type isEqual:kCATransitionPush]);
    assert([transition.subtype isEqual:kCATransitionFromRight]);
    [_contentView.layer removeAnimationForKey:@"navigation"];
    _lowMemory = YES;
    [self animateNavigationToScreen:1];
    assert(![_contentView.layer animationForKey:@"navigation"]);
    window.hidden = YES;
    window.rootViewController = nil;
    [window release];
    puts("PASS: persisted progress, resume, failed loads, changed chapter size, multiple manga, next chapter");
    puts("PASS: forward/back animation direction, uncached page slide, low-memory fallback");
    puts("PASS: continue from search with unavailable metadata");
    [self runSearchHistoryChecks];
}

- (void)runSearchHistoryChecks {
    _screen = 0;
    [[NSUserDefaults standardUserDefaults] setObject:[NSArray arrayWithObjects:
        @" Chainsaw ", [NSNumber numberWithInt:7], @"chainsaw", @" \n ", @"Наруто", [NSDictionary dictionary], nil]
        forKey:SearchHistoryKey];
    [self loadSearchHistory];
    assert([_searchHistory count] == 2);
    assert([[_searchHistory objectAtIndex:0] isEqual:@"Chainsaw"]);
    assert([[_searchHistory objectAtIndex:1] isEqual:@"Наруто"]);
    [self rememberSearchQuery:@" \n "];
    assert([_searchHistory count] == 2);
    [self rememberSearchQuery:@" CHAINSAW "];
    assert([_searchHistory count] == 2);
    assert([[_searchHistory objectAtIndex:0] isEqual:@"CHAINSAW"]);
    for (NSUInteger index = 0; index < SearchHistoryLimit + 3; index++) {
        [self rememberSearchQuery:[NSString stringWithFormat:@"Manga %lu", (unsigned long)index]];
    }
    assert([_searchHistory count] == SearchHistoryLimit);
    assert([[_searchHistory lastObject] isEqual:@"Manga 3"]);
    [self showSearchHistory];
    [self clearSearchHistory];
    assert(![_searchHistory count]);
    assert(![[[NSUserDefaults standardUserDefaults] arrayForKey:SearchHistoryKey] count]);
    assert([self savedProgressForSlug:@"test-manga"] && [self savedProgressForSlug:@"another-manga"]);

    _query.text = @"  Наруто  ";
    [self search];
    assert(_busy && !_showingSearchHistory && _screen == 0);
    assert([_query.text isEqual:@"Наруто"]);
    assert([[_lastTask objectForKey:@"kind"] isEqual:@"catalog"]);
    assert([[_lastTask objectForKey:@"path"] rangeOfString:Escape(@"Наруто")].location != NSNotFound);
    assert([[_searchHistory objectAtIndex:0] isEqual:@"Наруто"]);
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"catalog", @"kind", @"Network error", @"error", nil]];
    assert([_searchHistory count] == 1);
    [self showSearchHistory];
    [self rememberSearchQuery:@"Bleach"];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:1 inSection:0];
    assert([self tableView:_table numberOfRowsInSection:0] == 2);
    assert([[[self tableView:_table cellForRowAtIndexPath:indexPath] textLabel].text isEqual:@"Наруто"]);
    [self tableView:_table didSelectRowAtIndexPath:indexPath];
    assert(_busy && !_showingSearchHistory);
    assert([_query.text isEqual:@"Наруто"]);
    assert([_searchHistory count] == 2 && [[_searchHistory objectAtIndex:0] isEqual:@"Наруто"]);
    NSDictionary *manga = [NSDictionary dictionaryWithObjectsAndKeys:@"test-manga", @"slug_url", @"Test Manga", @"name", nil];
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"catalog", @"kind", [NSArray arrayWithObject:manga], @"value", nil]];
    assert(!_showingSearchHistory && [self tableView:_table numberOfRowsInSection:0] == 1);
    assert(![self tableView:_table canEditRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]);
    assert([[[self tableView:_table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]] textLabel].text isEqual:@"Test Manga"]);

    _query.text = @" \n ";
    [_lastTask release];
    _lastTask = nil;
    [self search];
    assert(_showingSearchHistory && !_busy && !_lastTask);
    assert([_catalog count] == 1);
    assert(!_resumePanel.hidden && _table.tableHeaderView == _resumePanel);
    [self rememberSearchQuery:@"One Piece"];
    [self tableView:_table commitEditingStyle:UITableViewCellEditingStyleDelete
        forRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    assert([_searchHistory count] == 2 && ![_searchHistory containsObject:@"One Piece"]);
    [self loadSearchHistory];
    assert([_searchHistory count] == 2);
    assert([[_searchHistory objectAtIndex:0] isEqual:@"Наруто"]);
    puts("PASS: empty startup, query history, Unicode search, deduplication, limit, failed search, row replay, deletion, clearing");
}
- (void)dealloc {
    [_lastTask release];
    [super dealloc];
}
@end

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ProgressTestController *controller = [[ProgressTestController alloc] init];
    if (argc > 1 && strcmp(argv[1], "verify") == 0) {
        [controller checkPersistedProgress];
    } else {
        [controller runChecks];
    }
    NSDictionary *original = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MangaLib6ReadingProgress"] copy];
    DownloadTestController *downloads = [[DownloadTestController alloc] init];
    [downloads runDownloadChecks:argc > 1 && strcmp(argv[1], "verify") == 0];
    [downloads release];
    [[NSUserDefaults standardUserDefaults] setObject:original forKey:@"MangaLib6ReadingProgress"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [original release];
    [controller release];
    [pool drain];
    return 0;
}
