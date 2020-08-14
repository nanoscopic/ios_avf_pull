#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#include <turbojpeg.h>
#include "uclop.h"
#include<nanomsg/nn.h>
#include<nanomsg/pipeline.h>
#include<stdint.h>
#include<sys/time.h>
#include<stdio.h>

int mynano__new( char *spec, int bind ) {
    int sock = nn_socket( AF_SP, bind ? NN_PULL : NN_PUSH );
    int seconds = 1000;
    nn_setsockopt( sock, NN_SOL_SOCKET, NN_SNDTIMEO, &seconds, sizeof( seconds ) );
    if( sock < 0 ) { NSLog( @"nanomsg socket creation err: %d", sock ); exit(1); }
    int rv;
    if( bind ) rv = nn_bind( sock, spec );
    else       rv = nn_connect( sock, spec );
    if( rv < 0 ) { NSLog( @"nanomsg bind/connect err: %d", rv ); exit(1); }
    return sock; 
}

void setup_nanomsg_socket( char *nanoSpec, int *nanoOut ) {
    if( nanoSpec ) {
        *nanoOut = mynano__new( nanoSpec, 0 ); // 0 means connect to socket
        NSLog(@"Send data to nanomsg %s", nanoSpec );
    }
    else *nanoOut = -1;
}

void mynano__send( int n, void *data, int size ) {
    int sent = nn_send( n, data, size, 0 );
    if( sent != size ) {
        NSLog(@"Send failed; sent=%d, size=%d", sent, size );
    }
}

void mynano__send_jpeg( unsigned char *data, unsigned long dataLen, int n, int ow, int oh, int dw, int dh ) {
    if(n) {
        char buffer[200];
        int jlen = snprintf( buffer, 200, "{\"ow\":%i,\"oh\":%i,\"dw\":%i,\"dh\":%i}", ow, oh, dw, dh );
        long unsigned int totlen = dataLen + jlen;
        char *both = malloc( totlen );
        memcpy( both, buffer, jlen );
        memcpy( &both[jlen], data, dataLen );
        mynano__send( n, both, totlen );
        free( both );
    }
}

void write_jpeg( unsigned char *data, unsigned long dataLen, char *filename ) {
    if( filename ) {
        FILE *fh = fopen( filename, "wb" );
        if( !fh ) {
            fprintf(stderr,"Can't open %s for writing", filename );
        }
        fwrite( data, 1, dataLen, fh );
        fclose( fh );
    }
}

const uint8_t difmap[ 17 ] = {
  0, // -16
  1, // -32
  3, // -48
  10, // -64
  10, // -80
  20, // -96
  20, // -112
  40, // -128
  40, // -144
  80, // -160
  80, // -176
  160, // -192
  160, // 208 
  255, // 224
  255, // 240
  255, // 256
  255
};

char frameDif( unsigned char *f1, unsigned char *f2, int l1, int w, int h, int verbose ) {
    uint64_t totDif = 0;
    for( int y=0;y<h;y++ ) {
        if( y%3 ) continue;
        int lstart = l1 * y;
        uint8_t *d1 = (uint8_t *) &f1[0] + lstart;
        uint8_t *d2 = (uint8_t *) &f2[0] + lstart;
        for( int x=0;x<w;x+=9,d1+=12,d2+=12 ) {
            uint8_t r1 = *d1;
            uint8_t g1 = *(d1+1);
            uint8_t b1 = *(d1+2);
            uint8_t r2 = *d2;
            uint8_t g2 = *(d2+1);
            uint8_t b2 = *(d2+2);
            
            uint8_t dr = abs( r1-r2 ) >> 4; 
            uint8_t dg = abs( g1-g2 ) >> 4;
            uint8_t db = abs( b1-b2 ) >> 4;
            
            totDif += difmap[dr] + difmap[dg] + difmap[db];
        }
        //if( totDif > 2500 ) return 1;
    }
    //printf("dif: %lli\n", (long long ) totDif );
    if( verbose ) NSLog(@"dif: %lli\n", (long long) totDif );
    if( totDif > 2500 ) return 1;
    return 0;
}

int64_t timespecDiff(struct timespec *timeA_p, struct timespec *timeB_p) {
  return ((timeA_p->tv_sec * 1000000000) + timeA_p->tv_nsec) - ((timeB_p->tv_sec * 1000000000) + timeB_p->tv_nsec);
}

@interface RecodeDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (assign) tjhandle compressor;
@property (assign) int quality;
@property (assign) int subsampling;
@property (assign) int format;
@property (assign) int bufferSize;
@property (assign) unsigned char *jpegData;
@property (assign) unsigned long jpegSize;
@property (assign) int bufferAllocated;
@property (assign) int prevNum;
@property (assign) int wroteJpeg;
@property (assign) char *outFile;
@property (assign) CMSampleBufferRef prevSample;
@property (assign) unsigned char *prevBgra;
@property (assign) CVImageBufferRef prevIbuf;
@property (assign) int verbose;
@property (assign) int outSock;
@property (assign) int frameSkip;
@property (assign) int frameNum;
@property (assign) struct timespec prevTime;

@end

@implementation RecodeDelegate

- (id) initWithFile:(char *)outFile andVerbose:(int)verbose andFrameSkip:(int)frameSkip {
    [super init];
    
    _compressor = tjInitCompress();
    _quality = 80;
    _subsampling = TJSAMP_420;
    _jpegSize = 0;
    _prevNum = 0;
    _wroteJpeg = 0;
    _outFile = outFile;
    _prevBgra = NULL;
    _prevSample = NULL;
    _verbose = verbose;
    _outSock = -1;
    _frameSkip = frameSkip;
    _frameNum = 0;
    
    return self;
}

- (void) captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CFRetain(sampleBuffer);
    CVImageBufferRef ibuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    CVPixelBufferLockBaseAddress(ibuf, kCVPixelBufferLock_ReadOnly);
    
    int width = CVPixelBufferGetWidth(ibuf);
    int height = CVPixelBufferGetHeight(ibuf);
    unsigned char *bgra = CVPixelBufferGetBaseAddress(ibuf);
    int size = CVPixelBufferGetDataSize(ibuf);
    int bytesPerRow = CVPixelBufferGetBytesPerRow(ibuf);
    
    if( !_bufferAllocated ) {
        _bufferSize = tjBufSize( width, height, _subsampling );
        _jpegData = tjAlloc(_bufferSize);
        _bufferAllocated = 1;
    }
    
    int dif = 1;
    
    struct timespec curTime;
    clock_gettime(CLOCK_MONOTONIC, &curTime);
    if( _prevBgra ) {
        dif = frameDif( _prevBgra, bgra, bytesPerRow, width, height, _verbose );
        
        if( !dif ) {
            int64_t timeDif = timespecDiff( &curTime, &_prevTime );
            if( ( (double) timeDif / ( double ) 1000000 ) >= 1000 ) {
                dif = 1;
            }
        }
    }
    
    _frameNum++;
    
    if( _verbose ) NSLog(@"Width: %d Height: %d Changed:%d\n", width, height, dif );
    
    // Only if we decided to use the new frame
    if( dif ) {
        if( _frameSkip && _frameNum >= _frameSkip ) _frameNum = 0;
    
        if( _prevBgra ) {
            CVPixelBufferUnlockBaseAddress( _prevIbuf, kCVPixelBufferLock_ReadOnly );
            CFRelease( _prevSample );
        }
        _prevBgra = bgra;
        _prevIbuf = ibuf;
        _prevSample = sampleBuffer;
        _prevTime = curTime;
        
        int res = tjCompress2(
            _compressor,
            bgra,
            width,
            bytesPerRow,
            height,
            TJPF_BGRA,
            &_jpegData,
            &_jpegSize,
            _subsampling,
            _quality,
            TJFLAG_FASTDCT | TJFLAG_NOREALLOC );
        if( res < 0 ) {
            // error
        }
        
        if( _outFile && !_wroteJpeg ) {
            write_jpeg( _jpegData, _jpegSize, _outFile );
            NSLog(@"Wrote JPEG; File:%s Width: %d Height: %d\n", _outFile, width, height );
            _wroteJpeg = 1;
        }
        if( _outSock == -1 ) {
            _outSock = nn_socket( AF_SP, NN_PUSH );
            nn_connect( _outSock, "inproc://img");
        }
            
        if( _outSock != -1 ) {
            if( _frameSkip ) {
                if( _frameNum == 0 ) mynano__send_jpeg( _jpegData, _jpegSize, _outSock, width, height, width, height );
            }
            else mynano__send_jpeg( _jpegData, _jpegSize, _outSock, width, height, width, height );
            //if( verbose ) NSLog(@"Sent JPEG; Width: %d Height: %d Size:%ld\n", width, height, _jpegSize );
        }
    } else {
        CVPixelBufferUnlockBaseAddress(ibuf, kCVPixelBufferLock_ReadOnly);
        CFRelease(sampleBuffer);
    }
}

@end

int run_stream( ucmd *cmd, char *udidIn, int nanoOut, char *outFile, int verbose, int frameSkip );

void run_nano( ucmd *cmd ) {
    int nanoOut = -1;
    
    char *nanoSpec = ucmd__get(cmd,"--out");
    setup_nanomsg_socket( nanoSpec, &nanoOut );
    char *outFile = ucmd__get(cmd,"--file");
    char *udid = ucmd__get(cmd,"--udid");
    char *verbose = ucmd__get(cmd,"--v");
    if( verbose ) {
        NSLog(@"Running in verbose mode\n");
    }
    int frameSkip = 0;
    char *frameSkipS = ucmd__get(cmd,"--frameSkip");
    if( frameSkipS ) {
        frameSkip = atoi( frameSkipS );
    }
    run_stream( cmd, udid, nanoOut, outFile, verbose ? 1 : 0, frameSkip );
}

void list_devs( ucmd *cmd ) {
    @autoreleasepool {
        CMIOObjectPropertyAddress prop = {
            kCMIOHardwarePropertyAllowScreenCaptureDevices,
            kCMIOObjectPropertyScopeGlobal,
            kCMIOObjectPropertyElementMaster
        };
        UInt32 allow = 1;
        CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &prop, 0, NULL, sizeof(allow), &allow );
    
        //NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeMuxed];
        NSArray<AVMediaType> *device_types = [NSArray arrayWithObjects: AVCaptureDeviceTypeExternalUnknown, nil];
        AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:device_types mediaType:AVMediaTypeMuxed position:0];
        NSArray<AVCaptureDevice *> *devices = [session devices];
        
        uint8_t count = [devices count];
        for (AVCaptureDevice *device in devices) {
            const char *name = [[device localizedName] UTF8String];
            const char *id = [[device uniqueID] UTF8String];
            //index            = [devices count] + [devices_muxed indexOfObject:device];
            printf("--Device--\n  Name:%s\n  UDID:%s\n", name, id );
        }
    }
}

void run_version( ucmd *cmd ) {
    printf("Commit:" GitCommit "\nDate:" GitDate "\nRemote:" GitRemote "\nVersion:" EasyVersion "\n" );
}

int main( int argc, char *argv[] ) {
    uopt *nano_options[] = {
        UOPT_REQUIRED("--udid","UDID of device to stream"),
        UOPT("--out","Nanomsg output spec"),
        UOPT("--file","File to output a single frame to"),
        UOPT("--frameSkip","Frame skip mod; 2=half frames, 3=1/3 frames"),
        UOPT("--dw","Destination width"),
        UOPT("--dh","Destination height"),
        UOPT_FLAG("--v","Verbose mode"),
        NULL
    };
    uclop *opts = uclop__new( NULL, NULL );
    uclop__addcmd( opts, "nano", "Stream using nanomsg", &run_nano, nano_options );
    uclop__addcmd( opts, "version", "Version info", &run_version, NULL );
    uclop__addcmd( opts, "list", "List IOS devices", &list_devs, NULL );
    uclop__run( opts, argc, argv );
    return 0;
}

int run_stream( ucmd *cmd, char *udidIn, int nanoOut, char *outFile, int verbose, int frameSkip ) {
    @autoreleasepool {
        NSString *udid = [NSString stringWithUTF8String:udidIn];
        NSString *nospace = [udid stringByReplacingOccurrencesOfString:@"-" withString:@""];
        NSString *lower = [nospace lowercaseString];
        
        CMIOObjectPropertyAddress prop = {
            kCMIOHardwarePropertyAllowScreenCaptureDevices,
            kCMIOObjectPropertyScopeGlobal,
            kCMIOObjectPropertyElementMaster
        };
        UInt32 allow = 1;
        CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &prop, 0, NULL, sizeof(allow), &allow );
        
        for (int i = 0 ; i < 10; i++) {
            if( [AVCaptureDevice deviceWithUniqueID: lower] != nil ) break;
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    
        AVCaptureDevice *device = [AVCaptureDevice deviceWithUniqueID: lower];
            
        if( device == nil ) {
            NSLog(@"device with udid '%@' not found", udid);
            return 1;
        }
        
        AVCaptureSession * session = [[AVCaptureSession alloc] init];
        
        [session beginConfiguration];
        
        NSError *error;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if( input == nil ) {
            NSLog(@"%@", error);
            return false;
        }
        
        [session addInput:input];
        
        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = YES;
        
        output.videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
            AVVideoScalingModeResizeAspect, (id)AVVideoScalingModeKey,
            //[NSNumber numberWithUnsignedInt:1080], (id)kCVPixelBufferWidthKey,
            //[NSNumber numberWithUnsignedInt:1920], (id)kCVPixelBufferHeightKey,
            [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA], (id)kCVPixelBufferPixelFormatTypeKey,
            nil
        ];

        dispatch_queue_t que = dispatch_queue_create("com.devicefarmer.que", DISPATCH_QUEUE_SERIAL);
        
        int sock = nn_socket( AF_SP, NN_PULL );
        nn_bind( sock, "inproc://img");
        
        RecodeDelegate *recoder = [[RecodeDelegate alloc] initWithFile:outFile andVerbose:verbose andFrameSkip:frameSkip];
        
        [output setSampleBufferDelegate:recoder queue:que];
        
        [session addOutput:output];
        [session commitConfiguration];
        
        [session startRunning];
        
        
        void *buf;
        while(1) {
            int bytes = nn_recv( sock, &buf, NN_MSG, 0 );
            nn_send( nanoOut, buf, bytes, 0 );
            nn_freemsg( buf );
        }
        
        [session stopRunning];
    }
    return 0;
}