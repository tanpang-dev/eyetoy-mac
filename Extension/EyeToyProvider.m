// Based on Xcode's "Camera Extension" template; the timer-driven test pattern is
// replaced by frames pushed from the EyeToy (eyetoy_usb.m) while a client streams.
#import "EyeToyProvider.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <IOKit/audio/IOAudioTypes.h>
#import "eyetoy_usb.h"

#define kWidth 640
#define kHeight 480
#define kFrameRate 15  // what the OV7648 actually delivers at 640x480
#define kSensorFps 30  // register setting that yields kFrameRate (see ov519_cam.c)
#define kPowerLineFreq 0

@class EyeToyStreamSource;

#pragma mark -

@interface EyeToyDeviceSource : NSObject<CMIOExtensionDeviceSource>
{
	EyeToyStreamSource *_streamSource;
	uint32_t _streamingCounter;
	CMFormatDescriptionRef _videoDescription;
	CVPixelBufferPoolRef _bufferPool;
	NSDictionary *_bufferAuxAttributes;
}

- (instancetype)initWithLocalizedName:(NSString *)localizedName;

@property(nonatomic, readonly) CMIOExtensionDevice *device;
@property(nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef videoDescription;
@property(nonatomic, strong) __attribute__((NSObject)) CVPixelBufferPoolRef bufferPool;
@property(nonatomic, strong) NSDictionary *bufferAuxAttributes;

- (void)startStreaming;
- (void)stopStreaming;

@end


#pragma mark -

@interface EyeToyStreamSource : NSObject<CMIOExtensionStreamSource>
{
	__unsafe_unretained CMIOExtensionDevice *_device;
	CMIOExtensionStreamFormat *_streamFormat;
}

- (instancetype)initWithLocalizedName:(NSString *)localizedName streamID:(NSUUID *)streamID streamFormat:(CMIOExtensionStreamFormat *)streamFormat device:(CMIOExtensionDevice *)device;

@property(nonatomic, readonly) CMIOExtensionStream *stream;

@end


#pragma mark -

@implementation EyeToyDeviceSource

- (instancetype)initWithLocalizedName:(NSString *)localizedName
{
	self = [super init];
	if (self) {
		// fixed IDs so apps remember the camera across launches
		NSUUID *deviceID = [[NSUUID alloc] initWithUUIDString:@"FBA32132-3540-429A-AC90-2051D073D819"];
		_device = [[CMIOExtensionDevice alloc] initWithLocalizedName:localizedName deviceID:deviceID legacyDeviceID:nil source:self];

		CMVideoDimensions dims = {.width = kWidth, .height = kHeight};
		(void)CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_32BGRA, dims.width, dims.height, NULL, &_videoDescription);
		if (_videoDescription) {
			NSDictionary *pixelBufferAttributes = @{ (id)kCVPixelBufferWidthKey : @(dims.width),
													 (id)kCVPixelBufferHeightKey : @(dims.height),
													 (id)kCVPixelBufferPixelFormatTypeKey : @(CMFormatDescriptionGetMediaSubType(_videoDescription)),
													 (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
													};
			(void)CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)pixelBufferAttributes, &_bufferPool);
		}

		CMIOExtensionStreamFormat *videoStreamFormat = nil;
		if (_bufferPool) {
			videoStreamFormat = [[CMIOExtensionStreamFormat alloc] initWithFormatDescription:_videoDescription maxFrameDuration:CMTimeMake(1, kFrameRate) minFrameDuration:CMTimeMake(1, kFrameRate) validFrameDurations:nil];
			_bufferAuxAttributes = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @(5)};
		}

		if (videoStreamFormat) {
			NSUUID *videoID = [[NSUUID alloc] initWithUUIDString:@"3A863877-22E7-478C-A1AC-22DEF1707AF3"];
			_streamSource = [[EyeToyStreamSource alloc] initWithLocalizedName:@"EyeToy.Video" streamID:videoID streamFormat:videoStreamFormat device:_device];

			NSError *error = nil;
			if (![_device addStream:_streamSource.stream error:&error]) {
				@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"Failed to add stream: %@", error.localizedDescription] userInfo:nil];
			}
		}
	}

	return self;
}

- (NSSet<CMIOExtensionProperty> *)availableProperties
{
    return [NSSet setWithObjects:CMIOExtensionPropertyDeviceTransportType, CMIOExtensionPropertyDeviceModel, nil];
}

- (nullable CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError * _Nullable *)outError
{
	CMIOExtensionDeviceProperties *deviceProperties = [CMIOExtensionDeviceProperties devicePropertiesWithDictionary:@{}];
	if ([properties containsObject:CMIOExtensionPropertyDeviceTransportType]) {
		deviceProperties.transportType = [NSNumber numberWithInt:kIOAudioDeviceTransportTypeUSB];
	}
	if ([properties containsObject:CMIOExtensionPropertyDeviceModel]) {
		deviceProperties.model = @"EyeToy (OV519)";
	}

	return deviceProperties;
}

- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)deviceProperties error:(NSError * _Nullable *)outError
{
	return YES;
}

- (void)sendJPEG:(NSData *)jpeg
{
	CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
	CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
	if (src) CFRelease(src);
	if (!image) {
		os_log_error(OS_LOG_DEFAULT, "eyetoy: undecodable frame (%lu bytes)", (unsigned long)jpeg.length);
		return;
	}

	CVPixelBufferRef pixelBuffer = NULL;
	OSStatus err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self.bufferPool, (__bridge CFDictionaryRef)self.bufferAuxAttributes, &pixelBuffer);
	if (err || !pixelBuffer) {
		os_log_error(OS_LOG_DEFAULT, "eyetoy: out of pixel buffers %d", err);
		CGImageRelease(image);
		return;
	}

	CVPixelBufferLockBaseAddress(pixelBuffer, 0);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer), kWidth, kHeight, 8,
		CVPixelBufferGetBytesPerRow(pixelBuffer), cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGContextDrawImage(ctx, CGRectMake(0, 0, kWidth, kHeight), image);
	CGContextRelease(ctx);
	CGColorSpaceRelease(cs);
	CGImageRelease(image);
	CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

	CMSampleBufferRef sbuf = NULL;
	CMSampleTimingInfo timingInfo = {.duration = CMTimeMake(1, kFrameRate), .decodeTimeStamp = kCMTimeInvalid};
	timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
	err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, self.videoDescription, &timingInfo, &sbuf);
	CFRelease(pixelBuffer);
	if (!err) {
		[_streamSource.stream sendSampleBuffer:sbuf discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:(uint64_t)(CMTimeGetSeconds(timingInfo.presentationTimeStamp) * NSEC_PER_SEC)];
		CFRelease(sbuf);
	}
}

- (void)startStreaming
{
	if (!_bufferPool || _streamingCounter++ > 0) {
		return;
	}
	__weak EyeToyDeviceSource *weakSelf = self;
	if (!eyetoy_start(kSensorFps, kPowerLineFreq, ^(NSData *jpeg) { [weakSelf sendJPEG:jpeg]; })) {
		os_log_error(OS_LOG_DEFAULT, "eyetoy: failed to start (not plugged in?)");
	}
}

- (void)stopStreaming
{
	if (_streamingCounter > 1) {
		_streamingCounter -= 1;
	}
	else {
		_streamingCounter = 0;
		eyetoy_stop();
	}
}

@end


#pragma mark -

@implementation EyeToyStreamSource

- (instancetype)initWithLocalizedName:(NSString *)localizedName streamID:(NSUUID *)streamID streamFormat:(CMIOExtensionStreamFormat *)streamFormat device:(CMIOExtensionDevice *)device
{
	self = [super init];
	if (self) {
		_device = device;
		_streamFormat = streamFormat;
		_stream = [[CMIOExtensionStream alloc] initWithLocalizedName:localizedName streamID:streamID direction:CMIOExtensionStreamDirectionSource clockType:CMIOExtensionStreamClockTypeHostTime source:self];
	}
	return self;
}

- (NSArray<CMIOExtensionStreamFormat *> *)formats
{
	return [NSArray arrayWithObjects:_streamFormat, nil];
}

- (NSUInteger)activeFormatIndex
{
	return 0;
}

- (void)setActiveFormatIndex:(NSUInteger)activeFormatIndex
{
	if (activeFormatIndex >= 1) {
		os_log_error(OS_LOG_DEFAULT, "Invalid index");
	}
}

- (NSSet<CMIOExtensionProperty> *)availableProperties
{
    return [NSSet setWithObjects:CMIOExtensionPropertyStreamActiveFormatIndex, CMIOExtensionPropertyStreamFrameDuration, nil];
}

- (nullable CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError * _Nullable *)outError
{
	CMIOExtensionStreamProperties *streamProperties = [CMIOExtensionStreamProperties streamPropertiesWithDictionary:@{}];
	if ([properties containsObject:CMIOExtensionPropertyStreamActiveFormatIndex]) {
		streamProperties.activeFormatIndex = @(self.activeFormatIndex);
	}
	if ([properties containsObject:CMIOExtensionPropertyStreamFrameDuration]) {
		CMTime frameDuration = CMTimeMake(1, kFrameRate);
		NSDictionary *frameDurationDictionary = CFBridgingRelease(CMTimeCopyAsDictionary(frameDuration, NULL));
		streamProperties.frameDuration = frameDurationDictionary;
	}
	return streamProperties;
}

- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)streamProperties error:(NSError * _Nullable *)outError
{
	if (streamProperties.activeFormatIndex) {
		[self setActiveFormatIndex:streamProperties.activeFormatIndex.unsignedIntegerValue];
	}
	return YES;
}

- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client
{
	return YES;
}

- (BOOL)startStreamAndReturnError:(NSError * _Nullable *)outError
{
	EyeToyDeviceSource *deviceSource = (EyeToyDeviceSource *)_device.source;
	[deviceSource startStreaming];
	return YES;
}

- (BOOL)stopStreamAndReturnError:(NSError * _Nullable *)outError
{
	EyeToyDeviceSource *deviceSource = (EyeToyDeviceSource *)_device.source;
	[deviceSource stopStreaming];
	return YES;
}

@end


#pragma mark -

@interface EyeToyProviderSource ()
{
	EyeToyDeviceSource *_deviceSource;
}

@end

@implementation EyeToyProviderSource

- (instancetype)initWithClientQueue:(dispatch_queue_t)clientQueue
{
	self = [super init];
	if (self) {
		_provider = [[CMIOExtensionProvider alloc] initWithSource:self clientQueue:clientQueue];
		_deviceSource = [[EyeToyDeviceSource alloc] initWithLocalizedName:@"EyeToy"];

		NSError *error = nil;
		if (![_provider addDevice:_deviceSource.device error:&error]) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"Failed to add device: %@", error.localizedDescription] userInfo:nil];
		}
	}
	return self;
}

- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError * _Nullable *)outError
{
	return YES;
}

- (void)disconnectClient:(CMIOExtensionClient *)client
{
}

- (NSSet<CMIOExtensionProperty> *)availableProperties
{
    return [NSSet setWithObjects:CMIOExtensionPropertyProviderManufacturer, nil];
}

- (nullable CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet<CMIOExtensionProperty> *)properties error:(NSError * _Nullable *)outError
{
	CMIOExtensionProviderProperties *providerProperties = [CMIOExtensionProviderProperties providerPropertiesWithDictionary:@{}];
	if ([properties containsObject:CMIOExtensionPropertyProviderManufacturer]) {
		providerProperties.manufacturer = @"Sony / Logitech";
	}
	return providerProperties;
}

- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)providerProperties error:(NSError * _Nullable *)outError
{
	return YES;
}

@end
