#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#import "ChapterDownloads.h"

static const NSInteger PageBufferSize = 5;
static const NSInteger PageHistorySize = 2;
static const NSInteger PageRetryLimit = 2;
static const NSUInteger SearchHistoryLimit = 20;
static NSString *const SearchHistoryKey = @"MangaLib6SearchHistory";
static const NSTimeInterval ImageRequestTimeout = 8;

// Decode at the original resolution on a worker, before handing an image to UIKit.
static UIImage *DecodePageImage(NSData *data) {
    UIImage *source = [UIImage imageWithData:data];
    CGImageRef original = source.CGImage;
    if (!original) return nil;
    size_t width = CGImageGetWidth(original), height = CGImageGetHeight(original);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return source;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), original);
    CGImageRef decoded = CGBitmapContextCreateImage(context);
    UIImage *image = decoded ? [UIImage imageWithCGImage:decoded scale:source.scale orientation:source.imageOrientation] : source;
    if (decoded) CGImageRelease(decoded);
    CGContextRelease(context);
    return image;
}

static unsigned long long PageImageBytes(UIImage *image) {
    CGImageRef original = image.CGImage;
    return original ? (unsigned long long)CGImageGetWidth(original) * CGImageGetHeight(original) * 4 : 0;
}

static UIColor *ThemeAccent(void) {
    return [UIColor colorWithRed:0.9 green:0.43 blue:0.12 alpha:1];
}

static UIColor *ThemeBackground(void) {
    return [UIColor colorWithRed:1 green:0.94 blue:0.87 alpha:1];
}

static UIColor *ThemeSurface(void) {
    return [UIColor colorWithRed:1 green:0.98 blue:0.94 alpha:1];
}

static UIColor *ThemeText(void) {
    return [UIColor colorWithRed:0.3 green:0.15 blue:0.07 alpha:1];
}

static UIColor *ThemeSecondaryText(void) {
    return [UIColor colorWithRed:0.52 green:0.28 blue:0.13 alpha:1];
}

static UIColor *ThemeBorder(void) {
    return [UIColor colorWithRed:0.88 green:0.68 blue:0.49 alpha:1];
}

static UIImage *ThemeBackgroundImage(UIColor *top, UIColor *bottom, UIColor *border) {
    CGRect bounds = CGRectMake(0, 0, 32, 36);
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, 0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds, 0.5, 0.5) cornerRadius:6];
    CGContextSaveGState(context);
    [outline addClip];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = [NSArray arrayWithObjects:(id)top.CGColor, (id)bottom.CGColor, nil];
    CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0), CGPointMake(0, 36), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(colorSpace);
    CGContextRestoreGState(context);
    [border setStroke];
    [outline stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image stretchableImageWithLeftCapWidth:16 topCapHeight:18];
}

static void ThemeButton(UIButton *button) {
    static UIImage *normal = nil;
    static UIImage *highlighted = nil;
    if (!normal) {
        normal = [ThemeBackgroundImage([UIColor colorWithRed:1 green:0.62 blue:0.28 alpha:1],
            ThemeAccent(), [UIColor colorWithRed:0.72 green:0.32 blue:0.08 alpha:1]) retain];
        highlighted = [ThemeBackgroundImage(ThemeAccent(),
            [UIColor colorWithRed:0.74 green:0.32 blue:0.08 alpha:1], ThemeSecondaryText()) retain];
    }
    [button setBackgroundImage:normal forState:UIControlStateNormal];
    [button setBackgroundImage:highlighted forState:UIControlStateHighlighted];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitleColor:ThemeBackground() forState:UIControlStateDisabled];
    [button setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.3] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    button.titleLabel.shadowOffset = CGSizeMake(0, -1);
}

static BOOL TransientNetworkError(NSError *error) {
    NSInteger code = [error code];
    return [[error domain] isEqual:NSURLErrorDomain] &&
        (code == NSURLErrorNotConnectedToInternet || code == NSURLErrorNetworkConnectionLost ||
         code == NSURLErrorTimedOut || code == NSURLErrorCannotConnectToHost || code == NSURLErrorCannotFindHost);
}

static NSString *Name(NSDictionary *item) {
    id value = [item objectForKey:@"rus_name"];
    if (![value isKindOfClass:[NSString class]] || ![value length]) {
        value = [item objectForKey:@"name"];
    }
    return [value isKindOfClass:[NSString class]] ? value : @"Без названия";
}

static NSString *Escape(NSString *value) {
    return [value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

static NSString *InfoText(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in [NSArray arrayWithObjects:@"label", @"rus_name", @"name", nil]) {
            NSString *text = InfoText([value objectForKey:key]);
            if ([text length]) {
                return text;
            }
        }
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (id entry in value) {
            NSString *text = InfoText(entry);
            if ([text length] && ![parts containsObject:text]) {
                [parts addObject:text];
            }
        }
        return [parts componentsJoinedByString:@", "];
    }
    return @"";
}

static NSString *ChapterPublicationDate(NSDictionary *chapter) {
    NSDictionary *publication = chapter;
    id branches = [chapter objectForKey:@"branches"];
    if ([branches isKindOfClass:[NSArray class]] && [branches count] &&
        [[branches objectAtIndex:0] isKindOfClass:[NSDictionary class]]) {
        publication = [branches objectAtIndex:0];
    }
    NSString *timestamp = InfoText([publication objectForKey:@"created_at"]);
    if ([timestamp length] < 10) {
        return @"";
    }
    static NSDateFormatter *parser = nil;
    static NSDateFormatter *formatter = nil;
    if (!parser) {
        NSLocale *locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
        parser = [[NSDateFormatter alloc] init];
        parser.locale = locale;
        parser.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        parser.dateFormat = @"yyyy-MM-dd";
        parser.lenient = NO;
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = locale;
        formatter.timeZone = parser.timeZone;
        formatter.dateFormat = @"dd.MM.yyyy";
    }
    NSString *day = [timestamp substringToIndex:10];
    NSDate *date = [parser dateFromString:day];
    return date && [[parser stringFromDate:date] isEqual:day] ? [formatter stringFromDate:date] : @"";
}

static NSData *Download(NSString *url, NSError **error) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    [request setValue:@"1" forHTTPHeaderField:@"Site-Id"];
    [request setValue:@"https://mangalib.me/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"https://mangalib.me" forHTTPHeaderField:@"Origin"];
    [request setValue:@"application/json, image/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    NSURLResponse *response = nil;
    NSData *data = nil;
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        *error = nil;
        response = nil;
        data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:error];
        NSError *failure = *error;
        if (!TransientNetworkError(failure) || attempt == 1) {
            break;
        }
        NSLog(@"MangaLib6 network retry %ld: %@ (%@)", (long)attempt + 1, url, [failure localizedDescription]);
        [NSThread sleepForTimeInterval:0.6 * (attempt + 1)];
    }
    if (*error) {
        return nil;
    }
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    NSLog(@"MangaLib6 HTTP %ld %@ (%lu bytes)", (long)status, url, (unsigned long)[data length]);
    if (status < 200 || status >= 300) {
        NSString *message = status ? [NSString stringWithFormat:@"HTTP %ld: доступ ограничен или API изменился", (long)status] :
            @"Нет HTTP-ответа. HyperHLE может не поддерживать сеть.";
        *error = [NSError errorWithDomain:@"MangaLib6" code:status userInfo:
            [NSDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey]];
        return nil;
    }
    return data;
}

static id Fetch(NSString *path, NSError **error) {
    NSData *data = Download([@"https://api.cdnlibs.org/api" stringByAppendingString:path], error);
    if (!data) {
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"data"] : nil;
}

@interface MangaLib6ProgressBar : UIView {
    CGFloat _progress;
}
@property(nonatomic) CGFloat progress;
@end

@implementation MangaLib6ProgressBar
@synthesize progress = _progress;
- (void)setProgress:(CGFloat)progress {
    _progress = MAX((CGFloat)0, MIN((CGFloat)1, progress));
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithRed:56.0 / 255 green:56.0 / 255 blue:61.0 / 255 alpha:1] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:3] fill];
    if (_progress > 0) {
        [[UIColor colorWithRed:1 green:171.0 / 255 blue:64.0 / 255 alpha:1] setFill];
        CGRect fill = self.bounds;
        fill.size.width *= _progress;
        [[UIBezierPath bezierPathWithRoundedRect:fill cornerRadius:3] fill];
    }
}
@end

@interface MangaLib6Controller : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate, NSURLConnectionDataDelegate> {
    UITextField *_query;
    UILabel *_status;
    UIButton *_previous;
    UIButton *_next;
    UIButton *_resume;
    UIView *_resumePanel;
    UILabel *_resumeName;
    UILabel *_resumeDetails;
    UIImageView *_resumeCover;
    MangaLib6ProgressBar *_resumeProgress;
    NSURLConnection *_resumeConnection;
    NSMutableData *_resumeData;
    NSString *_resumeCoverSlug;
    UIView *_contentView;
    UITableView *_table;
    UIScrollView *_infoView;
    UIImageView *_cover;
    UILabel *_coverStatus;
    NSURLConnection *_coverConnection;
    NSMutableData *_coverData;
    NSDictionary *_mangaInfo;
    NSArray *_catalog;
    NSArray *_chapters;
    NSDictionary *_chapter;
    NSMutableDictionary *_readingProgress;
    NSMutableArray *_searchHistory;
    BOOL _showingSearchHistory;
    BOOL _resumeRequested;
    BOOL _titleLoaded;
    UIScrollView *_pageView;
    UIImageView *_image;
    NSDictionary *_snapshot;
    NSArray *_items;
    NSArray *_pages;
    NSMutableDictionary *_pageCache;
    NSMutableDictionary *_pageErrors;
    NSArray *_imageServers;
    NSURLConnection *_imageConnection;
    NSMutableData *_imageData;
    NSDictionary *_imageTask;
    NSArray *_imageURLs;
    NSString *_preferredImageServer;
    NSUInteger _imageServerIndex;
    BOOL _imageRetryable;
    NSUInteger _imageDecodeGeneration;
    NSUInteger _imageDecodeCount;
    unsigned long long _pageImageEstimate;
    BOOL _serversLoading;
    NSString *_slug;
    NSInteger _screen;
    NSInteger _pageIndex;
    NSInteger _pageDirection;
    NSUInteger _readerGeneration;
    BOOL _live;
    BOOL _busy;
    BOOL _lowMemory;
    BOOL _smoke;
    MangaLib6Downloads *_downloads;
    NSDictionary *_offlineChapter;
    NSMutableDictionary *_downloadEntry;
    NSDictionary *_downloadManga;
    UIButton *_downloadButton;
    UIButton *_readerDownloadButton;
    UIButton *_cancelDownloadButton;
    UILabel *_readerInfo;
    CGRect _normalContentFrame;
    BOOL _readerFullscreen;
    NSUInteger _downloadGeneration;
    BOOL _downloading;
    BOOL _downloadPreparing;
    BOOL _downloadsReader;
}
- (void)showDownloads;
- (void)openDownloaded:(NSDictionary *)entry page:(NSInteger)page;
- (void)downloadChapter:(NSDictionary *)chapter manga:(NSDictionary *)manga;
- (void)downloadNextPage;
- (void)stopChapterDownload;
- (void)setReaderFullscreen:(BOOL)enabled;
- (void)updateDownloadControls;
- (void)updateReaderInfo;
- (void)decodePage:(NSDictionary *)task;
- (void)finishDecodedPage:(NSDictionary *)result;
- (void)startOfflinePageDecode;
@end

@implementation MangaLib6Controller
- (UIButton *)button:(NSString *)title action:(SEL)action frame:(CGRect)frame {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    ThemeButton(button);
    button.frame = frame;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (void)loadView {
    NSString *documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    _downloads = [[MangaLib6Downloads alloc] initWithRoot:[documents stringByAppendingPathComponent:@"Chapters"]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pauseChapterDownload:)
        name:UIApplicationWillResignActiveNotification object:nil];
    _pageCache = [[NSMutableDictionary alloc] init];
    _pageErrors = [[NSMutableDictionary alloc] init];
    id progress = [[NSUserDefaults standardUserDefaults] objectForKey:@"MangaLib6ReadingProgress"];
    _readingProgress = [progress isKindOfClass:[NSDictionary class]] ?
        [[NSMutableDictionary alloc] initWithDictionary:progress] : [[NSMutableDictionary alloc] init];
    [self loadSearchHistory];
    id savedServers = [[NSUserDefaults standardUserDefaults] objectForKey:@"MangaLib6ImageServers"];
    if ([savedServers isKindOfClass:[NSArray class]]) {
        _imageServers = [savedServers copy];
    }
    id preferredServer = [[NSUserDefaults standardUserDefaults] objectForKey:@"MangaLib6PreferredImageServer"];
    if ([preferredServer isKindOfClass:[NSString class]]) {
        _preferredImageServer = [preferredServer copy];
    }
    self.view = [[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.view.backgroundColor = ThemeBackground();
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat headerHeight = 44;
    CGFloat contentTop = headerHeight + 172;
    UINavigationBar *header = [[[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, width, headerHeight)] autorelease];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    header.tintColor = ThemeAccent();
    UINavigationItem *headerItem = [[[UINavigationItem alloc] initWithTitle:@"MangaLib6"] autorelease];
    UIView *brand = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 186, 32)] autorelease];
    UIImageView *brandIcon = [[[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Icon-Small.png"]] autorelease];
    brandIcon.frame = CGRectMake(0, 0, 32, 32);
    brandIcon.contentMode = UIViewContentModeScaleAspectFit;
    [brand addSubview:brandIcon];
    UILabel *brandTitle = [[[UILabel alloc] initWithFrame:CGRectMake(40, 0, 146, 32)] autorelease];
    brandTitle.text = @"MangaLib6";
    brandTitle.font = [UIFont boldSystemFontOfSize:21];
    brandTitle.backgroundColor = [UIColor clearColor];
    brandTitle.textColor = [UIColor whiteColor];
    brandTitle.shadowColor = [UIColor colorWithWhite:0 alpha:0.4];
    brandTitle.shadowOffset = CGSizeMake(0, -1);
    [brand addSubview:brandTitle];
    headerItem.titleView = brand;
    [header setItems:[NSArray arrayWithObject:headerItem] animated:NO];
    [self.view addSubview:header];
    _query = [[UITextField alloc] initWithFrame:CGRectMake(12, headerHeight + 12, width - 124, 36)];
    _query.borderStyle = UITextBorderStyleNone;
    _query.background = ThemeBackgroundImage(ThemeSurface(), ThemeBackground(), ThemeBorder());
    _query.textColor = ThemeText();
    _query.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _query.leftView = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 36)] autorelease];
    _query.leftViewMode = UITextFieldViewModeAlways;
    _query.text = @"";
    _query.placeholder = @"Поиск манги";
    _query.clearButtonMode = UITextFieldViewModeWhileEditing;
    _query.autocorrectionType = UITextAutocorrectionTypeNo;
    _query.delegate = self;
    _query.returnKeyType = UIReturnKeySearch;
    [self.view addSubview:_query];
    [self button:@"Поиск" action:@selector(search) frame:CGRectMake(width - 104, headerHeight + 12, 92, 36)];
    [self button:@"Назад" action:@selector(goBack) frame:CGRectMake(12, headerHeight + 56, 80, 36)];
    [self button:@"История" action:@selector(showSearchHistory) frame:CGRectMake(104, headerHeight + 56, 100, 36)];
    _downloadButton = [self button:@"Загрузки" action:@selector(downloadsButton) frame:CGRectMake(width - 104, headerHeight + 56, 92, 36)];
    _cancelDownloadButton = [self button:@"Отмена" action:@selector(cancelChapterDownload) frame:CGRectMake(width - 104, headerHeight + 112, 92, 36)];
    _cancelDownloadButton.hidden = YES;
    _status = [[UILabel alloc] initWithFrame:CGRectMake(12, headerHeight + 100, width - 24, 64)];
    _status.numberOfLines = 3;
    _status.font = [UIFont systemFontOfSize:15];
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = ThemeSecondaryText();
    [self.view addSubview:_status];
    _contentView = [[UIView alloc] initWithFrame:CGRectMake(0, contentTop, width, height - contentTop)];
    _normalContentFrame = _contentView.frame;
    _contentView.clipsToBounds = YES;
    [self.view addSubview:_contentView];
    _table = [[UITableView alloc] initWithFrame:_contentView.bounds style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = ThemeSurface();
    _table.separatorColor = ThemeBorder();
    [_contentView addSubview:_table];
    _infoView = [[UIScrollView alloc] initWithFrame:_table.frame];
    _infoView.backgroundColor = ThemeBackground();
    _infoView.hidden = YES;
    [_contentView addSubview:_infoView];
    [self createResumePanel];
    _cover = [[UIImageView alloc] initWithFrame:CGRectMake((width - 160) / 2, 12, 160, 224)];
    _cover.contentMode = UIViewContentModeScaleAspectFit;
    _cover.backgroundColor = ThemeSurface();
    [_infoView addSubview:_cover];
    _coverStatus = [[UILabel alloc] initWithFrame:_cover.frame];
    _coverStatus.backgroundColor = [UIColor clearColor];
    _coverStatus.textColor = ThemeSecondaryText();
    _coverStatus.textAlignment = UITextAlignmentCenter;
    _coverStatus.font = [UIFont systemFontOfSize:14];
    _coverStatus.numberOfLines = 0;
    [_infoView addSubview:_coverStatus];
    _pageView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, width, height - contentTop - 60)];
    _pageView.delegate = self;
    _pageView.backgroundColor = [UIColor colorWithRed:0.15 green:0.08 blue:0.04 alpha:1];
    _pageView.minimumZoomScale = 1;
    _pageView.maximumZoomScale = 4;
    _pageView.hidden = YES;
    [_contentView addSubview:_pageView];
    _image = [[UIImageView alloc] initWithFrame:_pageView.bounds];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    [_pageView addSubview:_image];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomPage:)];
    doubleTap.numberOfTapsRequired = 2;
    [_pageView addGestureRecognizer:doubleTap];
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleReaderFullscreen:)];
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [_pageView addGestureRecognizer:singleTap];
    [singleTap release];
    [doubleTap release];
    UIPanGestureRecognizer *pageSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(swipePage:)];
    pageSwipe.maximumNumberOfTouches = 1;
    pageSwipe.delegate = self;
    [_pageView addGestureRecognizer:pageSwipe];
    [pageSwipe release];
    _previous = [self button:@"< Страница" action:@selector(previousPage) frame:CGRectMake(12, height - 48, 140, 36)];
    _next = [self button:@"Страница >" action:@selector(nextPage) frame:CGRectMake(width - 152, height - 48, 140, 36)];
    _next.titleLabel.adjustsFontSizeToFitWidth = YES;
    _readerDownloadButton = [self button:@"Скачать главу" action:@selector(downloadCurrentChapter) frame:CGRectMake(12, height - 92, width - 24, 36)];
    _readerDownloadButton.hidden = YES;
    _readerInfo = [[UILabel alloc] initWithFrame:CGRectMake(0, height - 42, width, 42)];
    _readerInfo.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    _readerInfo.textColor = [UIColor whiteColor];
    _readerInfo.font = [UIFont systemFontOfSize:11];
    _readerInfo.textAlignment = UITextAlignmentCenter;
    _readerInfo.numberOfLines = 2;
    _readerInfo.hidden = YES;
    [self.view addSubview:_readerInfo];
    NSString *path = [[NSBundle mainBundle] pathForResource:@"snapshot" ofType:@"plist"];
    id snapshot = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([snapshot isKindOfClass:[NSDictionary class]]) {
        _snapshot = [snapshot retain];
        NSLog(@"MangaLib6 snapshot loaded: %@", [_snapshot objectForKey:@"captured_at"]);
    } else {
        NSLog(@"MangaLib6 no snapshot");
    }
    BOOL smokeTest = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"MangaLib6SmokeTest"] boolValue];
    _live = !smokeTest;
    if (smokeTest) {
        _query.text = InfoText([_snapshot objectForKey:@"query"]);
        [self search];
    } else {
        [self showSearchHistory];
    }
    if (_live) {
        [self refreshImageServers];
    }
    if (smokeTest) {
        [self performSelector:@selector(smokeTest) withObject:nil afterDelay:0.5];
    }
}

- (void)centerPage {
    CGSize viewport = _pageView.bounds.size;
    CGSize content = _pageView.contentSize;
    _image.center = CGPointMake(MAX(viewport.width, content.width) / 2,
        MAX(viewport.height, content.height) / 2);
}

- (void)setReaderFullscreen:(BOOL)enabled {
    _readerFullscreen = enabled && _screen == 2;
    if (CGRectIsEmpty(_normalContentFrame)) _normalContentFrame = _contentView.frame;
    for (UIView *view in [self.view subviews]) {
        if (view != _contentView && view != _previous && view != _next &&
            view != _readerDownloadButton && view != _readerInfo && view != _cancelDownloadButton) {
            view.hidden = _readerFullscreen;
        }
    }
    _contentView.frame = _readerFullscreen ? self.view.bounds : _normalContentFrame;
    _table.frame = _contentView.bounds;
    _infoView.frame = _contentView.bounds;
    CGRect pageFrame = _contentView.bounds;
    if (!_readerFullscreen) pageFrame.size.height = MAX((CGFloat)0, pageFrame.size.height - 104);
    BOOL resizeImage = !CGRectEqualToRect(_pageView.frame, pageFrame);
    _pageView.frame = pageFrame;
    _previous.hidden = _next.hidden = _screen != 2 || _readerFullscreen;
    _readerDownloadButton.hidden = _screen != 2 || _readerFullscreen;
    _readerInfo.hidden = !_readerFullscreen;
    _readerInfo.frame = CGRectMake(0, self.view.bounds.size.height - 42, self.view.bounds.size.width, 42);
    [self updateDownloadControls];
    [self updateReaderInfo];
    if (resizeImage && _image.image) [self setPageImage:_image.image];
}

- (void)toggleReaderFullscreen:(UITapGestureRecognizer *)gesture {
    if (_screen == 2) [self setReaderFullscreen:!_readerFullscreen];
}

- (void)updateReaderInfo {
    if (_screen != 2) return;
    NSInteger forward = 0, history = 0;
    for (NSNumber *page in _pageCache) {
        if ([page integerValue] >= _pageIndex) forward++; else history++;
    }
    NSDictionary *error = [_pageErrors objectForKey:[NSNumber numberWithInteger:_pageIndex]];
    NSString *details = _downloading ? _status.text : _offlineChapter ? (_image.image ? @"Без интернета" : _status.text) : error ?
        [error objectForKey:@"message"] :
        [NSString stringWithFormat:@"Буфер: %ld/%ld · Назад: %ld%@", (long)forward,
            (long)([self bufferEnd] - _pageIndex), (long)history, _image.image ? @"" : @" · Загрузка…"];
    _readerInfo.text = [NSString stringWithFormat:@"Страница %ld/%lu · Осталось: %ld\n%@",
        (long)_pageIndex + 1, (unsigned long)[_pages count], MAX((long)0, (long)[_pages count] - _pageIndex - 1), details];
}

- (void)animateAppearance:(UIView *)view {
    if (_smoke || _lowMemory || !view.window || view.hidden) {
        return;
    }
    CATransition *transition = [CATransition animation];
    transition.type = kCATransitionFade;
    transition.duration = 0.18;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [view.layer addAnimation:transition forKey:@"appearance"];
}

- (void)animateContentInDirection:(NSInteger)direction {
    if (_smoke || _lowMemory || !_contentView.window) {
        return;
    }
    CATransition *transition = [CATransition animation];
    transition.type = kCATransitionPush;
    transition.subtype = direction > 0 ? kCATransitionFromRight : kCATransitionFromLeft;
    transition.duration = 0.3;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_contentView.layer addAnimation:transition forKey:@"navigation"];
}

- (void)animateNavigationToScreen:(NSInteger)screen {
    if (_screen == screen) {
        return;
    }
    // Search -> information -> chapters -> reader.
    NSInteger currentDepth = _screen == 3 ? 1 : (_screen == 1 ? 2 : (_screen == 2 ? 3 : 0));
    NSInteger nextDepth = screen == 3 ? 1 : (screen == 1 ? 2 : (screen == 2 ? 3 : 0));
    [self animateContentInDirection:nextDepth > currentDepth ? 1 : -1];
}

- (void)setPageImage:(UIImage *)image {
    [_image.layer removeAnimationForKey:@"pageTransition"];
    [_pageView.layer removeAnimationForKey:@"pageTransition"];
    [_pageView setZoomScale:1 animated:NO];
    _image.image = image;
    CGSize viewport = _pageView.bounds.size;
    CGSize fitted = viewport;
    if (image && image.size.width > 0 && image.size.height > 0) {
        CGFloat scale = MIN(viewport.width / image.size.width, viewport.height / image.size.height);
        fitted = CGSizeMake(image.size.width * scale, image.size.height * scale);
    }
    _image.frame = CGRectMake(0, 0, fitted.width, fitted.height);
    _pageView.contentSize = fitted;
    _pageView.contentOffset = CGPointZero;
    _pageView.maximumZoomScale = image ? 4 : 1;
    _pageView.scrollEnabled = image != nil;
    [self centerPage];
}

- (void)transitionToPageImage:(UIImage *)image {
    BOOL slide = _pageDirection != 0;
    BOOL animate = image && image != _image.image && !_smoke && !_lowMemory && _pageView.window;
    [self setPageImage:image];
    if (animate) {
        // Animate only the image: a transition on the scroll view snapshots the
        // entire zoomable reader, which is expensive on emulated iPhone 4 iOS.
        CABasicAnimation *transition = [CABasicAnimation animationWithKeyPath:slide ? @"position.x" : @"opacity"];
        CGFloat position = _image.layer.position.x;
        transition.fromValue = [NSNumber numberWithFloat:slide ? position + (_pageDirection > 0 ? 1 : -1) * _pageView.bounds.size.width : 0];
        transition.toValue = [NSNumber numberWithFloat:slide ? position : 1];
        transition.duration = slide ? 0.3 : 0.18;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_image.layer addAnimation:transition forKey:@"pageTransition"];
    }
    if (image) _pageDirection = 0;
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return scrollView == _pageView && _image.image ? _image : nil;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView == _pageView) {
        [self centerPage];
    }
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    if (scrollView == _pageView) {
        NSLog(@"MangaLib6 zoom page %ld: scale=%.2f", (long)_pageIndex + 1, scale);
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == _pageView) {
        NSLog(@"MangaLib6 pan page %ld: offset=%.1f,%.1f", (long)_pageIndex + 1,
            scrollView.contentOffset.x, scrollView.contentOffset.y);
    }
}

- (void)zoomPage:(UITapGestureRecognizer *)gesture {
    if (!_image.image) {
        return;
    }
    if (_pageView.zoomScale > _pageView.minimumZoomScale + 0.01) {
        [_pageView setZoomScale:_pageView.minimumZoomScale animated:YES];
        return;
    }
    CGFloat scale = MIN((CGFloat)2.5, _pageView.maximumZoomScale);
    CGPoint point = [gesture locationInView:_image];
    CGSize size = CGSizeMake(_pageView.bounds.size.width / scale, _pageView.bounds.size.height / scale);
    [_pageView zoomToRect:CGRectMake(point.x - size.width / 2, point.y - size.height / 2,
        size.width, size.height) animated:YES];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (![gesture isKindOfClass:[UIPanGestureRecognizer class]]) {
        return YES;
    }
    if (_screen != 2 || _busy || _pageView.hidden ||
        _pageView.zoomScale > _pageView.minimumZoomScale + 0.01) {
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGesture {
    return gesture == _pageView.panGestureRecognizer || otherGesture == _pageView.panGestureRecognizer;
}

- (void)swipePage:(UIPanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || ![self gestureRecognizerShouldBegin:gesture]) {
        return;
    }
    CGPoint distance = [gesture translationInView:_pageView];
    NSLog(@"MangaLib6 swipe distance: %.1f,%.1f", distance.x, distance.y);
    if (fabs(distance.x) < 80 || fabs(distance.x) < fabs(distance.y) * 1.5) {
        return;
    }
    BOOL forward = distance.x < 0;
    if (forward && _pageIndex + 1 >= (NSInteger)[_pages count]) {
        [self nextPage];
        return;
    }
    if (!forward && _pageIndex == 0) {
        return;
    }
    NSLog(@"MangaLib6 swipe %@ page %ld -> %ld (scale=%.2f)", forward ? @"left" : @"right",
        (long)_pageIndex + 1, (long)_pageIndex + (forward ? 2 : 0), _pageView.zoomScale);
    if (forward) {
        [self nextPage];
    } else {
        [self previousPage];
    }
}

- (void)smokeTest {
    _smoke = YES;
    NSLog(@"MangaLib6 smoke catalog: %lu titles", (unsigned long)[_items count]);
    [self setItems:[_snapshot objectForKey:@"chapters"] screen:1];
    NSLog(@"MangaLib6 smoke chapters: %lu", (unsigned long)[_items count]);
    [_pages release];
    _pages = [[[_snapshot objectForKey:@"chapter"] objectForKey:@"pages"] copy];
    for (_pageIndex = 0; _pageIndex < (NSInteger)[_pages count]; _pageIndex++) {
        [self showPage];
    }
    _pageIndex = 0;
    _live = YES;
    [self search];
    [self refreshImageServers];
}

- (void)setItems:(NSArray *)items screen:(NSInteger)screen {
    [self stopChapterDownload];
    [self animateNavigationToScreen:screen];
    [self resetPageBuffer];
    [self cancelCoverDownload];
    NSArray *replacement = [items copy];
    [_items release];
    _items = replacement;
    [_chapter release];
    _chapter = nil;
    _screen = screen;
    [self setReaderFullscreen:NO];
    _showingSearchHistory = NO;
    [_offlineChapter release]; _offlineChapter = nil;
    _downloadsReader = NO;
    if (screen == 0) {
        [_catalog release];
        _catalog = [_items copy];
        [_mangaInfo release];
        _mangaInfo = nil;
        [_chapters release];
        _chapters = nil;
        _cover.image = nil;
        _titleLoaded = NO;
        _resumeRequested = NO;
    }
    _table.hidden = NO;
    _infoView.hidden = YES;
    _pageView.hidden = YES;
    [self setPageImage:nil];
    _previous.hidden = YES;
    _next.hidden = YES;
    [_table reloadData];
    [self updateResumeButton];
}

- (CGFloat)infoLabel:(NSString *)text font:(UIFont *)font top:(CGFloat)top left:(CGFloat)left width:(CGFloat)width {
    CGFloat height = ceil([text sizeWithFont:font constrainedToSize:CGSizeMake(width, CGFLOAT_MAX)
        lineBreakMode:UILineBreakModeWordWrap].height);
    UILabel *label = [[[UILabel alloc] initWithFrame:CGRectMake(left, top, width, MAX(height, font.lineHeight))] autorelease];
    label.backgroundColor = [UIColor clearColor];
    label.textColor = ThemeText();
    label.font = font;
    label.numberOfLines = 0;
    label.text = text;
    [_infoView addSubview:label];
    return label.frame.size.height;
}

- (void)showInformation {
    [self animateNavigationToScreen:3];
    _table.tableHeaderView = nil;
    [self resetPageBuffer];
    _screen = 3;
    [self setReaderFullscreen:NO];
    _table.hidden = YES;
    _pageView.hidden = YES;
    _previous.hidden = YES;
    _next.hidden = YES;
    _infoView.hidden = NO;
    for (UIView *view in [_infoView subviews]) {
        if (view != _cover && view != _coverStatus) {
            [view removeFromSuperview];
        }
    }
    CGFloat width = _infoView.bounds.size.width;
    CGFloat top = 252;
    top += [self infoLabel:Name(_mangaInfo) font:[UIFont boldSystemFontOfSize:20] top:top left:20 width:width - 40] + 12;
    NSDictionary *progress = [self savedProgressForSlug:_slug];
    if (progress) {
        _resumePanel.frame = CGRectMake(20, top, width - 40, 160);
        [_infoView addSubview:_resumePanel];
        top += 172;
        NSInteger page = [[progress objectForKey:@"page_index"] integerValue];
        NSInteger count = [[progress objectForKey:@"page_count"] integerValue];
        NSString *summary = [NSString stringWithFormat:@"Место чтения: том %@, глава %@\nСтраница %ld из %ld. После неё осталось %ld стр. в главе.",
            [progress objectForKey:@"volume"], [progress objectForKey:@"number"],
            (long)page + 1, (long)count, (long)MAX((NSInteger)0, count - page - 1)];
        top += [self infoLabel:summary font:[UIFont systemFontOfSize:15] top:top left:20 width:width - 40] + 12;
    }
    UIButton *chapters = [UIButton buttonWithType:UIButtonTypeCustom];
    ThemeButton(chapters);
    chapters.frame = CGRectMake(20, top, width - 40, 40);
    [chapters setTitle:@"Открыть главы" forState:UIControlStateNormal];
    [chapters addTarget:self action:@selector(openChapters) forControlEvents:UIControlEventTouchUpInside];
    [_infoView addSubview:chapters];
    top += 56;
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *key in [NSArray arrayWithObjects:@"name", @"eng_name", @"otherNames", @"other_names", nil]) {
        id value = [_mangaInfo objectForKey:key];
        NSArray *entries = [value isKindOfClass:[NSArray class]] ? value : [NSArray arrayWithObject:(value ? value : @"")];
        for (id entry in entries) {
            NSString *name = InfoText(entry);
            if ([name length] && ![name isEqual:Name(_mangaInfo)] && ![names containsObject:name]) {
                [names addObject:name];
            }
        }
    }
    id count = nil;
    id counts = [_mangaInfo objectForKey:@"items_count"];
    if ([counts isKindOfClass:[NSDictionary class]]) {
        count = [counts objectForKey:@"uploaded"];
    }
    if (!count || count == [NSNull null]) {
        count = [_mangaInfo objectForKey:@"chapter_count"];
    }
    if (!_live) {
        count = [_snapshot objectForKey:@"total_chapters"];
    } else if (_chapters) {
        count = [NSNumber numberWithUnsignedInteger:[_chapters count]];
    }
    NSString *year = InfoText([_mangaInfo objectForKey:@"releaseDate"]);
    if (![year length]) {
        year = InfoText([_mangaInfo objectForKey:@"releaseDateString"]);
    }
    NSArray *labels = [NSArray arrayWithObjects:@"Год", @"Формат", @"Тип", @"Глав на сайте", @"Статус", @"Автор", @"Издатель", @"Другие названия", nil];
    NSArray *values = [NSArray arrayWithObjects:year, InfoText([_mangaInfo objectForKey:@"format"]),
        InfoText([_mangaInfo objectForKey:@"type"]), InfoText(count), InfoText([_mangaInfo objectForKey:@"status"]),
        InfoText([_mangaInfo objectForKey:@"authors"]), InfoText([_mangaInfo objectForKey:@"publisher"]),
        [names componentsJoinedByString:@"\n"], nil];
    for (NSUInteger index = 0; index < [labels count]; index++) {
        NSString *value = [values objectAtIndex:index];
        CGFloat labelHeight = [self infoLabel:[labels objectAtIndex:index] font:[UIFont boldSystemFontOfSize:15]
            top:top left:20 width:122];
        CGFloat valueHeight = [self infoLabel:([value length] ? value : @"Не указано") font:[UIFont systemFontOfSize:16]
            top:top left:154 width:width - 174];
        top += MAX(labelHeight, valueHeight) + 16;
    }
    _infoView.contentSize = CGSizeMake(width, top + 8);
    _status.text = _titleLoaded || !_live ? @"Информация о манге" : @"Загружаем информацию о манге…";
    [self loadCover];
    [self updateResumeButton];
}

- (void)openManga:(NSDictionary *)item {
    [_offlineChapter release]; _offlineChapter = nil; _downloadsReader = NO;
    [_slug release];
    _slug = [[item objectForKey:@"slug_url"] copy];
    [self cancelCoverDownload];
    _cover.image = nil;
    [_mangaInfo release];
    _mangaInfo = [item copy];
    [_chapters release];
    _chapters = nil;
    _titleLoaded = NO;
    _infoView.contentOffset = CGPointZero;
    [self showInformation];
    if (_live) {
        NSString *path = [NSString stringWithFormat:@"/manga/%@?fields%%5B%%5D=authors&fields%%5B%%5D=publisher&fields%%5B%%5D=format&fields%%5B%%5D=otherNames&fields%%5B%%5D=chap_count&fields%%5B%%5D=releaseDate", Escape(_slug)];
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"title", @"kind", path, @"path", nil]];
    }
}

- (void)openChapters {
    if (_busy) {
        return;
    }
    if (!_live || _chapters) {
        [self setItems:(_live ? _chapters : [_snapshot objectForKey:@"chapters"]) screen:1];
        _status.text = _live ? @"Выбери главу" : [NSString stringWithFormat:@"Снимок: %lu из %@ глав",
            (unsigned long)[_items count], [_snapshot objectForKey:@"total_chapters"]];
        if (_resumeRequested) {
            [self resumeSavedChapter];
        }
    } else {
        NSString *path = [NSString stringWithFormat:@"/manga/%@/chapters", Escape(_slug)];
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapters", @"kind", path, @"path", nil]];
    }
}

- (NSDictionary *)savedProgressForSlug:(NSString *)slug {
    id progress = [slug isKindOfClass:[NSString class]] ? [_readingProgress objectForKey:slug] : nil;
    if (![progress isKindOfClass:[NSDictionary class]] ||
        ![InfoText([progress objectForKey:@"volume"]) length] ||
        ![InfoText([progress objectForKey:@"number"]) length] ||
        ![[progress objectForKey:@"page_index"] isKindOfClass:[NSNumber class]] ||
        ![[progress objectForKey:@"page_count"] isKindOfClass:[NSNumber class]]) {
        return nil;
    }
    NSInteger page = [[progress objectForKey:@"page_index"] integerValue];
    NSInteger count = [[progress objectForKey:@"page_count"] integerValue];
    if (page < 0 || count < 1 || page >= count) {
        return nil;
    }
    return progress;
}

- (NSString *)resumeSlug {
    if (_screen != 0) {
        return [self savedProgressForSlug:_slug] ? _slug : nil;
    }
    NSString *latest = nil;
    NSTimeInterval latestTime = 0;
    for (NSString *slug in _readingProgress) {
        NSDictionary *progress = [self savedProgressForSlug:slug];
        NSTimeInterval updated = [InfoText([progress objectForKey:@"updated"]) doubleValue];
        if (progress && (!latest || updated > latestTime)) {
            latest = slug;
            latestTime = updated;
        }
    }
    return latest;
}

- (void)createResumePanel {
    _resumePanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _table.bounds.size.width, 176)];
    _resumePanel.backgroundColor = [UIColor colorWithWhite:28.0 / 255 alpha:1];
    _resumePanel.layer.cornerRadius = 10;
    _resumePanel.hidden = YES;
    UILabel *heading = [[[UILabel alloc] initWithFrame:CGRectMake(16, 8, _resumePanel.bounds.size.width - 32, 28)] autorelease];
    heading.text = @"Продолжить читать";
    heading.font = [UIFont boldSystemFontOfSize:20];
    heading.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    heading.backgroundColor = [UIColor clearColor];
    heading.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_resumePanel addSubview:heading];
    _resume = [UIButton buttonWithType:UIButtonTypeCustom];
    _resume.frame = CGRectMake(16, 44, _resumePanel.bounds.size.width - 32, 112);
    _resume.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_resume setBackgroundImage:ThemeBackgroundImage([UIColor colorWithRed:37.0 / 255 green:37.0 / 255 blue:39.0 / 255 alpha:1],
        [UIColor colorWithRed:37.0 / 255 green:37.0 / 255 blue:39.0 / 255 alpha:1], [UIColor colorWithWhite:0.16 alpha:1])
        forState:UIControlStateNormal];
    [_resume setBackgroundImage:ThemeBackgroundImage([UIColor colorWithWhite:0.23 alpha:1],
        [UIColor colorWithWhite:0.23 alpha:1], [UIColor colorWithWhite:0.28 alpha:1]) forState:UIControlStateHighlighted];
    [_resume addTarget:self action:@selector(continueReading) forControlEvents:UIControlEventTouchUpInside];
    [_resumePanel addSubview:_resume];
    _resumeCover = [[UIImageView alloc] initWithFrame:CGRectMake(8, 10, 60, 92)];
    _resumeCover.contentMode = UIViewContentModeScaleAspectFill;
    _resumeCover.clipsToBounds = YES;
    _resumeCover.layer.cornerRadius = 4;
    _resumeCover.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    [_resume addSubview:_resumeCover];
    _resumeName = [[UILabel alloc] initWithFrame:CGRectMake(80, 10, _resume.bounds.size.width - 96, 44)];
    _resumeName.font = [UIFont boldSystemFontOfSize:15];
    _resumeName.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    _resumeName.backgroundColor = [UIColor clearColor];
    _resumeName.numberOfLines = 2;
    _resumeName.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_resume addSubview:_resumeName];
    _resumeDetails = [[UILabel alloc] initWithFrame:CGRectMake(80, 62, _resume.bounds.size.width - 96, 22)];
    _resumeDetails.font = [UIFont systemFontOfSize:13];
    _resumeDetails.textColor = [UIColor colorWithRed:136.0 / 255 green:136.0 / 255 blue:142.0 / 255 alpha:1];
    _resumeDetails.backgroundColor = [UIColor clearColor];
    _resumeDetails.adjustsFontSizeToFitWidth = YES;
    _resumeDetails.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_resume addSubview:_resumeDetails];
    _resumeProgress = [[MangaLib6ProgressBar alloc] initWithFrame:CGRectMake(80, 94, _resume.bounds.size.width - 96, 6)];
    _resumeProgress.backgroundColor = [UIColor clearColor];
    _resumeProgress.contentMode = UIViewContentModeRedraw;
    _resumeProgress.userInteractionEnabled = NO;
    _resumeProgress.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_resume addSubview:_resumeProgress];
}

- (void)cancelResumeCoverDownload {
    [_resumeConnection cancel];
    [_resumeConnection release];
    _resumeConnection = nil;
    [_resumeData release];
    _resumeData = nil;
}

- (void)loadResumeCoverForSlug:(NSString *)slug progress:(NSDictionary *)progress {
    if ([slug isEqual:_resumeCoverSlug] && (_resumeConnection || _resumeCover.image)) {
        return;
    }
    [self cancelResumeCoverDownload];
    [_resumeCoverSlug release];
    _resumeCoverSlug = [slug copy];
    _resumeCover.image = nil;
    _resumeCover.contentMode = UIViewContentModeScaleAspectFill;
    if ([slug isEqual:_slug] && _cover.image) {
        _resumeCover.image = _cover.image;
        return;
    }
    NSString *url = InfoText([progress objectForKey:@"cover_url"]);
    if (!_live || ![url hasPrefix:@"https://"] || ![[NSURL URLWithString:url] host]) {
        _resumeCover.contentMode = UIViewContentModeScaleAspectFit;
        _resumeCover.image = [UIImage imageNamed:@"Icon.png"];
        return;
    }
    _resumeCover.contentMode = UIViewContentModeScaleAspectFill;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:ImageRequestTimeout];
    [request setValue:@"https://mangalib.me/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"1" forHTTPHeaderField:@"Site-Id"];
    _resumeData = [[NSMutableData alloc] init];
    _resumeConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    [_resumeConnection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_resumeConnection start];
}

- (void)updateResumeButton {
    NSDictionary *progress = [self savedProgressForSlug:[self resumeSlug]];
    BOOL visible = _screen != 2 && progress != nil;
    _resumePanel.hidden = !visible;
    _resume.enabled = !_busy;
    _resume.alpha = _busy ? 0.6 : 1;
    if (_screen == 0 || _screen == 1) {
        if (visible) {
            _resumePanel.frame = CGRectMake(0, 0, _table.bounds.size.width, 176);
            _table.tableHeaderView = _resumePanel;
        } else {
            _table.tableHeaderView = nil;
        }
    }
    if (!visible) {
        [self cancelResumeCoverDownload];
        _resumeCover.image = nil;
        return;
    }
    _resumeName.text = InfoText([progress objectForKey:@"name"]);
    _resumeDetails.text = [NSString stringWithFormat:@"Глава %@ · %ld из %ld стр.",
        [progress objectForKey:@"number"], (long)[[progress objectForKey:@"page_index"] integerValue] + 1,
        (long)[[progress objectForKey:@"page_count"] integerValue]];
    _resumeProgress.progress = (float)([[progress objectForKey:@"page_index"] integerValue] + 1) /
        [[progress objectForKey:@"page_count"] integerValue];
    _resume.accessibilityLabel = [NSString stringWithFormat:@"Продолжить читать. %@. %@",
        _resumeName.text, _resumeDetails.text];
    [self loadResumeCoverForSlug:[self resumeSlug] progress:progress];
}

- (void)saveReadingProgress {
    // Save only a page that has actually appeared, never a pending or failed request.
    if (_smoke || _screen != 2 || !_image.image || ![_slug length] || !_chapter || ![_pages count]) {
        return;
    }
    NSString *volume = InfoText([_chapter objectForKey:@"volume"]);
    NSString *number = InfoText([_chapter objectForKey:@"number"]);
    if (![volume length] || ![number length]) {
        return;
    }
    NSMutableDictionary *progress = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        volume, @"volume", number, @"number", Name(_mangaInfo), @"name",
        [NSNumber numberWithInteger:_pageIndex], @"page_index",
        [NSNumber numberWithUnsignedInteger:[_pages count]], @"page_count",
        [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]], @"updated", nil];
    id cover = [_mangaInfo objectForKey:@"cover"];
    NSString *coverURL = [cover isKindOfClass:[NSDictionary class]] ? InfoText([cover objectForKey:@"thumbnail"]) : @"";
    if (![coverURL length] && [cover isKindOfClass:[NSDictionary class]]) {
        coverURL = InfoText([cover objectForKey:@"md"]);
    }
    if (![coverURL length] && [cover isKindOfClass:[NSDictionary class]]) {
        coverURL = InfoText([cover objectForKey:@"default"]);
    }
    if (![coverURL length]) {
        coverURL = InfoText([[self savedProgressForSlug:_slug] objectForKey:@"cover_url"]);
    }
    if ([coverURL hasPrefix:@"https://"]) {
        [progress setObject:coverURL forKey:@"cover_url"];
    }
    [_readingProgress setObject:progress forKey:_slug];
    [[NSUserDefaults standardUserDefaults] setObject:_readingProgress forKey:@"MangaLib6ReadingProgress"];
}

- (void)flushReadingProgress {
    [self saveReadingProgress];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)continueReading {
    if (_busy || _screen == 2) {
        return;
    }
    NSString *slug = [self resumeSlug];
    NSDictionary *progress = [self savedProgressForSlug:slug];
    if (!progress) {
        return;
    }
    NSDictionary *local = [_downloads entry:ChapterKey(slug, progress)];
    if ([_downloads complete:local]) { [self openDownloaded:local page:[[progress objectForKey:@"page_index"] integerValue]]; return; }
    _resumeRequested = YES;
    if (_screen == 0) {
        [self openManga:[NSDictionary dictionaryWithObjectsAndKeys:slug, @"slug_url",
            [progress objectForKey:@"name"] ?: @"Манга", @"name", nil]];
        if (!_live) {
            [self openChapters];
        }
    } else {
        [self openChapters];
    }
}

- (void)resumeSavedChapter {
    NSDictionary *progress = [self savedProgressForSlug:_slug];
    NSDictionary *selected = nil;
    for (NSDictionary *chapter in _items) {
        if ([InfoText([chapter objectForKey:@"volume"]) isEqual:[progress objectForKey:@"volume"]] &&
            [InfoText([chapter objectForKey:@"number"]) isEqual:[progress objectForKey:@"number"]]) {
            selected = chapter;
            break;
        }
    }
    _resumeRequested = NO;
    if (!selected) {
        _status.text = @"Сохранённая глава сейчас недоступна. Выбери другую главу.";
        return;
    }
    if (_live) {
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", selected, @"chapter",
            _slug, @"slug", [progress objectForKey:@"page_index"], @"resume_page", nil]];
    } else {
        [self resetPageBuffer];
        [_chapter release];
        _chapter = [selected copy];
        [_pages release];
        _pages = [[[_snapshot objectForKey:@"chapter"] objectForKey:@"pages"] copy];
        _pageIndex = MIN(MAX((NSInteger)0, [[progress objectForKey:@"page_index"] integerValue]),
            MAX((NSInteger)0, (NSInteger)[_pages count] - 1));
        [self showPage];
    }
}

- (void)cancelCoverDownload {
    [_coverConnection cancel];
    [_coverConnection release];
    _coverConnection = nil;
    [_coverData release];
    _coverData = nil;
}

- (void)loadCover {
    _coverStatus.hidden = _cover.image != nil;
    if (_cover.image || _coverConnection) {
        return;
    }
    id cover = [_mangaInfo objectForKey:@"cover"];
    NSString *url = [cover isKindOfClass:[NSDictionary class]] ? InfoText([cover objectForKey:@"md"]) : @"";
    if (![url length] && [cover isKindOfClass:[NSDictionary class]]) {
        url = InfoText([cover objectForKey:@"default"]);
    }
    if (!_live || ![url hasPrefix:@"https://"] || ![[NSURL URLWithString:url] host]) {
        _coverStatus.text = _live ? @"Нет обложки" : @"Обложка доступна\nв режиме API";
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
        cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:ImageRequestTimeout];
    [request setValue:@"https://mangalib.me/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"1" forHTTPHeaderField:@"Site-Id"];
    [request setValue:@"https://mangalib.me" forHTTPHeaderField:@"Origin"];
    [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
    _coverData = [[NSMutableData alloc] init];
    _coverStatus.text = @"Загрузка обложки…";
    _coverConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (!_coverConnection) {
        [self cancelCoverDownload];
        _coverStatus.text = @"Не удалось\nзагрузить обложку";
        return;
    }
    [_coverConnection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_coverConnection start];
}

- (void)start:(NSDictionary *)task {
    if ([[task objectForKey:@"kind"] isEqual:@"chapter"]) {
        NSDictionary *local = [_downloads entry:ChapterKey([task objectForKey:@"slug"], [task objectForKey:@"chapter"])];
        if ([_downloads complete:local]) {
            [self stopChapterDownload];
            [_offlineChapter release]; _offlineChapter = [local copy];
            [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", [task objectForKey:@"chapter"], @"chapter",
                [local objectForKey:@"pages"], @"value", [task objectForKey:@"resume_page"] ?: [NSNumber numberWithInt:0], @"resume_page", nil]];
            return;
        }
        [_offlineChapter release]; _offlineChapter = nil;
    }
    [self stopChapterDownload];
    _busy = YES;
    [self updateResumeButton];
    if (_screen == 2) {
        [self updatePageControls];
    }
    _status.text = @"Запрос к MangaLib…";
    [NSThread detachNewThreadSelector:@selector(work:) toTarget:self withObject:task];
}

- (void)search {
    if (_busy) {
        return;
    }
    NSString *query = [_query.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![query length]) {
        [self showSearchHistory];
        return;
    }
    _query.text = query;
    [self flushReadingProgress];
    [self resetPageBuffer];
    [_query resignFirstResponder];
    if (!_smoke && _live) {
        [self rememberSearchQuery:query];
    }
    [self setItems:nil screen:0];
    if (_live) {
        NSString *path = [NSString stringWithFormat:@"/manga?site_id%%5B%%5D=1&q=%@&per_page=20", Escape(query)];
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"catalog", @"kind", path, @"path", nil]];
    } else {
        [self setItems:[_snapshot objectForKey:@"catalog"] screen:0];
        _status.text = _snapshot ? [NSString stringWithFormat:@"Снимок реального API: %@. Открывается выбранная манга и одна глава; это не живая сеть.",
            [_snapshot objectForKey:@"query"]] : @"Нет снимка: запусти fetch_snapshot.py и пересобери IPA.";
    }
}

- (void)loadSearchHistory {
    [_searchHistory release];
    _searchHistory = [[NSMutableArray alloc] init];
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:SearchHistoryKey];
    if (![saved isKindOfClass:[NSArray class]]) {
        return;
    }
    for (id entry in saved) {
        if (![entry isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *query = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![query length]) {
            continue;
        }
        BOOL duplicate = NO;
        for (NSString *existing in _searchHistory) {
            if ([existing caseInsensitiveCompare:query] == NSOrderedSame) {
                duplicate = YES;
                break;
            }
        }
        if (!duplicate) {
            [_searchHistory addObject:query];
        }
        if ([_searchHistory count] == SearchHistoryLimit) {
            break;
        }
    }
}

- (void)persistSearchHistory {
    [[NSUserDefaults standardUserDefaults] setObject:_searchHistory forKey:SearchHistoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)rememberSearchQuery:(NSString *)query {
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![query length]) {
        return;
    }
    if (!_searchHistory) {
        [self loadSearchHistory];
    }
    // Copy before removing a matching entry: query may come from this array.
    NSString *remembered = [query copy];
    for (NSInteger index = (NSInteger)[_searchHistory count] - 1; index >= 0; index--) {
        if ([[_searchHistory objectAtIndex:index] caseInsensitiveCompare:remembered] == NSOrderedSame) {
            [_searchHistory removeObjectAtIndex:index];
        }
    }
    [_searchHistory insertObject:remembered atIndex:0];
    [remembered release];
    while ([_searchHistory count] > SearchHistoryLimit) {
        [_searchHistory removeLastObject];
    }
    [self persistSearchHistory];
}

- (void)updateSearchHistoryStatus {
    _status.text = [_searchHistory count] ? @"Выбери прошлый запрос или введи новый. Свайп влево удаляет запись." :
        @"История поиска пока пуста. Введи название манги.";
}

- (void)showSearchHistory {
    if (_busy) {
        return;
    }
    [self stopChapterDownload];
    [self flushReadingProgress];
    [self setItems:_catalog screen:0];
    _showingSearchHistory = YES;
    [_table reloadData];
    [_table setContentOffset:CGPointZero animated:NO];
    [self updateSearchHistoryStatus];
}

- (void)stopChapterDownload {
    _downloading = NO;
    _downloadPreparing = NO;
    _downloadGeneration++;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(downloadNextPage) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(chapterDownloadTimedOut) object:nil];
    if ([[_imageTask objectForKey:@"kind"] isEqual:@"download-image"]) [self cancelImageDownload];
    [_downloadEntry release]; _downloadEntry = nil;
    [_downloadManga release]; _downloadManga = nil;
    [self updateDownloadControls];
}

- (void)updateDownloadControls {
    _cancelDownloadButton.hidden = !_downloading || _readerFullscreen || _screen == 2;
    CGRect statusFrame = _status.frame;
    statusFrame.size.width = self.view.bounds.size.width - (_downloading && _screen != 2 ? 124 : 24);
    _status.frame = statusFrame;
    BOOL saved = _offlineChapter != nil;
    if (_screen == 2 && !saved && !_downloading)
        saved = [_downloads complete:[_downloads entry:ChapterKey(_slug, _chapter)]];
    [_readerDownloadButton setTitle:(_downloading ? @"Отмена скачивания" : saved ? @"Глава скачана" : @"Скачать главу") forState:UIControlStateNormal];
    _readerDownloadButton.enabled = !_busy && (_downloading || (_live && _chapter && !saved));
}

- (void)cancelChapterDownload {
    [self stopChapterDownload];
    _status.text = @"Скачивание приостановлено. Продолжить можно в «Загрузках».";
    [self updateReaderInfo];
}

- (void)downloadCurrentChapter {
    if (_screen != 2) return;
    if (_downloading) [self cancelChapterDownload];
    else [self downloadChapter:_chapter manga:_mangaInfo];
}

- (void)pauseChapterDownload:(NSNotification *)notification {
    BOOL wasDownloading = _downloading;
    [self stopChapterDownload];
    [self flushReadingProgress];
    if (wasDownloading) _status.text = @"Скачивание приостановлено. Продолжить можно в «Загрузках».";
}

- (void)chapterDownloadTimedOut {
    if (!_downloading) return;
    [self stopChapterDownload];
    _status.text = @"Сервер не ответил за 30 секунд. Продолжи скачивание в «Загрузках».";
}

- (void)downloadsButton {
    if (_downloading) {
        [self stopChapterDownload];
        [self showDownloads];
        _status.text = @"Скачивание приостановлено. Сохранённые страницы останутся в «Загрузках».";
    } else [self showDownloads];
}

- (void)showDownloads {
    if (_busy) return;
    [self stopChapterDownload];
    [self flushReadingProgress];
    [_query resignFirstResponder];
    [self setItems:[_downloads entries] screen:4];
    _table.tableHeaderView = nil;
    _resumePanel.hidden = YES;
    [self cancelResumeCoverDownload];
    [_table setContentOffset:CGPointZero animated:NO];
    _status.text = [_items count] ? @"Скачанные главы доступны без интернета. Нажми незавершённую для продолжения. Свайп влево — удалить." :
        @"Загрузок пока нет. Открой список глав и нажми «Скачать».";
}

- (void)openDownloaded:(NSDictionary *)entry page:(NSInteger)page {
    if (_busy || ![_downloads complete:entry]) return;
    // The selected dictionary can belong to _items, which setItems releases.
    NSDictionary *local = [entry copy];
    [self stopChapterDownload];
    [self flushReadingProgress];
    [self cancelCoverDownload];
    [self cancelResumeCoverDownload];
    [_slug release]; _slug = [[[local objectForKey:@"manga"] objectForKey:@"slug_url"] copy];
    [_mangaInfo release]; _mangaInfo = [[local objectForKey:@"manga"] copy];
    NSMutableArray *chapters = [NSMutableArray array];
    for (NSDictionary *item in [_downloads entries])
        if ([[[item objectForKey:@"manga"] objectForKey:@"slug_url"] isEqual:_slug] && [_downloads complete:item])
            [chapters addObject:[item objectForKey:@"chapter"]];
    [chapters sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult volume = [[NSDecimalNumber decimalNumberWithString:InfoText([a objectForKey:@"volume"])]
            compare:[NSDecimalNumber decimalNumberWithString:InfoText([b objectForKey:@"volume"])]];
        return volume == NSOrderedSame ? [[NSDecimalNumber decimalNumberWithString:InfoText([a objectForKey:@"number"])]
            compare:[NSDecimalNumber decimalNumberWithString:InfoText([b objectForKey:@"number"])]] : volume;
    }];
    [self setItems:chapters screen:1];
    _downloadsReader = YES;
    [_offlineChapter release]; _offlineChapter = [local copy];
    [self finish:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", [local objectForKey:@"chapter"], @"chapter",
        [local objectForKey:@"pages"], @"value", [NSNumber numberWithInteger:page], @"resume_page", nil]];
    [local release];
}

- (void)downloadChapterButton:(UIButton *)button {
    if (_screen != 1 || button.tag < 0 || button.tag >= (NSInteger)[_items count]) return;
    [self downloadChapter:[_items objectAtIndex:button.tag] manga:_mangaInfo];
}

- (void)downloadChapter:(NSDictionary *)chapter manga:(NSDictionary *)manga {
    if (_busy || _downloading || !_live || ![InfoText([manga objectForKey:@"slug_url"]) length]) return;
    [self cancelImageDownload];
    [self cancelCoverDownload];
    [self cancelResumeCoverDownload];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(prefetchPages) object:nil];
    _downloading = YES;
    _downloadGeneration++;
    _downloadManga = [manga copy];
    [self updateDownloadControls];
    _status.text = @"Получаем главу для скачивания…";
    [self performSelector:@selector(chapterDownloadTimedOut) withObject:nil afterDelay:30];
    NSMutableDictionary *existing = [_downloads entry:ChapterKey([manga objectForKey:@"slug_url"], chapter)];
    NSArray *knownPages = _screen == 2 && [chapter isEqual:_chapter] ? _pages : [existing objectForKey:@"pages"];
    if ([knownPages count]) {
        _downloadEntry = [[_downloads prepare:manga chapter:chapter pages:knownPages] retain];
        if (_downloadEntry) { [self downloadNextPage]; return; }
        [self stopChapterDownload]; _status.text = @"Не удалось сохранить загрузку. Проверь свободное место."; return;
    }
    _downloadPreparing = YES;
    [NSThread detachNewThreadSelector:@selector(work:) toTarget:self withObject:
        [NSDictionary dictionaryWithObjectsAndKeys:@"download-chapter", @"kind", chapter, @"chapter", [manga objectForKey:@"slug_url"], @"slug",
        [NSNumber numberWithUnsignedInteger:_downloadGeneration], @"download_generation", nil]];
}

- (void)downloadNextPage {
    if (!_downloading || _downloadPreparing || !_downloadEntry || _imageTask) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(chapterDownloadTimedOut) object:nil];
    [self performSelector:@selector(chapterDownloadTimedOut) withObject:nil afterDelay:30];
    NSArray *pages = [_downloadEntry objectForKey:@"pages"];
    NSInteger index = 0;
    while (index < (NSInteger)[pages count] && [_downloads hasPage:index entry:_downloadEntry]) index++;
    if (index == (NSInteger)[pages count]) {
        BOOL saved = [_downloads finish:_downloadEntry];
        [self stopChapterDownload];
        if (_screen == 4) [self showDownloads]; else [_table reloadData];
        _status.text = saved ? @"Глава скачана. Можно читать без интернета в «Загрузках»." :
            @"Не удалось завершить загрузку. Продолжи скачивание в «Загрузках».";
        [self updateReaderInfo];
        return;
    }
    _status.text = [NSString stringWithFormat:@"Скачивание: %lu / %lu стр. Кнопка «Отмена» приостанавливает загрузку.",
        (unsigned long)[_downloads count:_downloadEntry], (unsigned long)[pages count]];
    [self updateReaderInfo];
    if (![_imageServers count]) { [self refreshImageServers]; return; }
    [self startImageDownload:[NSDictionary dictionaryWithObjectsAndKeys:@"download-image", @"kind",
        [[pages objectAtIndex:index] objectForKey:@"url"], @"image_path", [NSNumber numberWithInteger:index], @"page_index",
        _imageServers, @"servers", [NSNumber numberWithUnsignedInteger:_downloadGeneration], @"download_generation", nil]];
}

- (void)clearSearchHistory {
    if (_busy || !_showingSearchHistory) {
        return;
    }
    [_searchHistory removeAllObjects];
    [self persistSearchHistory];
    [_table reloadData];
    [self updateSearchHistoryStatus];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    if (textField == _query) {
        [self showSearchHistory];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self search];
    return YES;
}

- (void)goBack {
    if (!_busy) {
        [self flushReadingProgress];
        if (_downloadsReader) { [self showDownloads]; return; }
        if (_screen == 4) { [self showSearchHistory]; return; }
        if (_screen == 2) {
            [self setItems:_items screen:1];
            _status.text = @"Выбери главу";
        } else if (_screen == 1) {
            [self showInformation];
        } else if (_screen == 3) {
            [self setItems:_catalog screen:0];
            _status.text = @"Выбери мангу";
        } else {
            [self showSearchHistory];
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _showingSearchHistory ? [_searchHistory count] : [_items count];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (!_showingSearchHistory) {
        return nil;
    }
    CGFloat width = tableView.bounds.size.width;
    UIView *header = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 44)] autorelease];
    header.backgroundColor = ThemeBackground();
    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(12, 0, width - 124, 44)] autorelease];
    title.text = @"История поиска";
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textColor = ThemeText();
    title.backgroundColor = [UIColor clearColor];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:title];
    if ([_searchHistory count]) {
        UIButton *clear = [UIButton buttonWithType:UIButtonTypeCustom];
        clear.frame = CGRectMake(width - 104, 5, 92, 34);
        clear.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        ThemeButton(clear);
        [clear setTitle:@"Очистить" forState:UIControlStateNormal];
        clear.enabled = !_busy;
        [clear addTarget:self action:@selector(clearSearchHistory) forControlEvents:UIControlEventTouchUpInside];
        [header addSubview:clear];
    }
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return _showingSearchHistory ? 44 : 0;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return (_showingSearchHistory || _screen == 4) && !_busy;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    return @"Удалить";
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_screen == 4 && !_busy && editingStyle == UITableViewCellEditingStyleDelete && indexPath.row < (NSInteger)[_items count]) {
        [self stopChapterDownload];
        if (![_downloads remove:[[_items objectAtIndex:indexPath.row] objectForKey:@"id"]]) {
            _status.text = @"Не удалось удалить загрузку"; return;
        }
        [self showDownloads]; return;
    }
    if (!_showingSearchHistory || _busy || editingStyle != UITableViewCellEditingStyleDelete ||
        indexPath.row >= (NSInteger)[_searchHistory count]) {
        return;
    }
    [_searchHistory removeObjectAtIndex:indexPath.row];
    [self persistSearchHistory];
    [tableView reloadData];
    [self updateSearchHistoryStatus];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"] autorelease];
        cell.backgroundView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        cell.backgroundView.backgroundColor = ThemeSurface();
        cell.selectedBackgroundView = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        cell.selectedBackgroundView.backgroundColor = ThemeAccent();
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = ThemeText();
        cell.textLabel.highlightedTextColor = [UIColor whiteColor];
        cell.detailTextLabel.backgroundColor = [UIColor clearColor];
        cell.detailTextLabel.textColor = ThemeSecondaryText();
        cell.detailTextLabel.highlightedTextColor = ThemeBackground();
        UILabel *disclosure = [[[UILabel alloc] initWithFrame:CGRectMake(0, 0, 18, 30)] autorelease];
        disclosure.text = @"›";
        disclosure.font = [UIFont boldSystemFontOfSize:28];
        disclosure.backgroundColor = [UIColor clearColor];
        disclosure.textColor = ThemeAccent();
        disclosure.highlightedTextColor = [UIColor whiteColor];
        cell.accessoryView = disclosure;
    }
    UILabel *arrow = [[[UILabel alloc] initWithFrame:CGRectMake(0, 0, 18, 30)] autorelease];
    arrow.text = @"›"; arrow.textColor = ThemeAccent(); arrow.font = [UIFont boldSystemFontOfSize:28];
    arrow.backgroundColor = [UIColor clearColor]; cell.accessoryView = arrow;
    if (_showingSearchHistory) {
        cell.textLabel.text = [_searchHistory objectAtIndex:indexPath.row];
        cell.detailTextLabel.text = @"Повторить поиск";
        return cell;
    }
    NSDictionary *item = [_items objectAtIndex:indexPath.row];
    if (_screen == 4) {
        NSDictionary *chapter = [item objectForKey:@"chapter"];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · Глава %@", Name([item objectForKey:@"manga"]),
            [chapter objectForKey:@"number"]];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu/%lu страниц · Свайп: удалить",
            [_downloads complete:item] ? @"Без интернета" : @"Нажми, чтобы продолжить скачивание",
            (unsigned long)[_downloads count:item], (unsigned long)[[item objectForKey:@"pages"] count]];
        return cell;
    }
    cell.textLabel.text = _screen == 0 ? Name(item) : [NSString stringWithFormat:@"Том %@, глава %@ — %@",
        [item objectForKey:@"volume"], [item objectForKey:@"number"], Name(item)];
    if (_screen == 0) {
        NSDictionary *progress = [self savedProgressForSlug:[item objectForKey:@"slug_url"]];
        cell.detailTextLabel.text = progress ? [NSString stringWithFormat:@"Место чтения: глава %@, стр. %ld/%ld",
            [progress objectForKey:@"number"], (long)[[progress objectForKey:@"page_index"] integerValue] + 1,
            (long)[[progress objectForKey:@"page_count"] integerValue]] : [item objectForKey:@"slug_url"];
    } else {
        NSDictionary *local = [_downloads entry:ChapterKey(_slug, item)];
        UIButton *download = [UIButton buttonWithType:UIButtonTypeCustom]; ThemeButton(download);
        download.frame = CGRectMake(0, 0, 78, 34); download.tag = indexPath.row; download.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [download setTitle:([_downloads complete:local] ? @"Скачана" : @"Скачать") forState:UIControlStateNormal];
        download.enabled = ![_downloads complete:local] && !_busy && !_downloading;
        [download addTarget:self action:@selector(downloadChapterButton:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = download;
        NSString *date = ChapterPublicationDate(item);
        NSDictionary *progress = [self savedProgressForSlug:_slug];
        BOOL savedChapter = [InfoText([item objectForKey:@"volume"]) isEqual:[progress objectForKey:@"volume"]] &&
            [InfoText([item objectForKey:@"number"]) isEqual:[progress objectForKey:@"number"]];
        cell.detailTextLabel.text = savedChapter ? [NSString stringWithFormat:@"Место чтения: стр. %ld/%ld%@",
            (long)[[progress objectForKey:@"page_index"] integerValue] + 1,
            (long)[[progress objectForKey:@"page_count"] integerValue],
            [date length] ? [NSString stringWithFormat:@" · %@", date] : @""] :
            ([date length] ? [NSString stringWithFormat:@"Опубликована: %@", date] : @"Дата публикации не указана");
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy) {
        return;
    }
    if (_showingSearchHistory) {
        _query.text = [_searchHistory objectAtIndex:indexPath.row];
        [self search];
        return;
    }
    NSDictionary *item = [_items objectAtIndex:indexPath.row];
    if (_screen == 4) {
        if ([_downloads complete:item]) {
            NSDictionary *progress = [self savedProgressForSlug:[[item objectForKey:@"manga"] objectForKey:@"slug_url"]];
            NSDictionary *chapter = [item objectForKey:@"chapter"];
            BOOL same = [InfoText([chapter objectForKey:@"volume"]) isEqual:[progress objectForKey:@"volume"]] &&
                [InfoText([chapter objectForKey:@"number"]) isEqual:[progress objectForKey:@"number"]];
            [self openDownloaded:item page:same ? [[progress objectForKey:@"page_index"] integerValue] : 0];
        } else [self downloadChapter:[item objectForKey:@"chapter"] manga:[item objectForKey:@"manga"]];
        return;
    }
    if (_screen == 0) {
        if (!_live && ![[item objectForKey:@"slug_url"] isEqual:[[_snapshot objectForKey:@"title"] objectForKey:@"slug_url"]]) {
            _status.text = [NSString stringWithFormat:@"Для этой манги нет снимка. Выбери %@.", Name([_snapshot objectForKey:@"title"])];
            return;
        }
        [self openManga:item];
    } else if (_live) {
        NSDictionary *progress = [self savedProgressForSlug:_slug];
        BOOL savedChapter = [InfoText([item objectForKey:@"volume"]) isEqual:[progress objectForKey:@"volume"]] &&
            [InfoText([item objectForKey:@"number"]) isEqual:[progress objectForKey:@"number"]];
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", item, @"chapter", _slug, @"slug",
            savedChapter ? [progress objectForKey:@"page_index"] : [NSNumber numberWithInteger:0], @"resume_page", nil]];
    } else {
        [self resetPageBuffer];
        [_chapter release];
        _chapter = [item copy];
        [_pages release];
        _pages = [[[_snapshot objectForKey:@"chapter"] objectForKey:@"pages"] copy];
        _pageIndex = 0;
        [self showPage];
    }
}

- (void)showPage {
    if (![_pages count]) {
        _status.text = @"Нет доступных страниц";
        return;
    }
    BOOL enteringReader = _screen != 2;
    [self animateNavigationToScreen:2];
    _screen = 2;
    [self setReaderFullscreen:enteringReader ? UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone : _readerFullscreen];
    [self updateResumeButton];
    [self cancelCoverDownload];
    _infoView.hidden = YES;
    _table.hidden = YES;
    _pageView.hidden = NO;
    _previous.hidden = _readerFullscreen;
    _next.hidden = _readerFullscreen;
    [self updatePageControls];
    NSString *pagePath = [[_pages objectAtIndex:_pageIndex] objectForKey:@"url"];
    if (_offlineChapter) {
        [self cancelImageDownload];
        [self transitionToPageImage:nil];
        _status.text = @"Открываем сохранённую страницу…";
        [self updateReaderInfo];
        if (!_imageDecodeCount) [self startOfflinePageDecode];
        return;
    }
    if (_live) {
        [self trimPageBuffer];
        NSNumber *page = [NSNumber numberWithInteger:_pageIndex];
        [_pageErrors removeObjectForKey:page];
        UIImage *image = [_pageCache objectForKey:page];
        if (image) {
            [self displayPageImage:image cacheHit:YES];
        } else {
            [self transitionToPageImage:nil];
            if (_imageTask && [[_imageTask objectForKey:@"page_index"] integerValue] != _pageIndex) {
                [self cancelImageDownload];
            }
            [self updatePageStatus];
        }
        [self prefetchPages];
    } else {
        NSString *filename = [[_snapshot objectForKey:@"image_files"] objectForKey:pagePath];
        NSString *path = filename ? [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:filename] : nil;
        [self transitionToPageImage:(path ? [UIImage imageWithContentsOfFile:path] : nil)];
        [self saveReadingProgress];
        _status.text = _image.image ? [NSString stringWithFormat:@"Снимок: страница %ld/%lu (в главе %@)",
            (long)_pageIndex + 1, (unsigned long)[_pages count], [_snapshot objectForKey:@"total_pages"]] : @"Картинка не найдена";
        NSLog(@"MangaLib6 snapshot page %ld: %@ decoded=%@", (long)_pageIndex + 1, filename, _image.image ? @"YES" : @"NO");
        [self updateReaderInfo];
    }
}

- (NSDictionary *)nextChapter {
    if (!_live || _screen != 2 || !_chapter) {
        return nil;
    }
    NSUInteger index = [_items indexOfObject:_chapter];
    return index != NSNotFound && index + 1 < [_items count] ? [_items objectAtIndex:index + 1] : nil;
}

- (void)updatePageControls {
    BOOL lastPage = _pageIndex + 1 >= (NSInteger)[_pages count];
    NSDictionary *chapter = lastPage ? [self nextChapter] : nil;
    [_next setTitle:(lastPage ? (chapter ? @"Следующая глава >" : @"Конец манги") : @"Страница >")
        forState:UIControlStateNormal];
    _previous.enabled = !_busy && _pageIndex > 0;
    _next.enabled = !_busy && (!lastPage || chapter != nil);
    [self updateDownloadControls];
}

- (void)previousPage {
    if (!_busy && _pageIndex > 0) {
        [self stopChapterDownload];
        _pageDirection = -1;
        _pageIndex--;
        [self showPage];
    }
}

- (void)resetPageBuffer {
    _readerGeneration++;
    _pageDirection = 0;
    [self cancelImageDownload];
    [_pageCache removeAllObjects];
    _pageImageEstimate = 0;
    [_pageErrors removeAllObjects];
    [self setPageImage:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(nextPage) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(prefetchPages) object:nil];
}

- (NSInteger)bufferStart {
    return MAX((NSInteger)0, _pageIndex - (_lowMemory ? 0 : PageHistorySize));
}

- (NSInteger)bufferEnd {
    return MIN(_pageIndex + (_lowMemory ? 1 : PageBufferSize), (NSInteger)[_pages count]);
}

- (void)trimPageBuffer {
    for (NSMutableDictionary *entries in [NSArray arrayWithObjects:_pageCache, _pageErrors, nil]) {
        for (NSNumber *page in [entries allKeys]) {
            if ([page integerValue] < [self bufferStart] || [page integerValue] >= [self bufferEnd]) {
                [entries removeObjectForKey:page];
            }
        }
    }
    // Seven full-resolution scans can exceed the iPhone 4's available app memory.
    unsigned long long budget = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone ? 24ULL : 48ULL) * 1024 * 1024;
    unsigned long long bytes = 0;
    for (UIImage *image in [_pageCache allValues]) bytes += PageImageBytes(image);
    while (bytes > budget && [_pageCache count] > 1) {
        NSNumber *victim = nil;
        NSInteger distance = -1;
        for (NSNumber *page in _pageCache) {
            NSInteger index = [page integerValue];
            if (index == _pageIndex) continue;
            // Keep the nearest unread pages before history pages.
            NSInteger priority = index < _pageIndex ? PageBufferSize + _pageIndex - index : index - _pageIndex;
            if (priority > distance) { victim = page; distance = priority; }
        }
        if (!victim) break;
        bytes -= PageImageBytes([_pageCache objectForKey:victim]);
        [_pageCache removeObjectForKey:victim];
    }
}

- (void)updatePageStatus {
    NSNumber *page = [NSNumber numberWithInteger:_pageIndex];
    NSDictionary *error = [_pageErrors objectForKey:page];
    if (error) {
        _status.text = [NSString stringWithFormat:@"Страница %ld: %@. %@", (long)_pageIndex + 1,
            [error objectForKey:@"message"], [error objectForKey:@"retry_at"] ? @"Повторяем в фоне…" : @"Для повтора вернись на неё."];
    } else {
        NSInteger forwardCount = 0;
        NSInteger historyCount = 0;
        for (NSNumber *cachedPage in _pageCache) {
            if ([cachedPage integerValue] >= _pageIndex) {
                forwardCount++;
            } else {
                historyCount++;
            }
        }
        _status.text = [NSString stringWithFormat:@"Прямой API: страница %ld/%lu%@. Буфер: %ld/%ld. Назад: %ld",
            (long)_pageIndex + 1, (unsigned long)[_pages count], _image.image ? @"" : @" — загрузка",
            (long)forwardCount, (long)([self bufferEnd] - _pageIndex), (long)historyCount];
    }
    [self updateReaderInfo];
}

- (void)displayPageImage:(UIImage *)image cacheHit:(BOOL)cacheHit {
    [self transitionToPageImage:image];
    [self saveReadingProgress];
    [self updatePageStatus];
    NSLog(@"MangaLib6 live page %ld: decoded=%@ cacheHit=%@", (long)_pageIndex + 1,
        _image.image ? @"YES" : @"NO", cacheHit ? @"YES" : @"NO");
    if (_smoke) {
        if (_pageIndex < 2 && _pageIndex + 1 < (NSInteger)[_pages count]) {
            [self performSelector:@selector(nextPage) withObject:nil afterDelay:0.5];
        } else {
            NSLog(@"MangaLib6 smoke live COMPLETE");
            _smoke = NO;
        }
    }
}

- (void)prefetchPages {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(prefetchPages) object:nil];
    if (_offlineChapter || _downloading || !_live || _screen != 2 || _busy || _imageTask || _imageDecodeCount) {
        return;
    }
    if (![_imageServers count]) {
        if (!_serversLoading) {
            [self refreshImageServers];
        }
        if (_serversLoading) {
            _status.text = @"Получаем адреса серверов изображений…";
        }
        return;
    }
    NSTimeInterval retryDelay = 0;
    for (NSInteger index = _pageIndex; index < [self bufferEnd]; index++) {
        NSNumber *page = [NSNumber numberWithInteger:index];
        if ([_pageCache objectForKey:page]) {
            continue;
        }
        if (index != _pageIndex && [_pageCache count]) {
            unsigned long long bytes = 0, largest = _pageImageEstimate;
            for (UIImage *image in [_pageCache allValues]) {
                unsigned long long size = PageImageBytes(image);
                bytes += size; largest = MAX(largest, size);
            }
            unsigned long long budget = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone ? 24ULL : 48ULL) * 1024 * 1024;
            if (bytes + largest > budget) return;
        }
        NSDictionary *failure = [_pageErrors objectForKey:page];
        if (failure) {
            NSDate *retryAt = [failure objectForKey:@"retry_at"];
            if (!retryAt) {
                continue;
            }
            NSTimeInterval remaining = [retryAt timeIntervalSinceNow];
            if (remaining > 0) {
                retryDelay = retryDelay ? MIN(retryDelay, remaining) : remaining;
                continue;
            }
        }
        NSMutableDictionary *task = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"image", @"kind",
            [[_pages objectAtIndex:index] objectForKey:@"url"], @"image_path", page, @"page_index",
            [NSNumber numberWithUnsignedInteger:_readerGeneration], @"generation", nil];
        if (failure) {
            [task setObject:[failure objectForKey:@"retry_count"] forKey:@"retry_count"];
        }
        if (_imageServers) {
            [task setObject:_imageServers forKey:@"servers"];
        }
        NSLog(@"MangaLib6 buffer download page %ld (current %ld)", (long)index + 1, (long)_pageIndex + 1);
        [self startImageDownload:task];
        return;
    }
    if (retryDelay > 0) {
        [self performSelector:@selector(prefetchPages) withObject:nil afterDelay:retryDelay];
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self cancelResumeCoverDownload];
    _resumeCover.image = nil;
    [_contentView.layer removeAnimationForKey:@"navigation"];
    [_pageView.layer removeAnimationForKey:@"pageTransition"];
    [_image.layer removeAnimationForKey:@"pageTransition"];
    [_table.layer removeAnimationForKey:@"appearance"];
    [_infoView.layer removeAnimationForKey:@"appearance"];
    [_cover.layer removeAnimationForKey:@"appearance"];
    if (_screen != 3) {
        [self cancelCoverDownload];
        _cover.image = nil;
    }
    _lowMemory = YES;
    _readerGeneration++;
    [self cancelImageDownload];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(prefetchPages) object:nil];
    [self trimPageBuffer];
    if (_live && _screen == 2 && !_busy) {
        [self updatePageStatus];
        [self prefetchPages];
    }
}

- (void)nextPage {
    if (_busy || _screen != 2 || ![_pages count]) {
        return;
    }
    if (_pageIndex + 1 < (NSInteger)[_pages count]) {
        [self stopChapterDownload];
        _pageDirection = 1;
        _pageIndex++;
        [self showPage];
    } else {
        NSDictionary *chapter = [self nextChapter];
        if (chapter) {
            [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", chapter, @"chapter", _slug, @"slug", nil]];
        }
    }
}

- (void)refreshImageServers {
    if (_serversLoading) {
        return;
    }
    _serversLoading = YES;
    [NSThread detachNewThreadSelector:@selector(work:) toTarget:self withObject:
        [NSDictionary dictionaryWithObject:@"servers" forKey:@"kind"]];
}

- (void)cancelImageDownload {
    _imageDecodeGeneration++;
    [_imageConnection cancel];
    [_imageConnection release];
    _imageConnection = nil;
    [_imageData release];
    _imageData = nil;
    [_imageTask release];
    _imageTask = nil;
    [_imageURLs release];
    _imageURLs = nil;
}

- (void)startImageDownload:(NSDictionary *)task {
    NSMutableDictionary *timedTask = [NSMutableDictionary dictionaryWithDictionary:task];
    [timedTask setObject:[NSDate date] forKey:@"started_at"];
    _imageTask = [timedTask copy];
    _imageServerIndex = 0;
    _imageRetryable = NO;
    NSString *relative = [task objectForKey:@"image_path"];
    while ([relative hasPrefix:@"/"]) {
        relative = [relative substringFromIndex:1];
    }
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *serverID in [NSArray arrayWithObjects:@"compress", @"download", @"secondary", @"main", nil]) {
        for (NSDictionary *server in [task objectForKey:@"servers"]) {
            if (![[server objectForKey:@"id"] isEqual:serverID] ||
                ![[server objectForKey:@"site_ids"] containsObject:[NSNumber numberWithInt:1]]) {
                continue;
            }
            NSString *base = [server objectForKey:@"url"];
            if (![base isKindOfClass:[NSString class]] || ![base hasPrefix:@"https://"]) {
                continue;
            }
            NSString *url = [NSString stringWithFormat:@"%@/%@", base, relative];
            if (![urls containsObject:url]) {
                if ([base isEqual:_preferredImageServer]) {
                    [urls insertObject:url atIndex:0];
                } else {
                    [urls addObject:url];
                }
            }
        }
    }
    _imageURLs = [urls copy];
    if (![_imageURLs count]) {
        [self completeImageDownload:nil error:[NSError errorWithDomain:@"MangaLib6" code:0 userInfo:
            [NSDictionary dictionaryWithObject:@"Нет подходящих серверов изображений" forKey:NSLocalizedDescriptionKey]]];
        return;
    }
    [self openImageConnection];
}

- (void)completeImageDownload:(UIImage *)image error:(NSError *)error {
    if ([[_imageTask objectForKey:@"kind"] isEqual:@"download-image"]) {
        if (!_downloading || [[_imageTask objectForKey:@"download_generation"] unsignedIntegerValue] != _downloadGeneration) {
            [self cancelImageDownload]; return;
        }
        NSInteger index = [[_imageTask objectForKey:@"page_index"] integerValue];
        BOOL saved = image && _downloading && [_downloads savePage:_imageData index:index entry:_downloadEntry];
        [self cancelImageDownload];
        if (!saved) {
            [self stopChapterDownload];
            _status.text = error ? [error localizedDescription] : @"Не удалось сохранить страницу. Проверь свободное место.";
        } else {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(chapterDownloadTimedOut) object:nil];
            [self performSelector:@selector(downloadNextPage) withObject:nil afterDelay:0.05];
        }
        return;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:_imageTask];
    if (image) {
        [result setObject:image forKey:@"value"];
    } else {
        [result setObject:(error ? [error localizedDescription] : @"Изображение не поддерживается") forKey:@"error"];
        [result setObject:[NSNumber numberWithBool:_imageRetryable] forKey:@"retryable"];
    }
    [self cancelImageDownload];
    [self finish:result];
}

- (void)openImageConnection {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[_imageURLs objectAtIndex:_imageServerIndex]]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:ImageRequestTimeout];
    [request setValue:@"1" forHTTPHeaderField:@"Site-Id"];
    [request setValue:@"https://mangalib.me/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"https://mangalib.me" forHTTPHeaderField:@"Origin"];
    [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    _imageData = [[NSMutableData alloc] init];
    _imageConnection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (!_imageConnection) {
        [self completeImageDownload:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil]];
        return;
    }
    [_imageConnection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_imageConnection start];
}

- (void)imageDownloadFailed:(NSError *)error allowFallback:(BOOL)allowFallback {
    _imageRetryable = _imageRetryable || TransientNetworkError(error);
    [_imageConnection cancel];
    [_imageConnection release];
    _imageConnection = nil;
    [_imageData release];
    _imageData = nil;
    if (allowFallback && _imageServerIndex + 1 < [_imageURLs count]) {
        _imageServerIndex++;
        [self openImageConnection];
    } else {
        [self completeImageDownload:nil error:error];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (connection == _resumeConnection) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            [self cancelResumeCoverDownload];
            _resumeCover.image = [UIImage imageNamed:@"Icon.png"];
        } else {
            [_resumeData setLength:0];
        }
        return;
    }
    if (connection == _coverConnection) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (status < 200 || status >= 300) {
            [self cancelCoverDownload];
            _coverStatus.text = [NSString stringWithFormat:@"Обложка:\nHTTP %ld", (long)status];
        } else {
            [_coverData setLength:0];
        }
        return;
    }
    if (connection != _imageConnection) {
        return;
    }
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (status < 200 || status >= 300) {
        NSError *error = [NSError errorWithDomain:@"MangaLib6" code:status userInfo:
            [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"HTTP %ld", (long)status] forKey:NSLocalizedDescriptionKey]];
        [self imageDownloadFailed:error allowFallback:status != 403 && status != 429];
        return;
    }
    [_imageData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (connection == _resumeConnection) {
        [_resumeData appendData:data];
        return;
    }
    if (connection == _coverConnection) {
        [_coverData appendData:data];
        return;
    }
    if (connection == _imageConnection) {
        [_imageData appendData:data];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if (connection == _resumeConnection) {
        [self cancelResumeCoverDownload];
        _resumeCover.image = [UIImage imageNamed:@"Icon.png"];
        return;
    }
    if (connection == _coverConnection) {
        [self cancelCoverDownload];
        _coverStatus.text = @"Не удалось\nзагрузить обложку";
        return;
    }
    if (connection == _imageConnection) {
        [self imageDownloadFailed:error allowFallback:TransientNetworkError(error)];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (connection == _resumeConnection) {
        _resumeCover.image = [UIImage imageWithData:_resumeData] ?: [UIImage imageNamed:@"Icon.png"];
        [self cancelResumeCoverDownload];
        [self animateAppearance:_resumeCover];
        return;
    }
    if (connection == _coverConnection) {
        _cover.image = [UIImage imageWithData:_coverData];
        _coverStatus.hidden = _cover.image != nil;
        _coverStatus.text = @"Обложка\nне поддерживается";
        [self cancelCoverDownload];
        if (_cover.image && !_infoView.hidden) {
            [self animateAppearance:_cover];
        }
        return;
    }
    if (connection != _imageConnection) {
        return;
    }
    NSDictionary *task = [NSDictionary dictionaryWithObjectsAndKeys:
        [[_imageData copy] autorelease], @"data", [NSNumber numberWithUnsignedInteger:_imageDecodeGeneration], @"decode_generation", nil];
    _imageDecodeCount++;
    [NSThread detachNewThreadSelector:@selector(decodePage:) toTarget:self withObject:task];
}

- (void)decodePage:(NSDictionary *)task {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSData *data = [task objectForKey:@"data"];
    if ([task objectForKey:@"offline"]) data = [_downloads page:[[task objectForKey:@"page_index"] integerValue]
        entry:[task objectForKey:@"offline"]];
    UIImage *image = DecodePageImage(data);
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:task];
    [result removeObjectForKey:@"data"];
    if (image) [result setObject:image forKey:@"value"];
    [self performSelectorOnMainThread:@selector(finishDecodedPage:) withObject:result waitUntilDone:NO];
    [pool drain];
}

- (void)finishDecodedPage:(NSDictionary *)result {
    if (_imageDecodeCount) _imageDecodeCount--;
    if ([result objectForKey:@"offline"]) {
        if ([[result objectForKey:@"decode_generation"] unsignedIntegerValue] == _imageDecodeGeneration &&
            _offlineChapter && _screen == 2 && [[result objectForKey:@"page_index"] integerValue] == _pageIndex) {
            UIImage *image = [result objectForKey:@"value"];
            [self transitionToPageImage:image];
            [self saveReadingProgress];
            _status.text = image ? [NSString stringWithFormat:@"Без интернета: страница %ld/%lu. Осталось: %ld",
                (long)_pageIndex + 1, (unsigned long)[_pages count], (long)[_pages count] - _pageIndex - 1] :
                @"Сохранённая страница повреждена. Удали загрузку и скачай главу заново.";
            [self updateReaderInfo];
        } else if (_offlineChapter && _screen == 2 && !_imageDecodeCount) {
            [self startOfflinePageDecode];
        } else {
            [self prefetchPages];
        }
        return;
    }
    if ([[result objectForKey:@"decode_generation"] unsignedIntegerValue] != _imageDecodeGeneration || !_imageTask) {
        if (_offlineChapter && _screen == 2 && !_imageDecodeCount) { [self startOfflinePageDecode]; return; }
        [self prefetchPages];
        return;
    }
    UIImage *image = [result objectForKey:@"value"];
    if (!image) {
        [self imageDownloadFailed:nil allowFallback:YES];
        return;
    }
    NSString *url = [_imageURLs objectAtIndex:_imageServerIndex];
    NSLog(@"MangaLib6 HTTP 200 %@ (%lu bytes)", url, (unsigned long)[_imageData length]);
    NSURL *address = [NSURL URLWithString:url];
    NSString *base = [NSString stringWithFormat:@"%@://%@", [address scheme], [address host]];
    if (![base isEqual:_preferredImageServer]) {
        [_preferredImageServer release];
        _preferredImageServer = [base copy];
        [[NSUserDefaults standardUserDefaults] setObject:base forKey:@"MangaLib6PreferredImageServer"];
    }
    [self completeImageDownload:image error:nil];
}

- (void)startOfflinePageDecode {
    NSDictionary *task = [NSDictionary dictionaryWithObjectsAndKeys:
        _offlineChapter, @"offline", [NSNumber numberWithInteger:_pageIndex], @"page_index",
        [NSNumber numberWithUnsignedInteger:_imageDecodeGeneration], @"decode_generation", nil];
    _imageDecodeCount++;
    [NSThread detachNewThreadSelector:@selector(decodePage:) toTarget:self withObject:task];
}

- (void)work:(NSDictionary *)task {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *kind = [task objectForKey:@"kind"];
    NSError *error = nil;
    id value = nil;
    if ([kind isEqual:@"servers"]) {
        id constants = Fetch(@"/constants?fields%5B%5D=imageServers", &error);
        id available = [constants isKindOfClass:[NSDictionary class]] ? [constants objectForKey:@"imageServers"] : nil;
        if ([available isKindOfClass:[NSArray class]] && [available count]) {
            value = available;
        }
    } else if ([kind isEqual:@"title"]) {
        value = Fetch([task objectForKey:@"path"], &error);
        if (![value isKindOfClass:[NSDictionary class]]) {
            value = nil;
        }
    } else if ([kind isEqual:@"chapter"] || [kind isEqual:@"download-chapter"]) {
        NSDictionary *chapter = [task objectForKey:@"chapter"];
        NSArray *branches = [chapter objectForKey:@"branches"];
        if (![branches count]) {
            branches = [NSArray arrayWithObject:[NSDictionary dictionary]];
        }
        for (NSDictionary *branch in branches) {
            NSString *path = [NSString stringWithFormat:@"/manga/%@/chapter?volume=%@&number=%@",
                Escape([task objectForKey:@"slug"]), Escape([chapter objectForKey:@"volume"]), Escape([chapter objectForKey:@"number"])];
            id branchID = [branch objectForKey:@"branch_id"];
            if (branchID && branchID != [NSNull null]) {
                path = [path stringByAppendingFormat:@"&branch_id=%@", Escape([branchID description])];
            }
            error = nil;
            id data = Fetch(path, &error);
            if (![data isKindOfClass:[NSDictionary class]]) {
                break;
            }
            id restriction = [data objectForKey:@"restricted_view"];
            if ([restriction isKindOfClass:[NSDictionary class]] && ![[restriction objectForKey:@"is_open"] boolValue]) {
                [NSThread sleepForTimeInterval:0.3];
                continue;
            }
            id pages = [data objectForKey:@"pages"];
            if ([pages isKindOfClass:[NSArray class]] && [pages count]) {
                value = pages;
                break;
            }
        }
    } else {
        value = Fetch([task objectForKey:@"path"], &error);
        if (![value isKindOfClass:[NSArray class]]) {
            value = nil;
        }
    }
    NSString *message = error ? [error localizedDescription] : @"Нет данных: глава закрыта или формат не поддерживается";
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:task];
    [result setObject:(value ? value : message) forKey:(value ? @"value" : @"error")];
    [self performSelectorOnMainThread:@selector(finish:) withObject:result waitUntilDone:YES];
    [pool drain];
}

- (void)finish:(NSDictionary *)result {
    NSString *kind = [result objectForKey:@"kind"];
    if ([kind isEqual:@"download-chapter"]) {
        if (!_downloading || [[result objectForKey:@"download_generation"] unsignedIntegerValue] != _downloadGeneration) return;
        _downloadPreparing = NO;
        NSArray *pages = [result objectForKey:@"value"];
        NSMutableDictionary *entry = pages ? [_downloads prepare:_downloadManga chapter:[result objectForKey:@"chapter"] pages:pages] : nil;
        if (!entry) {
            [self stopChapterDownload]; _status.text = [result objectForKey:@"error"] ?: @"Не удалось сохранить главу. Проверь свободное место.";
            return;
        }
        [_downloadEntry release]; _downloadEntry = [entry retain];
        [self downloadNextPage]; return;
    }
    if ([kind isEqual:@"servers"]) {
        _serversLoading = NO;
        NSArray *servers = [result objectForKey:@"value"];
        if ([servers count]) {
            [_imageServers release];
            _imageServers = [servers copy];
            [[NSUserDefaults standardUserDefaults] setObject:servers forKey:@"MangaLib6ImageServers"];
        }
        if (_downloading) {
            if ([_imageServers count]) [self downloadNextPage];
            else { [self stopChapterDownload]; _status.text = @"Не удалось получить серверы. Нажми главу в «Загрузках», чтобы повторить."; }
            return;
        }
        if (_live && _screen == 2) {
            if ([_imageServers count]) {
                [self prefetchPages];
            } else {
                _status.text = [NSString stringWithFormat:@"Не удалось получить серверы: %@. Для повтора вернись к главам и открой главу снова.",
                    [result objectForKey:@"error"]];
            }
        }
        return;
    }
    if ([kind isEqual:@"image"]) {
        NSNumber *page = [result objectForKey:@"page_index"];
        NSInteger index = [page integerValue];
        if ([[result objectForKey:@"generation"] unsignedIntegerValue] != _readerGeneration ||
            !_live || _screen != 2 || _busy || index < [self bufferStart] || index >= [self bufferEnd]) {
            NSLog(@"MangaLib6 buffer discarded page %ld", (long)index + 1);
            [self prefetchPages];
            return;
        }
        UIImage *image = [result objectForKey:@"value"];
        if (image) {
            [_pageErrors removeObjectForKey:page];
            _pageImageEstimate = MAX(_pageImageEstimate, PageImageBytes(image));
            [_pageCache setObject:image forKey:page];
            [self trimPageBuffer];
            NSLog(@"MangaLib6 buffer stored page %ld: %lu/%ld", (long)index + 1,
                (unsigned long)[_pageCache count], (long)([self bufferEnd] - [self bufferStart]));
            NSLog(@"MangaLib6 page %ld download time: %.2f seconds", (long)index + 1,
                -[[result objectForKey:@"started_at"] timeIntervalSinceNow]);
            if (index == _pageIndex) {
                [self displayPageImage:image cacheHit:NO];
            } else {
                [self updatePageStatus];
            }
        } else {
            NSInteger retryCount = [[result objectForKey:@"retry_count"] integerValue] + 1;
            NSMutableDictionary *failure = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                [result objectForKey:@"error"], @"message", [NSNumber numberWithInteger:retryCount], @"retry_count", nil];
            if ([[result objectForKey:@"retryable"] boolValue] && retryCount <= PageRetryLimit) {
                [failure setObject:[NSDate dateWithTimeIntervalSinceNow:5 * retryCount] forKey:@"retry_at"];
                NSLog(@"MangaLib6 buffer retry page %ld: %ld/%ld in %ld seconds", (long)index + 1,
                    (long)retryCount, (long)PageRetryLimit, (long)5 * retryCount);
            }
            [_pageErrors setObject:failure forKey:page];
            NSLog(@"MangaLib6 buffer failed page %ld: %@", (long)index + 1, [result objectForKey:@"error"]);
            [self updatePageStatus];
            if (index == _pageIndex) {
                _smoke = NO;
            }
        }
        [self prefetchPages];
        return;
    }
    _busy = NO;
    [self updateResumeButton];
    if ([result objectForKey:@"error"]) {
        // Reading does not depend on optional title metadata being available.
        if ([kind isEqual:@"title"] && _resumeRequested) {
            [self openChapters];
            return;
        }
        _resumeRequested = NO;
        if (_screen == 2) {
            [self updatePageControls];
        }
        _status.text = [result objectForKey:@"error"];
        NSLog(@"MangaLib6 request failed: %@", _status.text);
        _smoke = NO;
        return;
    }
    id value = [result objectForKey:@"value"];
    if ([kind isEqual:@"title"]) {
        NSMutableDictionary *title = [NSMutableDictionary dictionaryWithDictionary:_mangaInfo];
        [title addEntriesFromDictionary:value];
        [_mangaInfo release];
        _mangaInfo = [title copy];
        _titleLoaded = YES;
        [self showInformation];
        if (_smoke || _resumeRequested) {
            [self openChapters];
        }
    } else if ([kind isEqual:@"catalog"] || [kind isEqual:@"chapters"]) {
        if ([kind isEqual:@"chapters"]) {
            [_chapters release];
            _chapters = [value copy];
        }
        [self setItems:value screen:[kind isEqual:@"catalog"] ? 0 : 1];
        _status.text = [NSString stringWithFormat:@"Прямой API: %lu %@", (unsigned long)[_items count],
            _screen == 0 ? @"результатов" : @"глав"];
        NSLog(@"MangaLib6 live %@: %lu items", kind, (unsigned long)[_items count]);
        if ([kind isEqual:@"chapters"] && _resumeRequested) {
            [self resumeSavedChapter];
        }
        if (_smoke) {
            NSDictionary *selected = nil;
            for (NSDictionary *item in _items) {
                if ([kind isEqual:@"catalog"] ?
                    [[item objectForKey:@"slug_url"] isEqual:[[_snapshot objectForKey:@"title"] objectForKey:@"slug_url"]] :
                    ([[item objectForKey:@"volume"] isEqual:[[_snapshot objectForKey:@"chapter"] objectForKey:@"volume"]] &&
                    [[item objectForKey:@"number"] isEqual:[[_snapshot objectForKey:@"chapter"] objectForKey:@"number"]])) {
                    selected = item;
                    break;
                }
            }
            if (selected && [kind isEqual:@"catalog"]) {
                [self openManga:selected];
            } else if (selected) {
                [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", selected, @"chapter", _slug, @"slug", nil]];
            } else {
                NSLog(@"MangaLib6 smoke live FAILED: snapshot selection not found");
                _smoke = NO;
            }
        }
    } else if ([kind isEqual:@"chapter"]) {
        if (_screen == 2) {
            [self animateContentInDirection:1];
        }
        [self resetPageBuffer];
        [_chapter release];
        _chapter = [[result objectForKey:@"chapter"] copy];
        [_pages release];
        _pages = [value copy];
        NSLog(@"MangaLib6 live chapter: %lu pages", (unsigned long)[_pages count]);
        _pageIndex = MIN(MAX((NSInteger)0, [[result objectForKey:@"resume_page"] integerValue]),
            MAX((NSInteger)0, (NSInteger)[_pages count] - 1));
        [self showPage];
    }
}

- (void)dealloc {
    [self stopChapterDownload];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_downloads release]; [_offlineChapter release]; [_downloadEntry release]; [_downloadManga release];
    [_readerInfo release];
    [self cancelResumeCoverDownload];
    [_resumePanel release];
    [_resumeName release];
    [_resumeDetails release];
    [_resumeCover release];
    [_resumeProgress release];
    [_resumeCoverSlug release];
    [self cancelImageDownload];
    [self cancelCoverDownload];
    [_infoView release];
    [_cover release];
    [_coverStatus release];
    [_mangaInfo release];
    [_catalog release];
    [_chapters release];
    [_chapter release];
    [_readingProgress release];
    [_searchHistory release];
    [_query release];
    [_status release];
    [_table release];
    [_contentView release];
    _pageView.delegate = nil;
    [_pageView release];
    [_image release];
    [_snapshot release];
    [_items release];
    [_pages release];
    [_pageCache release];
    [_pageErrors release];
    [_imageServers release];
    [_preferredImageServer release];
    [_slug release];
    [super dealloc];
}
@end

@interface MangaLib6AppDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
    MangaLib6Controller *_controller;
}
@end

@implementation MangaLib6AppDelegate
- (void)applicationWillResignActive:(UIApplication *)application {
    [_controller flushReadingProgress];
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    [_controller flushReadingProgress];
}
- (void)applicationWillTerminate:(UIApplication *)application {
    [_controller flushReadingProgress];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _controller = [[MangaLib6Controller alloc] init];
    _window.rootViewController = _controller;
    [_window makeKeyAndVisible];
    return YES;
}
- (void)dealloc {
    [_controller release];
    [_window release];
    [super dealloc];
}
@end

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int result = UIApplicationMain(argc, argv, nil, @"MangaLib6AppDelegate");
    [pool drain];
    return result;
}
