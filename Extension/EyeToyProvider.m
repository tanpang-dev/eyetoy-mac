// Based on Xcode's "Camera Extension" template; the timer-driven test pattern is
// replaced by frames pushed from the EyeToy (eyetoy_usb.m) while a client streams.
#import "EyeToyProvider.h"

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <Accelerate/Accelerate.h>
#import <IOKit/audio/IOAudioTypes.h>
#import "eyetoy_usb.h"

// fps: what the OV7648 actually delivers with the clock divider in ov519_cam.c.
// maxFps: what we advertise. AVFoundation's default preset skips formats below 30 fps,
// so VGA claims 20-30 to stay the default for apps that don't pick a format.
typedef struct { int width, height, fps, maxFps; BOOL qvga; } EyeToyMode;
static const EyeToyMode kModes[] = {
	{640, 480, 20, 30, NO},
	{320, 240, 60, 60, YES}, // what the PS2 uses
};
#define kModeCount (sizeof kModes / sizeof kModes[0])
#define kSensorFps 30  // register setting for the fastest sensor timing (see ov519_cam.c)
#define kPowerLineFreq 0
// Tone curve applied after decoding: >1 darkens midtones, keeps black and white.
// Done here because the sensor's brightness registers get undone by its auto exposure.
#define kGamma 1.2

@class EyeToyStreamSource;

#pragma mark -

@interface EyeToyDeviceSource : NSObject<CMIOExtensionDeviceSource>
{
	EyeToyStreamSource *_streamSource;
	uint32_t _streamingCounter;
	CMFormatDescriptionRef _videoDescriptions[kModeCount];
	CVPixelBufferPoolRef _bufferPools[kModeCount];
	NSDictionary *_bufferAuxAttributes;
	Pixel_8 _toneCurve[256];
}

- (instancetype)initWithLocalizedName:(NSString *)localizedName;

@property(nonatomic, readonly) CMIOExtensionDevice *device;
@property(nonatomic) NSUInteger activeMode;

- (void)startStreaming;
- (void)stopStreaming;

@end


#pragma mark -

@interface EyeToyStreamSource : NSObject<CMIOExtensionStreamSource>
{
	__unsafe_unretained CMIOExtensionDevice *_device;
	NSArray<CMIOExtensionStreamFormat *> *_streamFormats;
}

- (instancetype)initWithLocalizedName:(NSString *)localizedName streamID:(NSUUID *)streamID streamFormats:(NSArray<CMIOExtensionStreamFormat *> *)streamFormats device:(CMIOExtensionDevice *)device;

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
		_bufferAuxAttributes = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @(5)};
		for (int i = 0; i < 256; i++) {
			_toneCurve[i] = (Pixel_8)lround(255.0 * pow(i / 255.0, kGamma));
		}

		NSMutableArray<CMIOExtensionStreamFormat *> *formats = [NSMutableArray array];
		for (NSUInteger i = 0; i < kModeCount; i++) {
			EyeToyMode m = kModes[i];
			(void)CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCVPixelFormatType_32BGRA, m.width, m.height, NULL, &_videoDescriptions[i]);
			NSDictionary *pixelBufferAttributes = @{ (id)kCVPixelBufferWidthKey : @(m.width),
													 (id)kCVPixelBufferHeightKey : @(m.height),
													 (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
													 (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
													};
			(void)CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)pixelBufferAttributes, &_bufferPools[i]);
			if (!_videoDescriptions[i] || !_bufferPools[i]) {
				@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Failed to create video format" userInfo:nil];
			}
			[formats addObject:[[CMIOExtensionStreamFormat alloc] initWithFormatDescription:_videoDescriptions[i] maxFrameDuration:CMTimeMake(1, m.fps) minFrameDuration:CMTimeMake(1, m.maxFps) validFrameDurations:nil]];
		}

		NSUUID *videoID = [[NSUUID alloc] initWithUUIDString:@"3A863877-22E7-478C-A1AC-22DEF1707AF3"];
		_streamSource = [[EyeToyStreamSource alloc] initWithLocalizedName:@"EyeToy.Video" streamID:videoID streamFormats:formats device:_device];

		NSError *error = nil;
		if (![_device addStream:_streamSource.stream error:&error]) {
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:[NSString stringWithFormat:@"Failed to add stream: %@", error.localizedDescription] userInfo:nil];
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

- (void)sendJPEG:(NSData *)jpeg mode:(NSUInteger)mode
{
	if (mode != _activeMode) {
		return; // stale frame from before a format switch
	}
	EyeToyMode m = kModes[mode];
	CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
	CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
	if (src) CFRelease(src);
	if (!image) {
		os_log_error(OS_LOG_DEFAULT, "eyetoy: undecodable frame (%lu bytes)", (unsigned long)jpeg.length);
		return;
	}

	CVPixelBufferRef pixelBuffer = NULL;
	OSStatus err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPools[mode], (__bridge CFDictionaryRef)_bufferAuxAttributes, &pixelBuffer);
	if (err || !pixelBuffer) {
		os_log_error(OS_LOG_DEFAULT, "eyetoy: out of pixel buffers %d", err);
		CGImageRelease(image);
		return;
	}

	CVPixelBufferLockBaseAddress(pixelBuffer, 0);
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer), m.width, m.height, 8,
		CVPixelBufferGetBytesPerRow(pixelBuffer), cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
	CGContextDrawImage(ctx, CGRectMake(0, 0, m.width, m.height), image);
	CGContextRelease(ctx);
	CGColorSpaceRelease(cs);
	CGImageRelease(image);
	// BGRA in memory: bytes 0-2 are B, G, R (curve), byte 3 is alpha (NULL = untouched)
	vImage_Buffer buf = {CVPixelBufferGetBaseAddress(pixelBuffer), m.height, m.width, CVPixelBufferGetBytesPerRow(pixelBuffer)};
	vImageTableLookUp_ARGB8888(&buf, &buf, _toneCurve, _toneCurve, _toneCurve, NULL, kvImageNoFlags);
	CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

	CMSampleBufferRef sbuf = NULL;
	CMSampleTimingInfo timingInfo = {.duration = CMTimeMake(1, m.fps), .decodeTimeStamp = kCMTimeInvalid};
	timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
	err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, _videoDescriptions[mode], &timingInfo, &sbuf);
	CFRelease(pixelBuffer);
	if (!err) {
		[_streamSource.stream sendSampleBuffer:sbuf discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:(uint64_t)(CMTimeGetSeconds(timingInfo.presentationTimeStamp) * NSEC_PER_SEC)];
		CFRelease(sbuf);
	}
}

- (void)startCamera
{
	NSUInteger mode = _activeMode;
	__weak EyeToyDeviceSource *weakSelf = self;
	if (!eyetoy_start(kSensorFps, kPowerLineFreq, kModes[mode].qvga, ^(NSData *jpeg) { [weakSelf sendJPEG:jpeg mode:mode]; })) {
		os_log_error(OS_LOG_DEFAULT, "eyetoy: failed to start (not plugged in?)");
	}
}

- (void)setActiveMode:(NSUInteger)activeMode
{
	if (activeMode >= kModeCount || activeMode == _activeMode) {
		return;
	}
	_activeMode = activeMode;
	if (_streamingCounter > 0) {
		eyetoy_stop();
		[self startCamera];
	}
}

- (void)startStreaming
{
	if (_streamingCounter++ > 0) {
		return;
	}
	[self startCamera];
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

- (instancetype)initWithLocalizedName:(NSString *)localizedName streamID:(NSUUID *)streamID streamFormats:(NSArray<CMIOExtensionStreamFormat *> *)streamFormats device:(CMIOExtensionDevice *)device
{
	self = [super init];
	if (self) {
		_device = device;
		_streamFormats = streamFormats;
		_stream = [[CMIOExtensionStream alloc] initWithLocalizedName:localizedName streamID:streamID direction:CMIOExtensionStreamDirectionSource clockType:CMIOExtensionStreamClockTypeHostTime source:self];
	}
	return self;
}

- (NSArray<CMIOExtensionStreamFormat *> *)formats
{
	return _streamFormats;
}

- (NSUInteger)activeFormatIndex
{
	return ((EyeToyDeviceSource *)_device.source).activeMode;
}

- (void)setActiveFormatIndex:(NSUInteger)activeFormatIndex
{
	if (activeFormatIndex >= kModeCount) {
		os_log_error(OS_LOG_DEFAULT, "Invalid index");
		return;
	}
	((EyeToyDeviceSource *)_device.source).activeMode = activeFormatIndex;
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
		CMTime frameDuration = CMTimeMake(1, kModes[self.activeFormatIndex].fps);
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
