/*
 *  AVFoundationVideoGrabber.mm
 */

#include "AVFoundationVideoGrabber.h"
#include "ofxiOSExtras.h"
#include "ofxiOSEAGLView.h"
#include "ofAppRunner.h"


#define IS_IOS_7_OR_LATER    ([[[UIDevice currentDevice] systemVersion] floatValue] >= 7.0)
#define IS_IOS_6_OR_LATER    ([[[UIDevice currentDevice] systemVersion] floatValue] >= 6.0)

#if TARGET_IPHONE_SIMULATOR
#warning Target = iOS Simulator - The AVFoundationVideoGrabber will not function on the iOS Simulator
#endif

//CVOpenGLESTextureCacheRef videoTextureCache = NULL;


@interface iOSVideoGrabber() <AVCaptureVideoDataOutputSampleBufferDelegate> {
	AVCaptureDeviceInput		*captureInput;	
	AVCaptureVideoDataOutput    *captureOutput;
	AVCaptureDevice				*device;
	
	CVOpenGLESTextureCacheRef videoTextureCache;
//	CVOpenGLESTextureRef internalTexture;
	CVImageBufferRef cvFrame;
	BOOL hasNewFrame;
	BOOL isFrameNew;
	BOOL returnPixels;
	size_t texWidth;
	size_t texHeight;
}
@property (nonatomic, retain) AVCaptureSession *captureSession;
@property(readonly) BOOL isFrameNew;

@end

@implementation iOSVideoGrabber

@synthesize captureSession;
@synthesize isFrameNew;

#pragma mark -
#pragma mark Initialization
- (id)init {
	self = [super init];
	if (self) {
		captureInput = nil;
		captureOutput = nil;
		device = nil;

		bInitCalled = NO;
		grabberPtr = NULL;
		cvFrame = NULL;
		hasNewFrame = false;
		isFrameNew = NO;
		deviceID = 0;
        width = 0;
        height = 0;
        currentFrame = 0;
		
		texWidth = 0;
		texHeight = 0;
		
		returnPixels = false;
	}
	return self;
}


- (BOOL)initCapture:(int)framerate capWidth:(int)w capHeight:(int)h needsPixels:(BOOL)bNeedsPixels{
	cvFrame = NULL;
	hasNewFrame = NO;
	returnPixels = bNeedsPixels;
	CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, ofxiOSGetGLView().context, NULL, &videoTextureCache);
	if (err)
	{
		NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
	}
	
	NSArray * devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	
	if([devices count] > 0) {
		if(deviceID>[devices count]-1)
			deviceID = [devices count]-1;
		
		
		// We set the device
		device = [devices objectAtIndex:deviceID];
		
		// iOS 7+ way of dealing with framerates.
        if(IS_IOS_7_OR_LATER) {
            #ifdef __IPHONE_7_0
			NSError *error = nil;
			[device lockForConfiguration:&error];
			if(!error) {
				NSArray * supportedFrameRates = device.activeFormat.videoSupportedFrameRateRanges;
				float minFrameRate = 1;
				float maxFrameRate = 1;
				for(AVFrameRateRange * range in supportedFrameRates) {
					minFrameRate = range.minFrameRate;
					maxFrameRate = range.maxFrameRate;
					break;
				}
				if(framerate < minFrameRate) {
					NSLog(@"iOSVideoGrabber: Framerate set is less than minimum. Setting to Minimum");
					framerate = minFrameRate;
				}
				if(framerate > maxFrameRate) {
					NSLog(@"iOSVideoGrabber: Framerate set is greater than maximum. Setting to Maximum");
					framerate = maxFrameRate;
				}
				device.activeVideoMinFrameDuration = CMTimeMake(1, framerate);
				device.activeVideoMaxFrameDuration = CMTimeMake(1, framerate);
				[device unlockForConfiguration];
			} else {
				NSLog(@"iOSVideoGrabber Init Error: %@", error);
			}
            #endif
        }

		// We setup the input
		captureInput						= [AVCaptureDeviceInput 
											   deviceInputWithDevice:device
											   error:nil];
												
		// We setup the output
		captureOutput = [[AVCaptureVideoDataOutput alloc] init];
		// While a frame is processes in -captureOutput:didOutputSampleBuffer:fromConnection: delegate methods no other frames are added in the queue.
		// If you don't want this behaviour set the property to NO
		captureOutput.alwaysDiscardsLateVideoFrames = YES; 
	
		
		
		// We create a serial queue to handle the processing of our frames
		dispatch_queue_t queue;
		queue = dispatch_queue_create("cameraQueue", NULL);
		[captureOutput setSampleBufferDelegate:self queue:queue];
		dispatch_release(queue);
		
		// Set the video output to store frame in BGRA (It is supposed to be faster)
		NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey; 
		NSNumber* value = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA]; 

		NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:value forKey:key]; 
		[captureOutput setVideoSettings:videoSettings];

		// And we create a capture session
		if(self.captureSession) {
			self.captureSession = nil;
		}
		self.captureSession = [[[AVCaptureSession alloc] init] autorelease];
		
		[self.captureSession beginConfiguration];
	
		
		
//		NSString * preset = AVCaptureSessionPresetMedium;
		NSString * preset = AVCaptureSessionPreset1280x720;
		width	= w;
		height	= h;
		
		texWidth = w;
		texHeight = h;

		
		if(ofxiOSGetDeviceRevision() == ofxiOS_DEVICE_IPHONE_3G) {
			width = 400;
			height = 304;
		}
		else {
			if( w == 640 && h == 480 ){
				preset = AVCaptureSessionPreset640x480;
				width	= w;
				height	= h;
			}
			else if( w == 1280 && h == 720 ){
				preset = AVCaptureSessionPreset1280x720;
				width	= w;
				height	= h;		
			}
			else if( w == 1920 && h == 1080 ){
				preset = AVCaptureSessionPreset1920x1080;
				width	= w;
				height	= h;
			}
			else if( w == 192 && h == 144 ){
				preset = AVCaptureSessionPresetLow;
				width	= w;
				height	= h;		
			}
		}
		[self.captureSession setSessionPreset:preset]; 
		
		// We add input and output
		[self.captureSession addInput:captureInput];
		[self.captureSession addOutput:captureOutput];
		
		// We specify a minimum duration for each frame (play with this settings to avoid having too many frames waiting
		// in the queue because it can cause memory issues). It is similar to the inverse of the maximum framerate.
		// In this example we set a min frame duration of 1/10 seconds so a maximum framerate of 10fps. We say that
		// we are not able to process more than 10 frames per second.
		// Called after added to captureSession
        
        if(IS_IOS_7_OR_LATER == false) {
            if(IS_IOS_6_OR_LATER) {
                #ifdef __IPHONE_6_0
                AVCaptureConnection *conn = [captureOutput connectionWithMediaType:AVMediaTypeVideo];
                if ([conn isVideoMinFrameDurationSupported] == YES &&
                    [conn isVideoMaxFrameDurationSupported] == YES) { // iOS 6+
                        [conn setVideoMinFrameDuration:CMTimeMake(1, framerate)];
                        [conn setVideoMaxFrameDuration:CMTimeMake(1, framerate)];
                }
                #endif
            } else { // iOS 5 or earlier
                [captureOutput setMinFrameDuration:CMTimeMake(1, framerate)];
            }
        }
		
		
		
		// We start the capture Session
		[self.captureSession commitConfiguration];		
		[self.captureSession startRunning];
		
		


		bInitCalled = YES;
		return YES;
	}
	return NO;
}

//from http://stackoverflow.com/questions/20864372/switch-cameras-with-avcapturesession
-(void) switchCamera{
	//Change camera source
	if(self.captureSession)
	{
		
		//Indicate that some changes will be made to the session
		[self.captureSession beginConfiguration];
		
		//Remove existing input
		AVCaptureInput* currentCameraInput = [self.captureSession.inputs objectAtIndex:0];
		[self.captureSession removeInput:currentCameraInput];
		
		//Get new input
		AVCaptureDevice *newCamera = nil;
		if(((AVCaptureDeviceInput*)currentCameraInput).device.position == AVCaptureDevicePositionBack)
		{
			newCamera = [self cameraWithPosition:AVCaptureDevicePositionFront];
		}
		else
		{
			newCamera = [self cameraWithPosition:AVCaptureDevicePositionBack];
		}
		
		//Add input to session
		NSError *err = nil;
		AVCaptureDeviceInput *newVideoInput = [[AVCaptureDeviceInput alloc] initWithDevice:newCamera error:&err];
		if(!newVideoInput || err)
		{
			NSLog(@"Error creating capture device input: %@", err.localizedDescription);
		}
		else
		{
			[self.captureSession addInput:newVideoInput];
		}
		
		//Commit all the configuration changes at once
		[self.captureSession commitConfiguration];
		 
		cout<<"test"<<endl;
	}
}



// Find a camera with the specified AVCaptureDevicePosition, returning nil if one is not found
- (AVCaptureDevice *) cameraWithPosition:(AVCaptureDevicePosition) position
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	for (AVCaptureDevice *device_ in devices)
	{
		if ([device_ position] == position) return device_;
	}
	return nil;
}

-(void) startCapture{

	if( !bInitCalled ){
		[self initCapture:30 capWidth:480 capHeight:360 needsPixels:NO];
	}
	
	[self.captureSession startRunning];
	
	[captureInput.device lockForConfiguration:nil];
	
	//if( [captureInput.device isExposureModeSupported:AVCaptureExposureModeAutoExpose] ) [captureInput.device setExposureMode:AVCaptureExposureModeAutoExpose ];
	if( [captureInput.device isFocusModeSupported:AVCaptureFocusModeAutoFocus] )	[captureInput.device setFocusMode:AVCaptureFocusModeAutoFocus ];

}



// focus

-(bool) setContinuousAutoFocus{
	return [self _setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
}

-(bool) focusOnce{
	return [self _setFocusMode:AVCaptureFocusModeAutoFocus];
}

-(bool) lockFocus{
	return [self _setFocusMode:AVCaptureFocusModeLocked];
}

-(bool)touchFocusAt:(CGPoint)focusPoint{
	bool r = false;
	AVCaptureInput* currentCameraInput = [self.captureSession.inputs objectAtIndex:0];
	AVCaptureDevice *acd = ((AVCaptureDeviceInput*)currentCameraInput).device;
	
	//the facetime camera can not focus per apple spec
	if(acd.focusPointOfInterestSupported){
		[acd lockForConfiguration:nil];
		acd.focusPointOfInterest = focusPoint;
		r = [self focusOnce];
//		NSLog(@"focusOnce: %d", r);
		[acd unlockForConfiguration];
	}
	
	return r;
}

-(bool)_setFocusMode:(AVCaptureFocusMode)mode{
	bool r = true;
	
	AVCaptureInput* currentCameraInput = [self.captureSession.inputs objectAtIndex:0];
	AVCaptureDevice *acd = ((AVCaptureDeviceInput*)currentCameraInput).device;
    [acd lockForConfiguration:nil];
	if( [acd isFocusModeSupported:mode]){
		[acd setFocusMode:mode];
	} else {
		r = false;
	}
	[acd unlockForConfiguration];
	
	return r;
}


-(void) lockExposureAndFocus{

	[captureInput.device lockForConfiguration:nil];
	//if( [captureInput.device isExposureModeSupported:AVCaptureExposureModeLocked] ) [captureInput.device setExposureMode:AVCaptureExposureModeLocked ];
	if( [captureInput.device isFocusModeSupported:AVCaptureFocusModeLocked] )	[captureInput.device setFocusMode:AVCaptureFocusModeLocked ];
	
	
}

-(void)stopCapture{
	if(self.captureSession) {
		if(captureOutput){
			if(captureOutput.sampleBufferDelegate != nil) {
				[captureOutput setSampleBufferDelegate:nil queue:NULL];
			}
		}
		
		// remove the input and outputs from session
		for(AVCaptureInput *input1 in self.captureSession.inputs) {
		    [self.captureSession removeInput:input1];
		}
		for(AVCaptureOutput *output1 in self.captureSession.outputs) {
		    [self.captureSession removeOutput:output1];
		}
		
		[self.captureSession stopRunning];
	}
}

-(CGImageRef)getCurrentFrame{
	return currentFrame;
}

-(vector <string>)listDevices{
    vector <string> deviceNames;
	NSArray * devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	int i=0;
	for (AVCaptureDevice * captureDevice in devices){
        deviceNames.push_back([captureDevice.localizedName UTF8String]);
		 ofLogNotice() << "Device: " << i << ": " << deviceNames.back();
		i++;
    }
    return deviceNames; 
}

-(void)setDevice:(int)_device{
	deviceID = _device;
}

#pragma mark -
#pragma mark AVCaptureSession delegate
- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	   fromConnection:(AVCaptureConnection *)connection
{
	if(grabberPtr != NULL) {
		if(returnPixels){
//			pixel stuff
			@autoreleasepool {
				CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
				// Lock the image buffer
	
				CVPixelBufferLockBaseAddress(imageBuffer,0);
	
				if(grabberPtr != NULL && grabberPtr->internalGlDataType == GL_BGRA) {
	
					unsigned int *isrc4 = (unsigned int *)CVPixelBufferGetBaseAddress(imageBuffer);
	
					unsigned int *idst4 = (unsigned int *)grabberPtr->pixels;
					unsigned int *ilast4 = &isrc4[width*height-1];
					while (isrc4 < ilast4){
						*(idst4++) = *(isrc4++);
					}
					grabberPtr->newFrame=true;
					CVPixelBufferUnlockBaseAddress(imageBuffer,0);
	
				} else {
					// Get information about the image
					uint8_t *baseAddress	= (uint8_t *)CVPixelBufferGetBaseAddress(imageBuffer);
					size_t bytesPerRow		= CVPixelBufferGetBytesPerRow(imageBuffer);
					size_t widthIn			= CVPixelBufferGetWidth(imageBuffer);
					size_t heightIn			= CVPixelBufferGetHeight(imageBuffer);
	
					// Create a CGImageRef from the CVImageBufferRef
					CGColorSpaceRef colorSpace	= CGColorSpaceCreateDeviceRGB();
	
					CGContextRef newContext		= CGBitmapContextCreate(baseAddress, widthIn, heightIn, 8, bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
					CGImageRef newImage			= CGBitmapContextCreateImage(newContext);
	
					CGImageRelease(currentFrame);
					currentFrame = CGImageCreateCopy(newImage);
	
					// We release some components
					CGContextRelease(newContext);
					CGColorSpaceRelease(colorSpace);
	
					// We relase the CGImageRef
					CGImageRelease(newImage);
	
					// We unlock the  image buffer
					CVPixelBufferUnlockBaseAddress(imageBuffer,0);
	
	
					if(grabberPtr != NULL && grabberPtr->bLock != true) {
						grabberPtr->updatePixelsCB(currentFrame);
					}
				}
			}
		}else {
			//texture stuff
			CVOpenGLESTextureRef internalTexture = NULL;
			CVImageBufferRef toRelease;
			@synchronized (self) {
				toRelease = cvFrame;
				CVBufferRetain(CMSampleBufferGetImageBuffer(sampleBuffer));
				cvFrame = CMSampleBufferGetImageBuffer(sampleBuffer);
				hasNewFrame = YES;
				if(toRelease){
					CVBufferRelease(toRelease);
				}
			}
		}
	}
}


- (void) updateTexture{
	@synchronized (self) {
		if(hasNewFrame){
			CVOpenGLESTextureRef internalTexture = NULL;
			CVPixelBufferLockBaseAddress(cvFrame, 0);
			
				if (!videoTextureCache){
					NSLog(@"No video texture cache");
					return;
				}
				
				CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(
																			kCFAllocatorDefault,
																			videoTextureCache,
																			cvFrame,
																			NULL,
																			GL_TEXTURE_2D,
																			GL_RGBA,
																			texWidth,
																			texHeight,
																			GL_BGRA,
																			GL_UNSIGNED_BYTE,
																			0,
																			&internalTexture);
				
				if (err){
					NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
				}
				
				unsigned int textureCacheID = CVOpenGLESTextureGetName(internalTexture);
				grabberPtr->texture.setUseExternalTextureID(textureCacheID);
				grabberPtr->texture.setTextureMinMagFilter(GL_LINEAR, GL_LINEAR);
				grabberPtr->texture.setTextureWrap(GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE);
				
				if(!ofIsGLProgrammableRenderer()) {
					grabberPtr->texture.bind();
					glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
					grabberPtr->texture.unbind();
				}
			
			CVPixelBufferUnlockBaseAddress(cvFrame, 0);
			
			CVOpenGLESTextureCacheFlush(videoTextureCache, 0);
			if(internalTexture) {
				CFRelease(internalTexture);
				internalTexture = NULL;
			}
			
			hasNewFrame = NO;
			isFrameNew = YES;
		} else {
			isFrameNew = NO;
		}
	}
}




#pragma mark -
#pragma mark Memory management

- (void)dealloc {
	// Stop the CaptureSession
	if(self.captureSession) {
		[self stopCapture];
		self.captureSession = nil;
	}
	if(captureOutput){
		if(captureOutput.sampleBufferDelegate != nil) {
			[captureOutput setSampleBufferDelegate:nil queue:NULL];
		}
		[captureOutput release];
		captureOutput = nil;
	}
	
	captureInput = nil;
	device = nil;
	
	if(grabberPtr) {
		[self eraseGrabberPtr];
	}
	grabberPtr = nil;
	if(currentFrame) {
		// release the currentFrame image
		CGImageRelease(currentFrame);
		currentFrame = nil;
	}
    [super dealloc];
}

- (void)eraseGrabberPtr {
	grabberPtr = NULL;
}

@end


AVFoundationVideoGrabber::AVFoundationVideoGrabber(){
	fps		= 30;
	grabber = [iOSVideoGrabber alloc];
	pixels	= NULL;
    width = 0;
    height = 0;
	
	internalGlDataType = GL_RGB;
	newFrame = false;
	bHavePixelsChanged = false;
	bLock = false;
}

AVFoundationVideoGrabber::~AVFoundationVideoGrabber(){
	ofLog(OF_LOG_VERBOSE, "AVFoundationVideoGrabber dtor");
	bLock = true;
	if(grabber) {
		// Stop and release the the iOSVideoGrabber
		[grabber stopCapture];
		[grabber eraseGrabberPtr];
		[grabber release];
		grabber = nil;
	}
	clear();

}


void AVFoundationVideoGrabber::switchCamera(){
	if(grabber){
		[grabber switchCamera];
	}
}


void AVFoundationVideoGrabber::clear(){
	
	if( pixels != NULL ){
		free(pixels);
		pixels = NULL;
		free(pixelsTmp);
	}
	texture.clear();
}

void AVFoundationVideoGrabber::setCaptureRate(int capRate){
	fps = capRate;
}

bool AVFoundationVideoGrabber::initGrabber(int w, int h, bool bNp){
	if( [grabber initCapture:fps capWidth:w capHeight:h needsPixels:bNp] ) {
		grabber->grabberPtr = this;
		
		bNeedsPixels = bNp;
		
		if(ofGetOrientation() == OF_ORIENTATION_DEFAULT || ofGetOrientation() == OF_ORIENTATION_180) {
			width = grabber->height;
			height = grabber->width;
		} else {
			width	= grabber->width;
			height	= grabber->height;
		}
		
		clear();
		texture.allocate(w, h, GL_RGBA);
		ofTextureData & texData = texture.getTextureData();
		texData.tex_t = 1.0f; // these values need to be reset to 1.0 to work properly.
		texData.tex_u = 1.0f; // assuming this is something to do with the way ios creates the texture cache.
		
		pixelsTmp	= (GLubyte *) malloc(width * height * 4);

		if(internalGlDataType == GL_RGB) {
			pixels = (GLubyte *) malloc(width * height * 3);//new unsigned char[width * width * 3];//memset(pixels, 0, width*height*3);
		} else if(internalGlDataType == GL_RGBA) {
			pixels = (GLubyte *) malloc(width * height * 4);
		} else if(internalGlDataType == GL_BGRA) {
			pixels = (GLubyte *) malloc(width * height * 4);
		}
		
		
		[grabber startCapture];
		
		newFrame=false;
		bIsInit = true;
		
		return true;
	} else {
		return false;
	}
}

void AVFoundationVideoGrabber::startCapture(){
	[grabber startCapture];
}

void AVFoundationVideoGrabber::stopCapture(){
	[grabber stopCapture];
}

bool AVFoundationVideoGrabber::isInitialized(){
    return bIsInit;
}

void AVFoundationVideoGrabber::update(){
	if(bNeedsPixels){
		newFrame = false;
		if (bHavePixelsChanged == true){
			newFrame = true;
			bHavePixelsChanged = false;
		}
	} else {
		if(bIsInit){
			[grabber updateTexture];
		}
	}
}

void AVFoundationVideoGrabber::focusOnce(){
	
}

void AVFoundationVideoGrabber::lockFocus(){
	
}

void AVFoundationVideoGrabber::touchFocusAt(ofPoint pt){
	[grabber touchFocusAt:CGPointMake(pt.x, pt.y)];
}

void AVFoundationVideoGrabber::setContinuousAutoFocus(){
	[grabber setContinuousAutoFocus];
}

void AVFoundationVideoGrabber::updatePixelsCB( CGImageRef & ref ){
	
	if(bLock) {
		return;
	}
	
	CGAffineTransform transform = CGAffineTransformIdentity;
	
	CGContextRef spriteContext;
	if(pixelsTmp != NULL) {
		// Uses the bitmap creation function provided by the Core Graphics framework. 
		spriteContext = CGBitmapContextCreate(pixelsTmp, width, height, CGImageGetBitsPerComponent(ref), width * 4, CGImageGetColorSpace(ref), kCGImageAlphaPremultipliedLast);
		
		if(ofGetOrientation() == OF_ORIENTATION_DEFAULT) {
			transform = CGAffineTransformMakeTranslation(0.0, height);
			transform = CGAffineTransformRotate(transform, 3.0 * M_PI / 2.0);
				
			CGContextConcatCTM(spriteContext, transform);
			CGContextDrawImage(spriteContext, CGRectMake(0.0, 0.0, (CGFloat)height, (CGFloat)width), ref);
		} else if(ofGetOrientation() == OF_ORIENTATION_180) {
			transform = CGAffineTransformMakeTranslation(width, 0.0);
			transform = CGAffineTransformRotate(transform, M_PI / 2.0);
			
			CGContextConcatCTM(spriteContext, transform);
			CGContextDrawImage(spriteContext, CGRectMake(0.0, 0.0, (CGFloat)height, (CGFloat)width), ref);
		} else if(ofGetOrientation() == OF_ORIENTATION_90_LEFT) {
			CGContextDrawImage(spriteContext, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), ref);
		} else { // landscape RIGHT
			transform = CGAffineTransformMakeTranslation(width, height);
			transform = CGAffineTransformScale(transform, -1.0, -1.0);
			
			CGContextConcatCTM(spriteContext, transform);
			CGContextDrawImage(spriteContext, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), ref);
		}
		
		if(bLock) {
			return;
		}
		
		CGContextRelease(spriteContext);
		
		if(internalGlDataType == GL_RGB) {
			unsigned int *isrc4 = (unsigned int *)pixelsTmp;
			unsigned int *idst3 = (unsigned int *)pixels;
			unsigned int *ilast4 = &isrc4[width*height-1];
			while (isrc4 < ilast4){
				if(bLock) {
					return;
				}
				*(idst3++) = *(isrc4++);
				idst3 = (unsigned int *) (((unsigned char *) idst3) - 1);
			}
		}
		
		else if(internalGlDataType == GL_RGBA || internalGlDataType == GL_BGRA){
			if(bLock) {
				return;
			}
			memcpy(pixels, pixelsTmp, width*height*4);
		}
	
		bHavePixelsChanged=true;
	}
}

bool AVFoundationVideoGrabber::isFrameNew() {
	return newFrame;
}

ofTexture * AVFoundationVideoGrabber::getTexture() {
	return &texture;
}

vector <ofVideoDevice> AVFoundationVideoGrabber::listDevices() {
	vector <string> devList = [grabber listDevices];
    
    vector <ofVideoDevice> devices; 
    for(int i = 0; i < devList.size(); i++){
        ofVideoDevice vd; 
        vd.deviceName = devList[i]; 
        vd.id = i;  
        vd.bAvailable = true; 
        devices.push_back(vd); 
    }
    
    return devices; 
}

void AVFoundationVideoGrabber::setDevice(int deviceID) {
	[grabber setDevice:deviceID];
	device = deviceID;
}

bool AVFoundationVideoGrabber::setPixelFormat(ofPixelFormat PixelFormat) {
	if(PixelFormat == OF_PIXELS_RGB){
		internalGlDataType = GL_RGB;
		return true;
	} else if(PixelFormat == OF_PIXELS_RGBA){
		internalGlDataType = GL_RGBA;
		return true;
	} else if(PixelFormat == OF_PIXELS_BGRA){
		internalGlDataType = GL_BGRA;
		return true;
	}
	return false;
}

ofPixelFormat AVFoundationVideoGrabber::getPixelFormat() {
	if(internalGlDataType == GL_RGB){
        return OF_PIXELS_RGB;
	} else if(internalGlDataType == GL_RGBA){
        return OF_PIXELS_RGBA;
	} else if(internalGlDataType == GL_BGRA){
        return OF_PIXELS_BGRA;
    } else {
        return OF_PIXELS_RGB;
	}
}



