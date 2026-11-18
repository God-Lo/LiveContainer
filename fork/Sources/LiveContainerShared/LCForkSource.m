//
//  LCForkSource.m
//  LiveContainer (fork)
//

#import "LCForkSource.h"
#import "../../../LiveContainer/utils.h"

static NSString *const kAppId = @"com.kdt.livecontainer";
static NSString *const kDataKey = @"LCForkSourceData";
static NSString *const kETagKey = @"LCForkSourceETag";

@implementation LCForkSource

+ (NSURL *)sourceURL { return [NSURL URLWithString:@"https://raw.githubusercontent.com/God-Lo/LiveContainer/main/source.json"]; }
+ (NSURL *)apiURL { return [NSURL URLWithString:@"https://api.github.com/repos/God-Lo/LiveContainer/contents/source.json"]; }
+ (NSString *)passthroughHeader { return @"X-LC-Fork-Source"; }

+ (NSString *)installedBuild {
    return NSUserDefaults.lcMainBundle.infoDictionary[@"CFBundleVersion"] ?: @"0";
}

+ (NSComparisonResult)compareBuild:(NSString *)a to:(NSString *)b {
    NSArray<NSString *> *x = [a componentsSeparatedByString:@"."], *y = [b componentsSeparatedByString:@"."];
    for (NSUInteger i = 0; i < MAX(x.count, y.count); i++) {
        NSInteger l = i < x.count ? x[i].integerValue : 0, r = i < y.count ? y[i].integerValue : 0;
        if (l != r) return l > r ? NSOrderedDescending : NSOrderedAscending;
    }
    return NSOrderedSame;
}

static NSString *buildOf(NSDictionary *version) {
    id build = version[@"buildVersion"] ?: version[@"version"];
    return [build isKindOfClass:NSString.class] ? build : nil;
}

/// The source with LiveContainer's releases sorted newest first, or nil if it isn't a valid source.
+ (nullable NSData *)normalized:(NSData *)data {
    if (!data.length) return nil;
    NSMutableDictionary *json = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    NSMutableArray *apps = [json isKindOfClass:NSDictionary.class] ? json[@"apps"] : nil;
    if (![apps isKindOfClass:NSArray.class]) return nil;
    BOOL found = NO;
    for (NSMutableDictionary *app in apps) {
        if (![app isKindOfClass:NSDictionary.class] || ![app[@"bundleIdentifier"] isEqual:kAppId]) continue;
        NSArray *versions = [app[@"versions"] isKindOfClass:NSArray.class] ? app[@"versions"] : @[];
        NSMutableArray *valid = [NSMutableArray new];
        NSMutableSet *seen = [NSMutableSet new];
        for (NSDictionary *v in versions) {
            NSString *build = [v isKindOfClass:NSDictionary.class] ? buildOf(v) : nil;
            if (!build || ![v[@"downloadURL"] isKindOfClass:NSString.class] || [seen containsObject:build]) continue;
            [seen addObject:build];
            [valid addObject:v];
        }
        [valid sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [self compareBuild:buildOf(b) to:buildOf(a)];
        }];
        if (!valid.count) return nil;
        app[@"versions"] = valid;
        found = YES;
    }
    return found ? [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] : nil;
}

+ (NSDictionary<NSString *, NSString *> *)latestReleaseIn:(NSData *)data {
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    for (NSDictionary *app in json[@"apps"]) {
        if (![app isKindOfClass:NSDictionary.class] || ![app[@"bundleIdentifier"] isEqual:kAppId]) continue;
        NSDictionary *best = nil;
        for (NSDictionary *v in app[@"versions"]) {
            if (![v isKindOfClass:NSDictionary.class] || !buildOf(v) || ![v[@"downloadURL"] isKindOfClass:NSString.class]) continue;
            if (!best || [self compareBuild:buildOf(v) to:buildOf(best)] == NSOrderedDescending) best = v;
        }
        if (best) {
            return @{@"build": buildOf(best), @"downloadURL": best[@"downloadURL"],
                     @"notes": [best[@"localizedDescription"] isKindOfClass:NSString.class] ? best[@"localizedDescription"] : @""};
        }
    }
    return nil;
}

+ (NSData *)cachedData {
    NSData *data = [NSUserDefaults.lcSharedDefaults dataForKey:kDataKey];
    return [self latestReleaseIn:data] ? data : nil;
}

/// Keeps `data` and returns it. From the plain link (not `authoritative`), which can serve an older copy,
/// the kept copy wins when it has a newer release. The API always serves the current file, so it always
/// wins (a release removed from the source goes away).
+ (NSData *)keep:(NSData *)data etag:(nullable NSString *)etag authoritative:(BOOL)authoritative {
    NSData *cached = [self cachedData];
    NSString *newBuild = [self latestReleaseIn:data][@"build"], *oldBuild = [self latestReleaseIn:cached][@"build"];
    if (!authoritative && cached && [self compareBuild:newBuild to:oldBuild] == NSOrderedAscending) return cached;
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;
    [defaults setObject:data forKey:kDataKey];
    if (etag) [defaults setObject:etag forKey:kETagKey]; else [defaults removeObjectForKey:kETagKey];
    return data;
}

+ (NSMutableURLRequest *)requestFor:(NSURL *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:20];
    [request setValue:@"1" forHTTPHeaderField:self.passthroughHeader];
    return request;
}

+ (void)fetchWithCompletion:(void (^)(NSData *, NSError *))completion {
    NSURLSession *session = NSURLSession.sharedSession;
    NSMutableURLRequest *api = [self requestFor:self.apiURL];
    [api setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];
    NSString *etag = [NSUserDefaults.lcSharedDefaults stringForKey:kETagKey];
    if (etag && [self cachedData]) [api setValue:etag forHTTPHeaderField:@"If-None-Match"];
    [[session dataTaskWithRequest:api completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode == 304 && [self cachedData]) {
            completion([self cachedData], nil);
            return;
        }
        NSData *normalized = http.statusCode == 200 ? [self normalized:data] : nil;
        if (normalized) {
            completion([self keep:normalized etag:http.allHeaderFields[@"ETag"] authoritative:YES], nil);
            return;
        }
        // API unavailable (rate limit or network): the plain link, which can lag a few minutes.
        [[session dataTaskWithRequest:[self requestFor:self.sourceURL] completionHandler:^(NSData *rawData, NSURLResponse *rawResponse, NSError *rawError) {
            NSData *raw = [self normalized:rawData];
            if (raw) {
                // No ETag: the next check asks the API again.
                completion([self keep:raw etag:nil authoritative:NO], nil);
            } else if ([self cachedData]) {
                completion([self cachedData], nil);
            } else {
                completion(nil, rawError ?: error ?: [NSError errorWithDomain:@"LCForkSource" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read the update source."}]);
            }
        }] resume];
    }] resume];
}

@end
