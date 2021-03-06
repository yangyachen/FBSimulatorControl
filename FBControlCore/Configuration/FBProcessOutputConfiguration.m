/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBProcessOutputConfiguration.h"

#import <FBControlCore/FBControlCore.h>

NSString *const FBProcessOutputToFileDefaultLocation = @"FBProcessOutputToFileDefaultLocation";

@implementation FBProcessOutputConfiguration

#pragma mark Initializers

+ (nullable instancetype)configurationWithStdOut:(id)stdOut stdErr:(id)stdErr error:(NSError **)error
{
  if (![stdOut isKindOfClass:NSNull.class] && ![stdOut isKindOfClass:NSString.class] && ![stdOut conformsToProtocol:@protocol(FBDataConsumer)]) {
    return [[FBControlCoreError
      describeFormat:@"'stdout' should be (Null | String | FBDataConsumer) but is %@",  stdOut]
      fail:error];
  }

  if (![stdErr isKindOfClass:NSNull.class] && ![stdErr isKindOfClass:NSString.class] && ![stdErr conformsToProtocol:@protocol(FBDataConsumer)]) {
    return [[FBControlCoreError
      describeFormat:@"'stderr' should be (Null | String | FBDataConsumer) but is %@",  stdErr]
      fail:error];
  }
  return [[self alloc] initWithStdOut:stdOut stdErr:stdErr];
}

+ (instancetype)defaultOutputToFile
{
  return [[self alloc] initWithStdOut:FBProcessOutputToFileDefaultLocation stdErr:FBProcessOutputToFileDefaultLocation];
}

+ (instancetype)outputToDevNull
{
  return [[self alloc] init];
}

- (instancetype)init
{
  return [self initWithStdOut:NSNull.null stdErr:NSNull.null];
}

- (instancetype)initWithStdOut:(id)stdOut stdErr:(id)stdErr
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _stdOut = stdOut;
  _stdErr = stdErr;
  return self;
}

- (nullable instancetype)withStdOut:(id)stdOut error:(NSError **)error
{
  return [FBProcessOutputConfiguration configurationWithStdOut:stdOut stdErr:self.stdErr error:error];
}

- (nullable instancetype)withStdErr:(id)stdErr error:(NSError **)error
{
  return [FBProcessOutputConfiguration configurationWithStdOut:self.stdOut stdErr:stdErr error:error];
}

#pragma mark Public Methods

- (FBFuture<NSArray<FBProcessOutput *> *> *)createOutputForTarget:(id<FBiOSTarget>)target
{
  return [FBFuture futureWithFutures:@[
    [self createOutputForTarget:target selector:@selector(stdOut)],
    [self createOutputForTarget:target selector:@selector(stdErr)],
  ]];
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
  return self;
}

#pragma mark NSObject

- (NSUInteger)hash
{
  return [self.stdOut hash] ^ [self.stdErr hash];
}

- (BOOL)isEqual:(FBProcessOutputConfiguration *)object
{
  if (![object isKindOfClass:self.class]) {
    return NO;
  }
  return [self.stdOut isEqual:object.stdOut] && [self.stdErr isEqual:object.stdErr];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"StdOut %@ | StdErr %@", self.stdOut, self.stdErr];
}

#pragma mark FBJSONSerializable

static NSString *StdOutKey = @"stdout";
static NSString *StdErrKey = @"stderr";

+ (instancetype)inflateFromJSON:(NSDictionary<NSString *, id> *)json error:(NSError **)error
{
  if (![FBCollectionInformation isDictionaryHeterogeneous:json keyClass:NSString.class valueClass:NSObject.class]) {
    return [[FBControlCoreError
      describeFormat:@"Process Output Configuration is not an Dictionary<String, Null|String> for %@", json]
      fail:error];
  }
  return [self configurationWithStdOut:json[StdOutKey] stdErr:json[StdErrKey] error:error];
}

- (NSDictionary *)jsonSerializableRepresentation
{
  return @{
    @"stdout": self.stdOut,
    @"stderr": self.stdErr,
  };
}

#pragma mark Private

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

- (FBFuture<FBProcessOutput *> *)createOutputForTarget:(id<FBiOSTarget>)target selector:(SEL)selector
{
  return [[self
    createDiagnosticForSelector:selector target:target]
    onQueue:target.workQueue fmap:^FBFuture *(id maybeDiagnostic) {
      if ([maybeDiagnostic isKindOfClass:FBDiagnostic.class]) {
        FBDiagnostic *diagnostic = maybeDiagnostic;
        NSString *path = diagnostic.asPath;
        return [FBFuture futureWithResult:[FBProcessOutput outputForFilePath:path]];
      }
      id<FBDataConsumer> consumer = [self performSelector:selector];
      if (![consumer conformsToProtocol:@protocol(FBDataConsumer)]) {
        return [FBFuture futureWithResult:FBProcessOutput.outputForNullDevice];
      }
      return [FBFuture futureWithResult:[FBProcessOutput outputForDataConsumer:consumer]];
    }];
}

- (FBFuture<id> *)createDiagnosticForSelector:(SEL)selector target:(id<FBiOSTarget>)target
{
  NSString *output = [self performSelector:selector];
  if (![output isKindOfClass:NSString.class]) {
    return [FBFuture futureWithResult:NSNull.null];
  }

  SEL diagnosticSelector = NSSelectorFromString([NSString stringWithFormat:@"%@:", NSStringFromSelector(selector)]);
  FBDiagnostic *diagnostic = [target.diagnostics performSelector:diagnosticSelector withObject:self];
  FBDiagnosticBuilder *builder = [FBDiagnosticBuilder builderWithDiagnostic:diagnostic];

  NSString *path = [output isEqualToString:FBProcessOutputToFileDefaultLocation] ? [builder createPath] : output;

  [builder updateStorageDirectory:[path stringByDeletingLastPathComponent]];

  if (![NSFileManager.defaultManager createFileAtPath:path contents:NSData.data attributes:nil]) {
    return [[FBControlCoreError
      describeFormat:@"Could not create '%@' at path '%@' for config '%@'", NSStringFromSelector(selector), path, self]
      failFuture];
  }

  [builder updatePath:path];

  return [FBFuture futureWithResult:[builder build]];
}

#pragma clang diagnostic pop

@end
