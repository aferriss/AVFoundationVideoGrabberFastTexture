This can replace the stock video grabber for ios.

It can be used like:
````
AVFoundationVideoGrabber grabber;

void ofApp::setup(){
	grabber.setDevice(0); // 0 is typically back camera, 1 is front camera
	grabber.initGrabber(1280, 720); // an optional third parameter can be used if you want the pixels instead 
}

void ofApp::update(){
	grabber.update();
}

void ofApp::draw(){
	grabber.getTexture()->draw(0,0);
}
````
I also added a function for switching between the front and back camera:
`grabber.switchCamera();`

And lastly a function for focus
````
void ofApp::touchDoubleTap(ofTouchEventArgs & touch){
    grabber.touchFocusAt(ofPoint(touch.x, touch.y));
    
}
````

TODO: 
Auto select closest resolution based on device. Right now it will ignore your width and height and auto select 1280x720.