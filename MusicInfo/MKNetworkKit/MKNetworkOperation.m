//
//  MKNetworkOperation.m
//  MKNetworkKit
//
//  Created by Mugunth Kumar (@mugunthkumar) on 11/11/11.
//  Copyright (C) 2011-2020 by Steinlogic

//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "MKNetworkOperation.h"
#import "NSDictionary+RequestEncoding.h"
#import "NSString+MKNetworkKitAdditions.h"


// Should there be a cancelled state? or something similar.
typedef enum {
    MKNetworkOperationStateReady = 1,
    MKNetworkOperationStateExecuting = 2,
    MKNetworkOperationStateFinished = 3
} MKNetworkOperationState;

@interface MKNetworkOperation (/*Private Methods*/)
@property (strong, nonatomic) NSURLConnection *connection;
@property (strong, nonatomic) NSString *uniqueId;
@property (strong, nonatomic) NSMutableURLRequest *request;
@property (strong, nonatomic) NSHTTPURLResponse *response;

@property (strong, nonatomic) NSMutableDictionary *fieldsToBePosted;
@property (strong, nonatomic) NSMutableArray *filesToBePosted;
@property (strong, nonatomic) NSMutableArray *dataToBePosted;

@property (strong, nonatomic) NSString *username;
@property (strong, nonatomic) NSString *password;

@property (nonatomic, retain) NSMutableArray *responseBlocks;
@property (nonatomic, retain) NSMutableArray *errorBlocks;

@property (nonatomic, assign) MKNetworkOperationState state;
@property (nonatomic, assign) BOOL isCancelled;

@property (strong, nonatomic) NSMutableData *mutableData;

@property (nonatomic, retain) NSMutableArray *uploadProgressChangedHandlers;
@property (nonatomic, retain) NSMutableArray *downloadProgressChangedHandlers;
@property (nonatomic, retain) NSMutableArray *downloadStreams;
@property (nonatomic, retain) NSData *cachedResponse;
@property (nonatomic, copy) MKNKResponseBlock cacheHandlingBlock;
#if TARGET_OS_IPHONE    
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTaskId;
#endif

@property (strong, nonatomic) NSError *error;

- (id)initWithURLString:(NSString *)aURLString
                 params:(NSMutableDictionary *)body
             httpMethod:(NSString *)method;

-(NSData*) bodyData;
-(BOOL) isCacheable;

@end

@implementation MKNetworkOperation

@synthesize stringEncoding = _stringEncoding;
@dynamic freezable;
@synthesize uniqueId = _uniqueId; // freezable operations have a unique id

@synthesize connection = _connection;

@synthesize request = _request;
@synthesize response = _response;

@synthesize fieldsToBePosted = _fieldsToBePosted;
@synthesize filesToBePosted = _filesToBePosted;
@synthesize dataToBePosted = _dataToBePosted;

@synthesize username = _username;
@synthesize password = _password;
@synthesize clientCertificate = _clientCertificate;
@synthesize authHandler = _authHandler;

@synthesize responseBlocks = _responseBlocks;
@synthesize errorBlocks = _errorBlocks;

@synthesize isCancelled = _isCancelled;
@synthesize mutableData = _mutableData;

@synthesize uploadProgressChangedHandlers = _uploadProgressChangedHandlers;
@synthesize downloadProgressChangedHandlers = _downloadProgressChangedHandlers;

@synthesize downloadStreams = _downloadStreams;

@synthesize cachedResponse = _cachedResponse;
@synthesize cacheHandlingBlock = _cacheHandlingBlock;

#if TARGET_OS_IPHONE    
@synthesize backgroundTaskId = _backgroundTaskId;
#endif

@synthesize cacheHeaders = _cacheHeaders;
@synthesize error = _error;


// A RESTful service should always return the same response for a given URL and it's parameters.
// this means if these values are correct, you can cache the responses
// This is another reason why we check only GET methods.
// even if URL and others are same, POST, DELETE, PUT methods should not be cached and should not be treated equal.

-(BOOL) isCacheable {
    
    return [self.request.HTTPMethod isEqualToString:@"GET"];
}

//=========================================================== 
//  freezable 
//=========================================================== 
- (BOOL)freezable
{
    return _freezable;
}

-(NSString*) url {
    
    return [[self.request URL] absoluteString];
}

-(NSMutableURLRequest*) readonlyRequest {
    
    return [self.request copy];
}

-(NSHTTPURLResponse*) readonlyResponse {
    
    return [self.response copy];
}

- (void)setFreezable:(BOOL)flag
{
    // get method cannot be frozen. 
    // No point in freezing a method that doesn't change server state.
    if([self.request.HTTPMethod isEqualToString:@"GET"] && flag) return;
    _freezable = flag;
    
    if(_freezable && self.uniqueId == nil)
        self.uniqueId = [NSString uniqueString];
}


-(BOOL) isEqual:(id)object {
    
    if([self isCacheable]) {
        
        MKNetworkOperation *anotherObject = (MKNetworkOperation*) object;
        return ([[self uniqueIdentifier] isEqualToString:[anotherObject uniqueIdentifier]]);
    }
    
    return NO;
}


-(NSString*) uniqueIdentifier {
    
    NSString *str = [self curlCommandLineString];
    
    if(self.username || self.password) {
        
        str = [str stringByAppendingFormat:@" [%@:%@]",
               self.username ? self.username : @"",
               self.password ? self.password : @""];
    }
    
    if(self.freezable) {
        
        str = [str stringByAppendingString:self.uniqueId];
    }
    return [str md5];
}

-(BOOL) isCachedResponse {
    
    return self.cachedResponse != nil;
}

-(void) notifyCache {
    
    if(![self isCacheable]) return;
    if(!([self.response statusCode] >= 200 && [self.response statusCode] < 300)) return;
    
    self.cacheHandlingBlock(self);
}

-(MKNetworkOperationState) state {
    
    return _state;
}

-(void) setState:(MKNetworkOperationState)newState {
    
    switch (newState) {
        case MKNetworkOperationStateReady:
            [self willChangeValueForKey:@"isReady"];
            break;
        case MKNetworkOperationStateExecuting:
            [self willChangeValueForKey:@"isReady"];
            [self willChangeValueForKey:@"isExecuting"];
            break;
        case MKNetworkOperationStateFinished:
            [self willChangeValueForKey:@"isExecuting"];
            [self willChangeValueForKey:@"isFinished"];
            break;
    }
    
    _state = newState;
    
    switch (newState) {
        case MKNetworkOperationStateReady:
            [self didChangeValueForKey:@"isReady"];
            break;
        case MKNetworkOperationStateExecuting:
            [self didChangeValueForKey:@"isReady"];
            [self didChangeValueForKey:@"isExecuting"];
            break;
        case MKNetworkOperationStateFinished:
            [self didChangeValueForKey:@"isExecuting"];
            [self didChangeValueForKey:@"isFinished"];
#if TARGET_OS_IPHONE                
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskId];
                    self.backgroundTaskId = UIBackgroundTaskInvalid;
                }
            });
#endif        
            break;
    }
}

- (void)encodeWithCoder:(NSCoder *)encoder 
{
    [encoder encodeInteger:self.stringEncoding forKey:@"stringEncoding"];
    [encoder encodeObject:self.uniqueId forKey:@"uniqueId"];
    [encoder encodeObject:self.request forKey:@"request"];
    [encoder encodeObject:self.response forKey:@"response"];
    [encoder encodeObject:self.fieldsToBePosted forKey:@"fieldsToBePosted"];
    [encoder encodeObject:self.filesToBePosted forKey:@"filesToBePosted"];
    [encoder encodeObject:self.dataToBePosted forKey:@"dataToBePosted"];
    [encoder encodeObject:self.username forKey:@"username"];
    [encoder encodeObject:self.password forKey:@"password"];
    [encoder encodeObject:self.clientCertificate forKey:@"clientCertificate"];
    
    self.state = MKNetworkOperationStateReady;
    [encoder encodeInt32:_state forKey:@"state"];
    [encoder encodeBool:self.isCancelled forKey:@"isCancelled"];
    [encoder encodeObject:self.mutableData forKey:@"mutableData"];
    
    [encoder encodeObject:self.downloadStreams forKey:@"downloadStreams"];
}

- (id)initWithCoder:(NSCoder *)decoder 
{
    self = [super init];
    if (self) {
        [self setStringEncoding:[decoder decodeIntegerForKey:@"stringEncoding"]];
        self.request = [decoder decodeObjectForKey:@"request"];
        self.uniqueId = [decoder decodeObjectForKey:@"uniqueId"];
        
        self.response = [decoder decodeObjectForKey:@"response"];
        self.fieldsToBePosted = [decoder decodeObjectForKey:@"fieldsToBePosted"];
        self.filesToBePosted = [decoder decodeObjectForKey:@"filesToBePosted"];
        self.dataToBePosted = [decoder decodeObjectForKey:@"dataToBePosted"];
        self.username = [decoder decodeObjectForKey:@"username"];
        self.password = [decoder decodeObjectForKey:@"password"];
        self.clientCertificate = [decoder decodeObjectForKey:@"clientCertificate"];
        [self setState:[decoder decodeInt32ForKey:@"state"]];
        self.isCancelled = [decoder decodeBoolForKey:@"isCancelled"];
        self.mutableData = [decoder decodeObjectForKey:@"mutableData"];
        
        self.downloadStreams = [decoder decodeObjectForKey:@"downloadStreams"];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    MKNetworkOperation *theCopy = [[[self class] allocWithZone:zone] init];  // use designated initializer
    
    [theCopy setStringEncoding:self.stringEncoding];
    [theCopy setUniqueId:[self.uniqueId copy]];
    
    [theCopy setConnection:[self.connection copy]];
    [theCopy setRequest:[self.request copy]];
    [theCopy setResponse:[self.response copy]];
    [theCopy setFieldsToBePosted:[self.fieldsToBePosted copy]];
    [theCopy setFilesToBePosted:[self.filesToBePosted copy]];
    [theCopy setDataToBePosted:[self.dataToBePosted copy]];
    [theCopy setUsername:[self.username copy]];
    [theCopy setPassword:[self.password copy]];
    [theCopy setClientCertificate:[self.clientCertificate copy]];
    [theCopy setResponseBlocks:[self.responseBlocks copy]];
    [theCopy setErrorBlocks:[self.errorBlocks copy]];
    [theCopy setState:self.state];
    [theCopy setIsCancelled:self.isCancelled];
    [theCopy setMutableData:[self.mutableData copy]];
    [theCopy setUploadProgressChangedHandlers:[self.uploadProgressChangedHandlers copy]];
    [theCopy setDownloadProgressChangedHandlers:[self.downloadProgressChangedHandlers copy]];
    [theCopy setDownloadStreams:[self.downloadStreams copy]];
    [theCopy setCachedResponse:[self.cachedResponse copy]];
    [theCopy setCacheHandlingBlock:self.cacheHandlingBlock];
    
    return theCopy;
}

-(void) dealloc {
    
    [_connection cancel];
    _connection = nil;
}

-(void) updateHandlersFromOperation:(MKNetworkOperation*) operation {
    
    [self.responseBlocks addObjectsFromArray:operation.responseBlocks];
    [self.errorBlocks addObjectsFromArray:operation.errorBlocks];
    [self.uploadProgressChangedHandlers addObjectsFromArray:operation.uploadProgressChangedHandlers];
    [self.downloadProgressChangedHandlers addObjectsFromArray:operation.downloadProgressChangedHandlers];
    [self.downloadStreams addObjectsFromArray:operation.downloadStreams];
}

-(void) setCachedData:(NSData*) cachedData {
    
    self.cachedResponse = cachedData;    
    [self operationSucceeded];
}

-(void) updateOperationBasedOnPreviousHeaders:(NSMutableDictionary*) headers {
    
    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    NSString *eTag = [headers objectForKey:@"ETag"];
    
    if(lastModified) {
        [self.request setHTTPMethod:@"HEAD"];
        [self.request addValue:lastModified forHTTPHeaderField:@"IF-MODIFIED-SINCE"];
    }
    
    if(eTag) {
        [self.request setHTTPMethod:@"HEAD"];
        [self.request addValue:eTag forHTTPHeaderField:@"IF-NONE-MATCH"];
    }    
}

-(void) setUsername:(NSString*) username password:(NSString*) password {
    
    self.username = username;
    self.password = password;
}

-(void) onCompletion:(MKNKResponseBlock) response onError:(MKNKErrorBlock) error {
    
    [self.responseBlocks addObject:[response copy]];
    [self.errorBlocks addObject:[error copy]];
}

-(void) onUploadProgressChanged:(MKNKProgressBlock) uploadProgressBlock {
    
    [self.uploadProgressChangedHandlers addObject:[uploadProgressBlock copy]];
}

-(void) onDownloadProgressChanged:(MKNKProgressBlock) downloadProgressBlock {
    
    [self.downloadProgressChangedHandlers addObject:[downloadProgressBlock copy]];
}

-(void) setDownloadStream:(NSOutputStream*) outputStream {
    
    [self.downloadStreams addObject:outputStream];
}

- (id)initWithURLString:(NSString *)aURLString
                 params:(NSMutableDictionary *)params
             httpMethod:(NSString *)method

{	
    if((self = [super init])) {
        
        self.responseBlocks = [NSMutableArray array];
        self.errorBlocks = [NSMutableArray array];        
        
        self.filesToBePosted = [NSMutableArray array];
        self.dataToBePosted = [NSMutableArray array];
        self.fieldsToBePosted = [NSMutableArray array];
        
        self.uploadProgressChangedHandlers = [NSMutableArray array];
        self.downloadProgressChangedHandlers = [NSMutableArray array];
        self.downloadStreams = [NSMutableArray array];
        
        NSURL *finalURL = nil;
        
        if(params)
            self.fieldsToBePosted = params;
        
        self.stringEncoding = NSUTF8StringEncoding; // use a delegate to get these values later
        
        if ([method isEqualToString:@"GET"])
            self.cacheHeaders = [NSMutableDictionary dictionary];
        
        if (([method isEqualToString:@"GET"] ||
             [method isEqualToString:@"DELETE"]) && (params && [params count] > 0)) {
            
            finalURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", aURLString, 
                                             [params urlEncodedKeyValueString]]];
        } else {
            finalURL = [NSURL URLWithString:aURLString];
        }
        
        // if your server takes longer than 30 seconds to provide real data,
        // you should hire a better server developer.
        // on iOS (or any mobile device), 30 seconds is already considered high.
        
        self.request = [NSMutableURLRequest requestWithURL:finalURL                                                           
                                               cachePolicy:NSURLRequestUseProtocolCachePolicy                                            
                                           timeoutInterval:30.0f];
        
        [self.request setHTTPMethod:method];
        
        NSString *charset = (__bridge NSString *)CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(self.stringEncoding));
        
        [self.request addValue:[NSString stringWithFormat:@"%@, en-us", 
                                [[NSLocale preferredLanguages] componentsJoinedByString:@", "]
                                ] forHTTPHeaderField:@"Accept-Language"];
        
        if (([method isEqualToString:@"POST"] ||
             [method isEqualToString:@"PUT"]) && (params && [params count] > 0)) {
            
            [self.request addValue:
             [NSString stringWithFormat:@"application/x-www-form-urlencoded; charset=%@", charset]
                forHTTPHeaderField:@"Content-Type"];
        }
        
        self.state = MKNetworkOperationStateReady;
    }
    
	return self;
}

-(void) addHeaders:(NSDictionary*) headersDictionary {
    
    [headersDictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        [self.request addValue:obj forHTTPHeaderField:key];
    }];
}

/*
 Printing a MKNetworkOperation object is printed in curl syntax
 */

-(NSString*) description {
    
    NSMutableString *displayString = [NSMutableString stringWithFormat:@"%@\nRequest\n-------\n%@", 
                                      [[NSDate date] descriptionWithLocale:[NSLocale currentLocale]],
                                      [self curlCommandLineString]];
    
    NSString *responseString = [self responseString];    
    if([responseString length] > 0) {
        [displayString appendFormat:@"\n--------\nResponse\n--------\n%@\n", responseString];
    }
    
    return displayString;
}

-(NSString*) curlCommandLineString
{
    __block NSMutableString *displayString = [NSMutableString stringWithFormat:@"curl -X %@", self.request.HTTPMethod];
    
    if([self.filesToBePosted count] == 0 && [self.dataToBePosted count] == 0) {
        [[self.request allHTTPHeaderFields] enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop)
         {
             [displayString appendFormat:@" -H \"%@: %@\"", key, val];
         }];
    }
    
    [displayString appendFormat:@" \"%@\"",  self.url];
    
    if ([self.request.HTTPMethod isEqualToString:@"POST"] || [self.request.HTTPMethod isEqualToString:@"PUT"]) {
        
        NSString *option = [self.filesToBePosted count] == 0 ? @"-d" : @"-F";
        [self.fieldsToBePosted enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            
            [displayString appendFormat:@" %@ \"%@=%@\"", option, key, obj];    
        }];
        
        [self.filesToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            
            NSDictionary *thisFile = (NSDictionary*) obj;
            [displayString appendFormat:@" -F \"%@=@%@;type=%@\"", [thisFile objectForKey:@"name"],
             [thisFile objectForKey:@"filepath"], [thisFile objectForKey:@"mimetype"]];
        }];
        
        /* Not sure how to do this via curl
         [self.dataToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
         
         NSDictionary *thisData = (NSDictionary*) obj;
         [displayString appendFormat:@" --data-binary \"%@\"", [thisData objectForKey:@"data"]];
         }];*/
    }
    
    return displayString;
}


-(void) addData:(NSData*) data forKey:(NSString*) key {
    
    [self addData:data forKey:key mimeType:@"application/octet-stream"];
}

-(void) addData:(NSData*) data forKey:(NSString*) key mimeType:(NSString*) mimeType {
    
    [self.request setHTTPMethod:@"POST"];
    
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          data, @"data",
                          key, @"name",
                          mimeType, @"mimetype",     
                          nil];
    
    [self.dataToBePosted addObject:dict];    
}

-(void) addFile:(NSString*) filePath forKey:(NSString*) key {
    
    [self addFile:filePath forKey:key mimeType:@"application/octet-stream"];
}

-(void) addFile:(NSString*) filePath forKey:(NSString*) key mimeType:(NSString*) mimeType {
    
    [self.request setHTTPMethod:@"POST"];
    
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          filePath, @"filepath",
                          key, @"name",
                          mimeType, @"mimetype",     
                          nil];
    
    [self.filesToBePosted addObject:dict];    
}

-(NSData*) bodyData {
    
    
    if([self.filesToBePosted count] == 0 && [self.dataToBePosted count] == 0) {
        
        return [[[self.fieldsToBePosted urlEncodedKeyValueString] dataUsingEncoding:self.stringEncoding] mutableCopy];
    }
    
    NSString *boundary = @"0xKhTmLbOuNdArY";
    NSMutableData *body = [NSMutableData data];
    __block NSUInteger postLength = 0;    
    
    [self.fieldsToBePosted enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        
        NSString *thisFieldString = [NSString stringWithFormat:
                                     @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
                                     boundary, [key urlEncodedString], [obj urlEncodedString]];
        
        [body appendData:[thisFieldString dataUsingEncoding:[self stringEncoding]]];
    }];        
    
    [self.filesToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        
        NSDictionary *thisFile = (NSDictionary*) obj;
        NSString *thisFieldString = [NSString stringWithFormat:
                                     @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: %@\r\nContent-Transfer-Encoding: binary\r\n\r\n",
                                     boundary, 
                                     [thisFile objectForKey:@"name"], 
                                     [[thisFile objectForKey:@"filepath"] lastPathComponent], 
                                     [thisFile objectForKey:@"mimetype"]];
        
        [body appendData:[thisFieldString dataUsingEncoding:[self stringEncoding]]];         
        [body appendData: [NSData dataWithContentsOfFile:[thisFile objectForKey:@"filepath"]]];
    }];
    
    [self.dataToBePosted enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        
        NSDictionary *thisDataObject = (NSDictionary*) obj;
        NSString *thisFieldString = [NSString stringWithFormat:
                                     @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\nContent-Type: %@\r\nContent-Transfer-Encoding: binary\r\n\r\n",
                                     boundary, 
                                     [thisDataObject objectForKey:@"name"], 
                                     [thisDataObject objectForKey:@"name"], 
                                     [thisDataObject objectForKey:@"mimetype"]];
        
        [body appendData:[thisFieldString dataUsingEncoding:[self stringEncoding]]];         
        [body appendData:[thisDataObject objectForKey:@"data"]];
    }];
    
    if (postLength >= 1)
        [self.request setValue:[NSString stringWithFormat:@"%lu", postLength] forHTTPHeaderField:@"content-length"];
    
    [body appendData: [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:self.stringEncoding]];
    
    NSString *charset = (__bridge NSString *)CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(self.stringEncoding));
    
    if(([self.filesToBePosted count] > 0) || ([self.dataToBePosted count] > 0)) {
        [self.request setValue:[NSString stringWithFormat:@"multipart/form-data; charset=%@; boundary=%@", charset, boundary] 
            forHTTPHeaderField:@"Content-Type"];
        
        [self.request setValue:[NSString stringWithFormat:@"%d", [body length]] forHTTPHeaderField:@"Content-Length"];
    }
    
    return body;
}

-(void) setCacheHandler:(MKNKResponseBlock) cacheHandler {
    
    self.cacheHandlingBlock = cacheHandler;
}

#pragma mark -
#pragma Main method
-(void) main {
    
    @autoreleasepool {
        [self start];
    }
}

- (void) start
{
    
#if TARGET_OS_IPHONE
    self.backgroundTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.backgroundTaskId != UIBackgroundTaskInvalid)
            {
                [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskId];
                self.backgroundTaskId = UIBackgroundTaskInvalid;
                [self cancel];
            }
        });
    }];
    
#endif
    
    if(![NSThread isMainThread]){
        [self performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
        return;
    }
    if(!self.isCancelled) {
        
        if ([self.request.HTTPMethod isEqualToString:@"POST"] || [self.request.HTTPMethod isEqualToString:@"PUT"]) {            
            
            [self.request setHTTPBody:[self bodyData]];
        }
        
        DLog(@"%@", self);
        self.connection = [[NSURLConnection alloc] initWithRequest:self.request 
                                                          delegate:self 
                                                  startImmediately:YES]; 
        self.state = MKNetworkOperationStateExecuting;
    }
    else {
        self.state = MKNetworkOperationStateFinished;
    }
}

#pragma -
#pragma mark NSOperation stuff

- (BOOL)isConcurrent
{
    return YES;
}

- (BOOL)isReady {
    
    return (self.state == MKNetworkOperationStateReady);
}

- (BOOL)isFinished 
{
	return (self.state == MKNetworkOperationStateFinished);
}

- (BOOL)isExecuting {
    
	return (self.state == MKNetworkOperationStateExecuting);
}

-(void) cancel {
    
    if([self isFinished]) return;
    
    [self.responseBlocks removeAllObjects];
    self.responseBlocks = nil;
    
    [self.errorBlocks removeAllObjects];
    self.errorBlocks = nil;
    
    [self.uploadProgressChangedHandlers removeAllObjects];
    self.uploadProgressChangedHandlers = nil;
    
    [self.downloadProgressChangedHandlers removeAllObjects];
    self.downloadProgressChangedHandlers = nil;
    
    [self.downloadStreams removeAllObjects];
    self.downloadStreams = nil;
    
    [self.connection cancel];
    
    self.authHandler = nil;    
    self.mutableData = nil;
    self.isCancelled = YES; 
    
    [super cancel];
}

#pragma mark -
#pragma mark NSURLConnection delegates

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    
    self.error = error;
    self.mutableData = nil;
    for(NSOutputStream *stream in self.downloadStreams)
        [stream close];
    self.state = MKNetworkOperationStateFinished;
    
    [self operationFailedWithError:error];
}

- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    
    if (((challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodDefault) ||
         (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic) ||
         (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest) ||
         (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNTLM)) && 
        (self.username && self.password))
    {
        
        // for NTLM, we will assume user name to be of the form "domain\\username"
        NSURLCredential *credential = [NSURLCredential credentialWithUser:self.username 
                                                                 password:self.password
                                                              persistence:NSURLCredentialPersistenceForSession];
        
        [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
    }
    else if ((challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate) && self.clientCertificate) {
         
        NSData *certData = [[NSData alloc] initWithContentsOfFile:self.clientCertificate];
        
#warning method not implemented. Don't use client certicate authentication for now.
        SecIdentityRef myIdentity;  // ???
        
        SecCertificateRef myCert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certData);
        SecCertificateRef certArray[1] = { myCert };
        CFArrayRef myCerts = CFArrayCreate(NULL, (void *)certArray, 1, NULL);
        CFRelease(myCert);
        NSURLCredential *credential = [NSURLCredential credentialWithIdentity:myIdentity
                                                                 certificates:(__bridge NSArray *)myCerts
                                                                  persistence:NSURLCredentialPersistencePermanent];
        CFRelease(myCerts);
        [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
    }
    else if (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust) {
#warning method not tested. proceed at your own risk
        SecTrustRef serverTrust = [[challenge protectionSpace] serverTrust];
        SecTrustResultType result;
        SecTrustEvaluate(serverTrust, &result);

        if(result == kSecTrustResultProceed) {
            
             [challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge];
        }
        else if(result == kSecTrustResultConfirm) {
            
            // ask user
            BOOL userOkWithWrongCert = NO; // (ACTUALLY CHEAT., DON'T BE A F***ING BROWSER, USERS ALWAYS TAP YES WHICH IS RISKY)
            if(userOkWithWrongCert) {

                // Cert not trusted, but user is OK with that
                [challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge];
            } else {

                // Cert not trusted, and user is not OK with that. Don't proceed
                [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
            }
        } else {

            // invalid or revoked certificate
            [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
        }
    }        
    else if (self.authHandler) {
    
        // forward the authentication to the view controller that created this operation
        // If this happens for NSURLAuthenticationMethodHTMLForm, you have to
        // do some shit work like showing a modal webview controller and close it after authentication.
        // I HATE THIS.
        self.authHandler(challenge);
    }
    else {
        [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    
    NSUInteger size = [self.response expectedContentLength] < 0 ? 0 : [self.response expectedContentLength];
    self.response = (NSHTTPURLResponse*) response;
    self.mutableData = [NSMutableData dataWithCapacity:size];
    
    for(NSOutputStream *stream in self.downloadStreams)
        [stream open];
    
    NSDictionary *httpHeaders = [self.response allHeaderFields];
    
    if([self.request.HTTPMethod isEqualToString:@"GET"]) {
        
        // We have all this complicated cache handling since NSURLRequestReloadRevalidatingCacheData is not implemented
        // do cache processing only if the request is a "GET" method
        NSString *lastModified = [httpHeaders objectForKey:@"Last-Modified"];
        NSString *eTag = [httpHeaders objectForKey:@"ETag"];
        NSString *expiresOn = [httpHeaders objectForKey:@"Expires"];
        
        NSString *contentType = [httpHeaders objectForKey:@"Content-Type"];
        // if contentType is image, 
        
        NSDate *expiresOnDate = nil;
        
        if([contentType rangeOfString:@"image"].location != NSNotFound) {
            
            // For images let's assume a expiry date of 7 days if there is no eTag or Last Modified.
            if(!eTag && !lastModified)
                expiresOnDate = [[NSDate date] dateByAddingTimeInterval:kMKNetworkKitDefaultImageCacheDuration];
            else    
                expiresOnDate = [[NSDate date] dateByAddingTimeInterval:kMKNetworkKitDefaultImageHeadRequestDuration];
        }
        
        NSString *cacheControl = [httpHeaders objectForKey:@"Cache-Control"]; // max-age, must-revalidate, no-cache
        NSArray *cacheControlEntities = [cacheControl componentsSeparatedByString:@","];
        
        for(NSString *substring in cacheControlEntities) {
            
            if([substring rangeOfString:@"max-age"].location != NSNotFound) {
                
                // do some processing to calculate expiresOn
                NSString *maxAge = nil;
                NSArray *array = [substring componentsSeparatedByString:@"="];
                if([array count] > 1)
                    maxAge = [array objectAtIndex:1];
                
                expiresOnDate = [[NSDate date] dateByAddingTimeInterval:[maxAge intValue]];
            }
            if([substring rangeOfString:@"no-cache"].location != NSNotFound) {
                
                // Don't cache this request
                expiresOnDate = [[NSDate date] dateByAddingTimeInterval:kMKNetworkKitDefaultCacheDuration];
            }
        }
        
        // if there was a cacheControl entity, we would have a expiresOnDate that is not nil.        
        // "Cache-Control" headers take precedence over "Expires" headers
        
        expiresOn = [expiresOnDate rfc1123String];
        
        // now remember lastModified, eTag and expires for this request in cache
        if(expiresOn)
            [self.cacheHeaders setObject:expiresOn forKey:@"Expires"];
        if(lastModified)
            [self.cacheHeaders setObject:lastModified forKey:@"Last-Modified"];
        if(eTag)
            [self.cacheHeaders setObject:eTag forKey:@"ETag"];
    }
    
    
    
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    
    [self.mutableData appendData:data];
    
    for(NSOutputStream *stream in self.downloadStreams) {
        
        if ([stream hasSpaceAvailable]) {
            const uint8_t *dataBuffer = [data bytes];
            [stream write:&dataBuffer[0] maxLength:[data length]];
        }
    }
    
    for(MKNKProgressBlock downloadProgressBlock in self.downloadProgressChangedHandlers) {
        
        if([self.response expectedContentLength] > 0) {
            
            double progress = (double)[self.mutableData length] / (double)[self.response expectedContentLength];
            downloadProgressBlock(progress);
        }        
    }
}

- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten 
 totalBytesWritten:(NSInteger)totalBytesWritten
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
    
    for(MKNKProgressBlock uploadProgressBlock in self.uploadProgressChangedHandlers) {
        
        if(totalBytesExpectedToWrite > 0) {
            uploadProgressBlock(((double)totalBytesWritten/(double)totalBytesExpectedToWrite));
        }
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    
    self.state = MKNetworkOperationStateFinished;
    self.cachedResponse = nil; // remove cached data
    
    for(NSOutputStream *stream in self.downloadStreams)
        [stream close];
    
    if (self.response.statusCode >= 200 && self.response.statusCode < 300) {
        
        [self notifyCache];        
        [self operationSucceeded];
        
    } 
    if (self.response.statusCode >= 300 && self.response.statusCode < 400) {
        
        if(self.response.statusCode == 301) {
            DLog(@"%@ has moved to %@", self.url, [self.response.URL absoluteString]);
        }
        else if(self.response.statusCode == 304) {
            DLog(@"%@ not modified", self.url);
        }
        else if(self.response.statusCode == 307) {
            DLog(@"%@ temporarily redirected", self.url);
        }
        else {
            DLog(@"%@ returned status %d", self.url, self.response.statusCode);
        }
        
    } else if (self.response.statusCode >= 400 && self.response.statusCode < 600) {                        
        
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:self.response.statusCode
                                         userInfo:self.response.allHeaderFields];
        
        [self operationFailedWithError:error];
    }
}

#pragma mark -
#pragma mark Our methods to get data

-(NSData*) responseData {
    
    if([self isFinished])
        return [self.mutableData copy];
    else if(self.cachedResponse)
        return self.cachedResponse;
    else
        return nil;
}

-(NSString*)responseString {
    
    return [self responseStringWithEncoding:self.stringEncoding];
}

-(NSString*) responseStringWithEncoding:(NSStringEncoding) encoding {
    
    return [[NSString alloc] initWithData:[self responseData] encoding:encoding];
}

#if TARGET_OS_IPHONE
-(UIImage*) responseImage {
    
    return [UIImage imageWithData:[self responseData]];
}
#elif TARGET_OS_MAC
-(NSImage*) responseImage {
    
    return [[NSImage alloc] initWithData:[self responseData]];
}

-(NSXMLDocument*) responseXML {
    
    return [[NSXMLDocument alloc] initWithData:[self responseData] options:0 error:nil];
}
#endif

#ifdef __IPHONE_5_0
-(id) responseJSON {
    
    if([self responseData] == nil) return nil;
    NSError *error = nil;
    id returnValue = [NSJSONSerialization JSONObjectWithData:[self responseData] options:0 error:&error];    
    DLog(@"JSON Parsing Error: %@", error);
    return returnValue;
}
#endif


#pragma mark -
#pragma mark Overridable methods

-(void) operationSucceeded {
    
    // don't log for cached responses
    if(![self isCachedResponse])
        DLog(@"%@", self);
    
    for(MKNKResponseBlock responseBlock in self.responseBlocks)
        responseBlock(self);
}

-(void) operationFailedWithError:(NSError*) error {
    
    DLog(@"%@", self);
    for(MKNKErrorBlock errorBlock in self.errorBlocks)
        errorBlock(error);       
}

@end