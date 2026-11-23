#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>

static const NSInteger PageBufferSize = 5;
static const NSInteger PageHistorySize = 2;
static const NSInteger PageRetryLimit = 2;
static const NSTimeInterval ImageRequestTimeout = 8;

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

@interface MangaLib6Controller : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate, NSURLConnectionDataDelegate> {
    UITextField *_query;
    UILabel *_status;
    UIButton *_previous;
    UIButton *_next;
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
}
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
    _pageCache = [[NSMutableDictionary alloc] init];
    _pageErrors = [[NSMutableDictionary alloc] init];
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
    _query.text = @"chainsaw";
    _query.placeholder = @"Поиск манги";
    _query.delegate = self;
    _query.returnKeyType = UIReturnKeySearch;
    [self.view addSubview:_query];
    [self button:@"Поиск" action:@selector(search) frame:CGRectMake(width - 104, headerHeight + 12, 92, 36)];
    [self button:@"Назад" action:@selector(goBack) frame:CGRectMake(12, headerHeight + 56, 80, 36)];
    _status = [[UILabel alloc] initWithFrame:CGRectMake(12, headerHeight + 100, width - 24, 64)];
    _status.numberOfLines = 3;
    _status.font = [UIFont systemFontOfSize:15];
    _status.backgroundColor = [UIColor clearColor];
    _status.textColor = ThemeSecondaryText();
    [self.view addSubview:_status];
    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, contentTop, width, height - contentTop) style:UITableViewStylePlain];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = ThemeSurface();
    _table.separatorColor = ThemeBorder();
    [self.view addSubview:_table];
    _infoView = [[UIScrollView alloc] initWithFrame:_table.frame];
    _infoView.backgroundColor = ThemeBackground();
    _infoView.hidden = YES;
    [self.view addSubview:_infoView];
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
    _pageView = [[UIScrollView alloc] initWithFrame:CGRectMake(0, contentTop, width, height - contentTop - 60)];
    _pageView.delegate = self;
    _pageView.backgroundColor = [UIColor colorWithRed:0.15 green:0.08 blue:0.04 alpha:1];
    _pageView.minimumZoomScale = 1;
    _pageView.maximumZoomScale = 4;
    _pageView.hidden = YES;
    [self.view addSubview:_pageView];
    _image = [[UIImageView alloc] initWithFrame:_pageView.bounds];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    [_pageView addSubview:_image];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoomPage:)];
    doubleTap.numberOfTapsRequired = 2;
    [_pageView addGestureRecognizer:doubleTap];
    [doubleTap release];
    UIPanGestureRecognizer *pageSwipe = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(swipePage:)];
    pageSwipe.maximumNumberOfTouches = 1;
    pageSwipe.delegate = self;
    [_pageView addGestureRecognizer:pageSwipe];
    [pageSwipe release];
    _previous = [self button:@"< Страница" action:@selector(previousPage) frame:CGRectMake(12, height - 48, 140, 36)];
    _next = [self button:@"Страница >" action:@selector(nextPage) frame:CGRectMake(width - 152, height - 48, 140, 36)];
    _next.titleLabel.adjustsFontSizeToFitWidth = YES;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"snapshot" ofType:@"plist"];
    id snapshot = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([snapshot isKindOfClass:[NSDictionary class]]) {
        _snapshot = [snapshot retain];
        id query = [_snapshot objectForKey:@"query"];
        if ([query isKindOfClass:[NSString class]] && [query length]) {
            _query.text = query;
        }
        NSLog(@"MangaLib6 snapshot loaded: %@", [_snapshot objectForKey:@"captured_at"]);
    } else {
        NSLog(@"MangaLib6 no snapshot");
    }
    BOOL smokeTest = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"MangaLib6SmokeTest"] boolValue];
    _live = !smokeTest;
    [self search];
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

- (void)animateAppearance:(UIView *)view {
    if (_smoke || !view.window || view.hidden) {
        return;
    }
    CATransition *transition = [CATransition animation];
    transition.type = kCATransitionFade;
    transition.duration = 0.18;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [view.layer addAnimation:transition forKey:@"appearance"];
}

- (void)setPageImage:(UIImage *)image {
    if (!image) {
        [_pageView.layer removeAnimationForKey:@"pageTransition"];
    }
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
    BOOL slide = _pageDirection != 0 && _image.image != nil;
    BOOL animate = image && image != _image.image && !_smoke && !_lowMemory && _pageView.window;
    [self setPageImage:image];
    if (animate) {
        CATransition *transition = [CATransition animation];
        transition.type = slide ? kCATransitionPush : kCATransitionFade;
        if (slide) {
            transition.subtype = _pageDirection > 0 ? kCATransitionFromRight : kCATransitionFromLeft;
        }
        transition.duration = slide ? 0.22 : 0.18;
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_pageView.layer addAnimation:transition forKey:@"pageTransition"];
    }
    _pageDirection = 0;
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
    [self resetPageBuffer];
    [self cancelCoverDownload];
    NSArray *replacement = [items copy];
    [_items release];
    _items = replacement;
    [_chapter release];
    _chapter = nil;
    _screen = screen;
    if (screen == 0) {
        [_catalog release];
        _catalog = [_items copy];
        [_mangaInfo release];
        _mangaInfo = nil;
        [_chapters release];
        _chapters = nil;
        _cover.image = nil;
        _titleLoaded = NO;
    }
    _table.hidden = NO;
    _infoView.hidden = YES;
    _pageView.hidden = YES;
    [self setPageImage:nil];
    _previous.hidden = YES;
    _next.hidden = YES;
    [_table reloadData];
    [self animateAppearance:_table];
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
    [self resetPageBuffer];
    _screen = 3;
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
    [self animateAppearance:_infoView];
}

- (void)openManga:(NSDictionary *)item {
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
    } else {
        NSString *path = [NSString stringWithFormat:@"/manga/%@/chapters", Escape(_slug)];
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapters", @"kind", path, @"path", nil]];
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
    _busy = YES;
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
    [self resetPageBuffer];
    [_query resignFirstResponder];
    if (_live) {
        NSString *path = [NSString stringWithFormat:@"/manga?site_id%%5B%%5D=1&q=%@&per_page=20", Escape(_query.text)];
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"catalog", @"kind", path, @"path", nil]];
    } else {
        [self setItems:[_snapshot objectForKey:@"catalog"] screen:0];
        _status.text = _snapshot ? [NSString stringWithFormat:@"Снимок реального API: %@. Открывается выбранная манга и одна глава; это не живая сеть.",
            [_snapshot objectForKey:@"query"]] : @"Нет снимка: запусти fetch_snapshot.py и пересобери IPA.";
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self search];
    return YES;
}

- (void)goBack {
    if (!_busy) {
        if (_screen == 2) {
            [self setItems:_items screen:1];
            _status.text = @"Выбери главу";
        } else if (_screen == 1) {
            [self showInformation];
        } else if (_screen == 3) {
            [self setItems:_catalog screen:0];
            _status.text = @"Выбери мангу";
        } else {
            [self search];
        }
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_items count];
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
    NSDictionary *item = [_items objectAtIndex:indexPath.row];
    cell.textLabel.text = _screen == 0 ? Name(item) : [NSString stringWithFormat:@"Том %@, глава %@ — %@",
        [item objectForKey:@"volume"], [item objectForKey:@"number"], Name(item)];
    if (_screen == 0) {
        cell.detailTextLabel.text = [item objectForKey:@"slug_url"];
    } else {
        NSString *date = ChapterPublicationDate(item);
        cell.detailTextLabel.text = [date length] ? [NSString stringWithFormat:@"Опубликована: %@", date] : @"Дата публикации не указана";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_busy) {
        return;
    }
    NSDictionary *item = [_items objectAtIndex:indexPath.row];
    if (_screen == 0) {
        if (!_live && ![[item objectForKey:@"slug_url"] isEqual:[[_snapshot objectForKey:@"title"] objectForKey:@"slug_url"]]) {
            _status.text = [NSString stringWithFormat:@"Для этой манги нет снимка. Выбери %@.", Name([_snapshot objectForKey:@"title"])];
            return;
        }
        [self openManga:item];
    } else if (_live) {
        [self start:[NSDictionary dictionaryWithObjectsAndKeys:@"chapter", @"kind", item, @"chapter", _slug, @"slug", nil]];
    } else {
        [self resetPageBuffer];
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
    _screen = 2;
    [self cancelCoverDownload];
    _infoView.hidden = YES;
    _table.hidden = YES;
    _pageView.hidden = NO;
    _previous.hidden = NO;
    _next.hidden = NO;
    [self updatePageControls];
    NSString *pagePath = [[_pages objectAtIndex:_pageIndex] objectForKey:@"url"];
    if (_live) {
        _lowMemory = NO;
        [self trimPageBuffer];
        NSNumber *page = [NSNumber numberWithInteger:_pageIndex];
        [_pageErrors removeObjectForKey:page];
        UIImage *image = [_pageCache objectForKey:page];
        if (image) {
            [self displayPageImage:image cacheHit:YES];
        } else {
            [self setPageImage:nil];
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
        _status.text = _image.image ? [NSString stringWithFormat:@"Снимок: страница %ld/%lu (в главе %@)",
            (long)_pageIndex + 1, (unsigned long)[_pages count], [_snapshot objectForKey:@"total_pages"]] : @"Картинка не найдена";
        NSLog(@"MangaLib6 snapshot page %ld: %@ decoded=%@", (long)_pageIndex + 1, filename, _image.image ? @"YES" : @"NO");
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
}

- (void)previousPage {
    if (!_busy && _pageIndex > 0) {
        _pageDirection = -1;
        _pageIndex--;
        [self showPage];
    }
}

- (void)resetPageBuffer {
    _readerGeneration++;
    _pageDirection = 0;
    [self cancelImageDownload];
    _lowMemory = NO;
    [_pageCache removeAllObjects];
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
}

- (void)displayPageImage:(UIImage *)image cacheHit:(BOOL)cacheHit {
    [self transitionToPageImage:image];
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
    if (!_live || _screen != 2 || _busy || _imageTask) {
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
    [_pageView.layer removeAnimationForKey:@"pageTransition"];
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
    if (connection == _coverConnection) {
        [_coverData appendData:data];
        return;
    }
    if (connection == _imageConnection) {
        [_imageData appendData:data];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
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
    UIImage *image = [UIImage imageWithData:_imageData];
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
    } else if ([kind isEqual:@"chapter"]) {
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
    if ([kind isEqual:@"servers"]) {
        _serversLoading = NO;
        NSArray *servers = [result objectForKey:@"value"];
        if ([servers count]) {
            [_imageServers release];
            _imageServers = [servers copy];
            [[NSUserDefaults standardUserDefaults] setObject:servers forKey:@"MangaLib6ImageServers"];
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
            [_pageCache setObject:image forKey:page];
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
    if ([result objectForKey:@"error"]) {
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
        if (_smoke) {
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
        [self resetPageBuffer];
        [_chapter release];
        _chapter = [[result objectForKey:@"chapter"] copy];
        [_pages release];
        _pages = [value copy];
        NSLog(@"MangaLib6 live chapter: %lu pages", (unsigned long)[_pages count]);
        _pageIndex = 0;
        [self showPage];
    }
}

- (void)dealloc {
    [self cancelImageDownload];
    [self cancelCoverDownload];
    [_infoView release];
    [_cover release];
    [_coverStatus release];
    [_mangaInfo release];
    [_catalog release];
    [_chapters release];
    [_chapter release];
    [_query release];
    [_status release];
    [_table release];
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
