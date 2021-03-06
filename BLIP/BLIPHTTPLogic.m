//
//  BLIPHTTPLogic.m
//  BLIP
//
//  Created by Jens Alfke on 11/13/13.
//  Copyright (c) 2013-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "BLIPHTTPLogic.h"
#import "Logging.h"
#import "Test.h"
#import "MYURLUtils.h"


#define kMaxRedirects 10


@implementation BLIPHTTPLogic
{
    NSMutableURLRequest* _urlRequest;
    NSString* _nonceKey;
    NSString* _authorizationHeader;
    CFHTTPMessageRef _responseMsg;
    NSURLCredential* _credential;
    NSUInteger _redirectCount;
}


@synthesize handleRedirects=_handleRedirects, shouldContinue=_shouldContinue,
            shouldRetry=_shouldRetry, credential=_credential, httpStatus=_httpStatus, error=_error;


- (instancetype) initWithURLRequest:(NSURLRequest *)urlRequest {
    NSParameterAssert(urlRequest);
    self = [super init];
    if (self) {
        _urlRequest = [urlRequest mutableCopy];
        _handleRedirects = YES;
    }
    return self;
}


- (void) dealloc {
    if (_responseMsg) CFRelease(_responseMsg);
}


- (NSURL*) URL {
    return _urlRequest.URL;
}


- (UInt16) port {
    NSNumber* portObj = self.URL.port;
    if (portObj)
        return (UInt16)portObj.intValue;
    else
        return self.useTLS ? 443 : 80;
}

- (BOOL) useTLS {
    NSString* scheme = self.URL.scheme.lowercaseString;
    return [scheme isEqualToString: @"https"] || [scheme isEqualToString: @"wss"];
}


+ (NSString*) userAgent {
    NSProcessInfo* process = [NSProcessInfo processInfo];
    NSString* appVers = (__bridge NSString*)CFBundleGetValueForInfoDictionaryKey
    (CFBundleGetMainBundle(), kCFBundleVersionKey);
    return $sprintf(@"%@/%@ (%@ %@)",
                    process.processName, appVers,
#if TARGET_OS_IPHONE
                    @"iOS",
#else
                    @"Mac OS X",
#endif
                    process.operatingSystemVersionString);
}


- (void) setValue: (NSString*)value forHTTPHeaderField:(NSString*)header {
    [_urlRequest setValue: value forHTTPHeaderField: header];
}

- (void) setObject: (NSString*)value forKeyedSubscript: (NSString*)key {
    [_urlRequest setValue: value forHTTPHeaderField: key];
}


- (NSURLRequest*) URLRequest {
    CFHTTPMessageRef httpMessage = [self newHTTPRequest];

    NSMutableURLRequest* request = [_urlRequest mutableCopy];
    NSDictionary* headers = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(httpMessage));
    for (NSString* headerName in headers) {
        if (![request valueForHTTPHeaderField: headerName])
            [request setValue: headers[headerName] forHTTPHeaderField: headerName];
    }
    CFRelease(httpMessage);
    return request;
}


- (CFHTTPMessageRef) newHTTPRequest {
    NSURL* url = self.URL;
    // Set/update the "Host" header:
    NSString* host = url.host;
    if (url.port)
        host = [host stringByAppendingFormat: @":%@", url.port];
    [self setValue: host forHTTPHeaderField: @"Host"];

    // Create the CFHTTPMessage:
    CFHTTPMessageRef httpMsg = CFHTTPMessageCreateRequest(NULL,
                                                      (__bridge CFStringRef)_urlRequest.HTTPMethod,
                                                      (__bridge CFURLRef)url,
                                                      kCFHTTPVersion1_1);
    NSDictionary* headers = _urlRequest.allHTTPHeaderFields;
    for (NSString* header in headers)
        CFHTTPMessageSetHeaderFieldValue(httpMsg, (__bridge CFStringRef)header,
                                         (__bridge CFStringRef)headers[header]);

    // Add cookie headers from the NSHTTPCookieStorage:
    if (_urlRequest.HTTPShouldHandleCookies) {
        NSArray* cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL: url];
        NSDictionary* cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies: cookies];
        for (NSString* headerName in cookieHeaders) {
            CFHTTPMessageSetHeaderFieldValue(httpMsg,
                                             (__bridge CFStringRef)headerName,
                                             (__bridge CFStringRef)cookieHeaders[headerName]);
        }
    }

    // Add User-Agent if necessary:
    if (![_urlRequest valueForHTTPHeaderField: @"User-Agent"])
        CFHTTPMessageSetHeaderFieldValue(httpMsg, CFSTR("User-Agent"),
                                         (__bridge CFStringRef)[[self class] userAgent]);

    // If this is a retry, set auth headers from the credential we got:
    if (_responseMsg && _credential.user) {
        NSString* password = _credential.password;
        if (!password) {
            // For some reason the password sometimes isn't accessible, even though we checked
            // .hasPassword when setting _credential earlier. (See #195.) Keychain bug??
            // If this happens, try looking up the credential again:
            LogTo(ChangeTracker, @"Huh, couldn't get password of %@; trying again", _credential);
            _credential = [self credentialForAuthHeader:
                                                getHeader(_responseMsg, @"WWW-Authenticate")];
            password = _credential.password;
            if (!password)
                Warn(@"%@: Unable to get password of credential %@", self, _credential);
        }
        if (!password ||
            (!CFHTTPMessageAddAuthentication(httpMsg, _responseMsg,
                                             (__bridge CFStringRef)_credential.user,
                                             (__bridge CFStringRef)password,
                                             NULL,
                                             _httpStatus == 407)
             && !CFHTTPMessageAddAuthentication(httpMsg, _responseMsg,
                                                (__bridge CFStringRef)_credential.user,
                                                (__bridge CFStringRef)password,
                                                kCFHTTPAuthenticationSchemeBasic, // fallback
                                                _httpStatus == 407)))
        {
            // The 2nd call above works around a bug where it can fail if the auth scheme is NULL.
            Warn(@"%@: Unable to add authentication", self);
            _credential = nil;
            CFRelease(_responseMsg);
            _responseMsg = NULL;
        }
    }

    NSData* body = _urlRequest.HTTPBody;
    if (body) {
        CFHTTPMessageSetHeaderFieldValue(httpMsg, CFSTR("Content-Length"),
                                         (__bridge CFStringRef)[@(body.length) description]);
        CFHTTPMessageSetBody(httpMsg, (__bridge CFDataRef)body);
    }

    _authorizationHeader = getHeader(httpMsg, @"Authorization");
    _shouldContinue = _shouldRetry = NO;
    _httpStatus = 0;

    return httpMsg;
}


- (void) receivedResponse: (CFHTTPMessageRef)response {
    NSParameterAssert(response);
    if (response == _responseMsg)
        return;
    if (_responseMsg)
        CFRelease(_responseMsg);
    _responseMsg = response;
    CFRetain(_responseMsg);

    _shouldContinue = _shouldRetry = NO;
    _httpStatus = (int) CFHTTPMessageGetResponseStatusCode(_responseMsg);
    switch (_httpStatus) {
        case 301:
        case 302:
        case 307: {
            // Redirect:
            if (!_handleRedirects)
                break;
            if (++_redirectCount > kMaxRedirects) {
                [self setErrorCode: NSURLErrorHTTPTooManyRedirects userInfo: nil];
            } else if (![self redirect]) {
                [self setErrorCode: NSURLErrorRedirectToNonExistentLocation userInfo: nil];
            } else {
                _shouldRetry = YES;
            }
            break;
        }

        case 401:
        case 407: {
            NSString* authResponse = getHeader(_responseMsg, @"WWW-Authenticate");
            if (!_authorizationHeader) {
                if (!_credential)
                    _credential = [self credentialForAuthHeader: authResponse];
                LogTo(ChangeTracker, @"%@: Auth challenge; credential = %@", self, _credential);
                if (_credential) {
                    // Recoverable auth failure -- try again with new _credential:
                    _shouldRetry = YES;
                    break;
                }
            }
            Log(@"%@: HTTP auth failed; sent Authorization: %@  ;  got WWW-Authenticate: %@",
                self, _authorizationHeader, authResponse);
            NSDictionary* errorInfo = $dict({@"HTTPAuthorization", _authorizationHeader},
                                            {@"HTTPAuthenticateHeader", authResponse});
            [self setErrorCode: NSURLErrorUserAuthenticationRequired userInfo: errorInfo];
            break;
        }

        default:
            if (_httpStatus < 300)
                _shouldContinue = YES;
            break;
    }
}


- (BOOL) redirect {
    NSString* location = getHeader(_responseMsg, @"Location");
    if (!location)
        return NO;
    NSURL* url = [NSURL URLWithString: location relativeToURL: self.URL];
    if (!url)
        return NO;
    if ([url.scheme caseInsensitiveCompare: @"http"] != 0 &&
            [url.scheme caseInsensitiveCompare: @"https"] != 0)
        return NO;
    _urlRequest.URL = url;
    return YES;
}


- (NSURLCredential*) credentialForAuthHeader: (NSString*)authHeader {
    NSString* realm;
    NSString* authenticationMethod;

    // Basic & digest auth: http://www.ietf.org/rfc/rfc2617.txt
    if (!authHeader)
        return nil;

    // Get the auth type:
    if ([authHeader hasPrefix: @"Basic"])
        authenticationMethod = NSURLAuthenticationMethodHTTPBasic;
    else if ([authHeader hasPrefix: @"Digest"])
        authenticationMethod = NSURLAuthenticationMethodHTTPDigest;
    else
        return nil;

    // Get the realm:
    NSRange r = [authHeader rangeOfString: @"realm=\""];
    if (r.length == 0)
        return nil;
    NSUInteger start = NSMaxRange(r);
    r = [authHeader rangeOfString: @"\"" options: 0
                            range: NSMakeRange(start, authHeader.length - start)];
    if (r.length == 0)
        return nil;
    realm = [authHeader substringWithRange: NSMakeRange(start, r.location - start)];

    NSURLCredential* cred;
    cred = [self.URL my_credentialForRealm: realm authenticationMethod: authenticationMethod];
    if (!cred.hasPassword)
        cred = nil;     // TODO: Add support for client certs
    return cred;
}


- (void) setErrorCode: (NSInteger)code userInfo: (NSDictionary*)userInfo {
    NSMutableDictionary* info = $mdict({NSURLErrorFailingURLErrorKey, self.URL});
    if (userInfo)
        [info addEntriesFromDictionary: userInfo];
    _error = [NSError errorWithDomain: NSURLErrorDomain code: code userInfo: info];
}


static NSString* getHeader(CFHTTPMessageRef message, NSString* header) {
    return CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue(message,
                                                               (__bridge CFStringRef)header));
}


@end
