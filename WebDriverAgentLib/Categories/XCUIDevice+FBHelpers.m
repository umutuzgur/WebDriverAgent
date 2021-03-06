/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "XCUIDevice+FBHelpers.h"

#import <arpa/inet.h>
#import <ifaddrs.h>
#include <notify.h>

#import "FBSpringboardApplication.h"
#import "FBErrorBuilder.h"
#import "FBMathUtils.h"
#import "FBXCodeCompatibility.h"

#import "FBMacros.h"
#import "XCAXClient_iOS.h"

static const NSTimeInterval FBHomeButtonCoolOffTime = 1.;

@implementation XCUIDevice (FBHelpers)

// We can assume that the screen is not locked when the test starts
static bool locked = FALSE;

+ (void) load {
  [self registerAppforDetectLockState];
}

+ (void)registerAppforDetectLockState {
  
  int notify_token;
#pragma clang diagnostic ignored "-Wstrict-prototypes"
  notify_register_dispatch("com.apple.springboard.lockstate", &notify_token,dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(int token) {
    uint64_t state = UINT64_MAX;
    notify_get_state(token, &state);
    if(state == 0) {
      locked = FALSE;
    } else {
      locked = TRUE;
    }
  });
  
}

- (BOOL)fb_goToHomescreenWithError:(NSError **)error
{
  [self pressButton:XCUIDeviceButtonHome];
  // This is terrible workaround to the fact that pressButton:XCUIDeviceButtonHome is not a synchronous action.
  // On 9.2 some first queries  will trigger additional "go to home" event
  // So if we don't wait here it will be interpreted as double home button gesture and go to application switcher instead.
  // On 9.3 pressButton:XCUIDeviceButtonHome can be slightly delayed.
  // Causing waitUntilApplicationBoardIsVisible not to work properly in some edge cases e.g. like starting session right after this call, while being on home screen
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:FBHomeButtonCoolOffTime]];
  if (![[FBSpringboardApplication fb_springboard] fb_waitUntilApplicationBoardIsVisible:error]) {
    return NO;
  }
  return YES;
}

- (BOOL)fb_lockScreen:(NSError **)error
{
  if (locked) {
    return TRUE;
  }
  SEL mSelector = NSSelectorFromString(@"pressLockButton");
  [self methodSignatureForSelector:mSelector];
  NSMethodSignature *mSignature = [self methodSignatureForSelector:mSelector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:mSignature];
  [invocation setTarget:self];
  [invocation setSelector:mSelector];
  [invocation invoke];
  return [[[[FBRunLoopSpinner new]
            timeout:10.]
           timeoutErrorMessage:@"Timeout waiting until screen getting locked"]
          spinUntilTrue:^BOOL{
            return locked;
          } error:error];
}

- (BOOL)fb_isScreenLocked
{
  return locked;
}

- (BOOL)fb_unlockScreen:(NSError **)error
{
  if (!locked) {
    return TRUE;
  }
  [self fb_goToHomescreenWithError:NULL];
  [self fb_goToHomescreenWithError:NULL];
  
  return [[[[FBRunLoopSpinner new]
            timeout:10.]
           timeoutErrorMessage:@"Timeout waiting until screen getting unlocked"]
          spinUntilTrue:^BOOL{
            return !locked;
          } error:error];
}


- (NSData *)fb_screenshotWithError:(NSError*__autoreleasing*)error
{
  id xcScreen = NSClassFromString(@"XCUIScreen");
  if (nil == xcScreen) {
    NSData *result = [[XCAXClient_iOS sharedClient] screenshotData];
    if (nil == result) {
      if (error) {
        *error = [[FBErrorBuilder.builder withDescription:@"Cannot take a screenshot of the current screen state"] build];
      }
      return nil;
    }
    return result;
  }
  
  id mainScreen = [xcScreen valueForKey:@"mainScreen"];
  XCUIApplication *app = FBApplication.fb_activeApplication;
  CGSize screenSize = FBAdjustDimensionsForApplication(app.frame.size, app.interfaceOrientation);
  SEL mSelector = NSSelectorFromString(@"screenshotDataForQuality:rect:error:");
  NSMethodSignature *mSignature = [mainScreen methodSignatureForSelector:mSelector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:mSignature];
  [invocation setTarget:mainScreen];
  [invocation setSelector:mSelector];
  // https://developer.apple.com/documentation/xctest/xctimagequality?language=objc
  // Select lower quality, since XCTest crashes randomly if the maximum quality (zero value) is selected
  // and the resulting screenshot does not fit the memory buffer preallocated for it by the operating system
  NSUInteger quality = 1;
  [invocation setArgument:&quality atIndex:2];
  CGRect screenRect = CGRectMake(0, 0, screenSize.width, screenSize.height);
  [invocation setArgument:&screenRect atIndex:3];
  [invocation setArgument:&error atIndex:4];
  [invocation invoke];
  NSData __unsafe_unretained *result;
  [invocation getReturnValue:&result];
  if (nil == result) {
    return nil;
  }
  // The resulting data is a JPEG image, so we need to convert it to PNG representation
  UIImage *image = [UIImage imageWithData:result];
  return (NSData *)UIImagePNGRepresentation(image);
}

- (BOOL)fb_fingerTouchShouldMatch:(BOOL)shouldMatch
{
  const char *name;
  if (shouldMatch) {
    name = "com.apple.BiometricKit_Sim.fingerTouch.match";
  } else {
    name = "com.apple.BiometricKit_Sim.fingerTouch.nomatch";
  }
  return notify_post(name) == NOTIFY_STATUS_OK;
}

- (NSString *)fb_wifiIPAddress
{
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = getifaddrs(&interfaces);
  if (success != 0) {
    freeifaddrs(interfaces);
    return nil;
  }

  NSString *address = nil;
  temp_addr = interfaces;
  while(temp_addr != NULL) {
    if(temp_addr->ifa_addr->sa_family != AF_INET) {
      temp_addr = temp_addr->ifa_next;
      continue;
    }
    NSString *interfaceName = [NSString stringWithUTF8String:temp_addr->ifa_name];
    if(![interfaceName containsString:@"en"]) {
      temp_addr = temp_addr->ifa_next;
      continue;
    }
    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
    break;
  }
  freeifaddrs(interfaces);
  return address;
}

@end
