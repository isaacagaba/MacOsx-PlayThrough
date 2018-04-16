//
//  Recorder.m
//  MicrophoneTest
//
//  Created by agaba isaac on 4/11/18.
//  Copyright © 2018 agaba isaac. All rights reserved.
//

#import "Recorder.h"
#import <AudioToolbox/AudioToolbox.h>

#define kNumberRecordBuffers 3

typedef struct MyPlayer {
    AudioQueueRef                queue; // the audio queue object
    AudioStreamBasicDescription dataFormat; // file's data stream description
    AudioFileID                    playbackFile; // reference to your output file
    SInt64                        packetPosition; // current packet index in output file
    UInt32                        numPacketsToRead; // number of packets to read from file
    AudioStreamPacketDescription *packetDescs; // array of packet descriptions for read buffer
    // AudioQueueBufferRef            buffers[kNumberPlaybackBuffers];
    Boolean                        isDone; // playback has completed
    UInt32                        playBufferByteSize;
    struct MyRecorder *recorder;
} MyPlayer;

typedef struct MyRecorder {
    AudioQueueRef recordQueue;
    AudioFileID                    recordFile; // reference to your output file
    SInt64                        recordPacket; // current packet index in output file
    Boolean                        running; // recording state
    MyPlayer    *player;
} MyRecorder;


OSStatus MyGetDefaultInputDeviceSampleRate(Float64 *outSampleRate);


#pragma mark - utility functions -

// generic error handler - if error is nonzero, prints error message and exits program.
static void CheckError(OSStatus error, const char *operation)
{
    if (error == noErr) return;
    
    char errorString[20];
    // see if it appears to be a 4-char-code
    *(UInt32 *)(errorString + 1) = CFSwapInt32HostToBig(error);
    if (isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else
        // no, format it as an integer
        sprintf(errorString, "%d", (int)error);
    
    fprintf(stderr, "Error: %s (%s)\n", operation, errorString);
    
    exit(1);
}

// get sample rate of the default input device
OSStatus MyGetDefaultInputDeviceSampleRate(Float64 *outSampleRate)
{
    OSStatus error;
    AudioDeviceID deviceID = 0;
    
    // get the default input device
    AudioObjectPropertyAddress propertyAddress;
    UInt32 propertySize;
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    error = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &propertySize, &deviceID);
    if (error) return error;
    
    // get its sample rate
    propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(Float64);
    error = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, NULL, &propertySize, outSampleRate);
    
    return error;
}


// Determine the size, in bytes, of a buffer necessary to represent the supplied number
// of seconds of audio data.
static int MyComputeRecordBufferSize(const AudioStreamBasicDescription *format, AudioQueueRef queue, float seconds)
{
    int packets, frames, bytes;
    
    frames = (int)ceil(seconds * format->mSampleRate);
    
    if (format->mBytesPerFrame > 0)                        // 1
        bytes = frames * format->mBytesPerFrame;
    else
    {
        UInt32 maxPacketSize;
        if (format->mBytesPerPacket > 0)                // 2
            maxPacketSize = format->mBytesPerPacket;
        else
        {
            // get the largest single packet size possible
            UInt32 propertySize = sizeof(maxPacketSize);    // 3
            CheckError(AudioQueueGetProperty(queue, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize,
                                             &propertySize), "couldn't get queue's maximum output packet size");
        }
        if (format->mFramesPerPacket > 0)
            packets = frames / format->mFramesPerPacket;     // 4
        else
            // worst-case scenario: 1 frame in a packet
            packets = frames;                            // 5
        
        if (packets == 0)        // sanity check
            packets = 1;
        bytes = packets * maxPacketSize;                // 6
    }
    return bytes;
}


#pragma mark - audio queue -

// Audio Queue callback function, called when an input buffer has been filled.
static void MyAQInputCallback(void *inUserData, AudioQueueRef inQueue,
                              AudioQueueBufferRef inBuffer,
                              const AudioTimeStamp *inStartTime,
                              UInt32 inNumPackets,
                              const AudioStreamPacketDescription *inPacketDesc)
{
    
    MyRecorder *recorder = (MyRecorder *)inUserData;
    MyPlayer *player = recorder->player;
    printf("Writing buffer %lld\n", recorder->recordPacket);
    // if inNumPackets is greater then zero, our buffer contains audio data
    // in the format we specified (AAC)
    if (inNumPackets > 0)
    {
        // Enqueue on the output Queue!
        AudioQueueBufferRef outputBuffer;
        CheckError(AudioQueueAllocateBuffer(player->queue, inBuffer->mAudioDataBytesCapacity, &outputBuffer), "Input callback failed to allocate new output buffer");
        
        memcpy(outputBuffer->mAudioData, inBuffer->mAudioData, inBuffer->mAudioDataByteSize);
        outputBuffer->mAudioDataByteSize = inBuffer->mAudioDataByteSize;
        
        CheckError(AudioQueueEnqueueBuffer(player->queue, outputBuffer, 0, NULL), "Enqueing the buffer in input callback failed");
        recorder->recordPacket += inNumPackets;
    }
    
    
    if (recorder->running) {
        CheckError(AudioQueueEnqueueBuffer(inQueue, inBuffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
    }
    
}


// Output audio methods

void CalculateBytesForTime (AudioFileID inAudioFile, AudioStreamBasicDescription inDesc, Float64 inSeconds, UInt32 *outBufferSize, UInt32 *outNumPackets);
void CalculateBytesForTime (AudioFileID inAudioFile, AudioStreamBasicDescription inDesc, Float64 inSeconds, UInt32 *outBufferSize, UInt32 *outNumPackets);


#define kNumberPlaybackBuffers    3



#pragma mark - utility functions -

// we only use time here as a guideline
// we're really trying to get somewhere between 16K and 64K buffers, but not allocate too much if we don't need it
void CalculateBytesForTime (AudioFileID inAudioFile, AudioStreamBasicDescription inDesc, Float64 inSeconds, UInt32 *outBufferSize, UInt32 *outNumPackets)
{
    
    // we need to calculate how many packets we read at a time, and how big a buffer we need.
    // we base this on the size of the packets in the file and an approximate duration for each buffer.
    //
    // first check to see what the max size of a packet is, if it is bigger than our default
    // allocation size, that needs to become larger
    UInt32 maxPacketSize;
    UInt32 propSize = sizeof(maxPacketSize);
    CheckError(AudioFileGetProperty(inAudioFile, kAudioFilePropertyPacketSizeUpperBound,
                                    &propSize, &maxPacketSize), "couldn't get file's max packet size");
    
    static const int maxBufferSize = 0x10000; // limit size to 64K
    static const int minBufferSize = 0x4000; // limit size to 16K
    
    if (inDesc.mFramesPerPacket) {
        Float64 numPacketsForTime = inDesc.mSampleRate / inDesc.mFramesPerPacket * inSeconds;
        *outBufferSize = numPacketsForTime * maxPacketSize;
    } else {
        // if frames per packet is zero, then the codec has no predictable packet == time
        // so we can't tailor this (we don't know how many Packets represent a time period
        // we'll just return a default buffer size
        *outBufferSize = maxBufferSize > maxPacketSize ? maxBufferSize : maxPacketSize;
    }
    
    // we're going to limit our size to our default
    if (*outBufferSize > maxBufferSize && *outBufferSize > maxPacketSize)
        *outBufferSize = maxBufferSize;
    else {
        // also make sure we're not too small - we don't want to go the disk for too small chunks
        if (*outBufferSize < minBufferSize)
            *outBufferSize = minBufferSize;
    }
    *outNumPackets = *outBufferSize / maxPacketSize;
}


#pragma mark - audio queue -

static void MyAQOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inCompleteAQBuffer)
{
    MyPlayer *aqp = (MyPlayer *)inUserData;
     
    if (aqp->isDone) return;
}

void CalculateBytesForPlaythrough(AudioQueueRef queue,
                                  AudioStreamBasicDescription inDesc,
                                  Float64 inSeconds,
                                  UInt32 *outBufferSize,
                                  UInt32 *outNumPackets)
{
    UInt32 maxPacketSize;
    UInt32 propSize = sizeof(maxPacketSize);
    CheckError(AudioQueueGetProperty(queue,
                                     kAudioQueueProperty_MaximumOutputPacketSize,
                                     &maxPacketSize, &propSize), "Couldn't get file's max packet size");
    
    static const int maxBufferSize = 0x10000;
    static const int minBufferSize = 0x4000;
    
    if (inDesc.mFramesPerPacket) {
        Float64 numPacketsForTime = inDesc.mSampleRate / inDesc.mFramesPerPacket * inSeconds;
        *outBufferSize = numPacketsForTime * maxPacketSize;
    } else {
        *outBufferSize = maxBufferSize > maxPacketSize ? maxBufferSize : maxPacketSize;
    }
    
    if (*outBufferSize > maxBufferSize &&
        *outBufferSize > maxPacketSize) {
        *outBufferSize = maxBufferSize;
    } else {
        if (*outBufferSize < minBufferSize) {
            *outBufferSize = minBufferSize;
        }
    }
    *outNumPackets = *outBufferSize / maxPacketSize;
}

@implementation Recorder{
    MyRecorder recorder;
    MyPlayer player;
}

-(void) start{
    @autoreleasepool {
        
        memset(&recorder,0,sizeof(MyRecorder));
        memset(&player,0,sizeof(MyPlayer));
        recorder.player = &player;
        player.recorder = &recorder;
        AudioStreamBasicDescription recordFormat;
        memset(&recordFormat, 0, sizeof(recordFormat));
        
        recordFormat.mFormatID = kAudioFormatLinearPCM;
        recordFormat.mChannelsPerFrame = 2; //stereo
        
        // Begin my changes to make LPCM work
        recordFormat.mBitsPerChannel = 16;
        // Haven't checked if each of these flags is necessary, this is just what Chapter 2 used for LPCM.
        recordFormat.mFormatFlags = kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        
        // end my changes
        
        MyGetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate);
        
        
        UInt32 propSize = sizeof(recordFormat);
        CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                          0,
                                          NULL,
                                          &propSize,
                                          &recordFormat), "AudioFormatGetProperty failed");
        
        
        AudioQueueRef queue = {0};
        
        CheckError(AudioQueueNewInput(&recordFormat, MyAQInputCallback, &recorder, NULL, NULL, 0, &queue), "AudioQueueNewInput failed");
        
        recorder.recordQueue = queue;
        
        // Fills in ABSD a little more
        UInt32 size = sizeof(recordFormat);
        CheckError(AudioQueueGetProperty(queue,
                                         kAudioConverterCurrentOutputStreamDescription,
                                         &recordFormat,
                                         &size), "Couldn't get queue's format");
        
        
        int bufferByteSize = MyComputeRecordBufferSize(&recordFormat,queue,0.5);
        NSLog(@"%d",__LINE__);
        // Create and Enqueue buffers
        int bufferIndex;
        for (bufferIndex = 0;
             bufferIndex < kNumberRecordBuffers;
             ++bufferIndex) {
            AudioQueueBufferRef buffer;
            CheckError(AudioQueueAllocateBuffer(queue,
                                                bufferByteSize,
                                                &buffer), "AudioQueueBufferRef failed");
            CheckError(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
        }
        
        // PLAYBACK SETUP
        
        AudioQueueRef playbackQueue;
        CheckError(AudioQueueNewOutput(&recordFormat,
                                       MyAQOutputCallback,
                                       &player, NULL, NULL, 0,
                                       &playbackQueue), "AudioOutputNewQueue failed");
        player.queue = playbackQueue;
        
        
        UInt32 playBufferByteSize;
        CalculateBytesForPlaythrough(queue, recordFormat, 0.1, &playBufferByteSize, &player.numPacketsToRead);
        
        bool isFormatVBR = (recordFormat.mBytesPerPacket == 0
                            || recordFormat.mFramesPerPacket == 0);
        if (isFormatVBR) {
            NSLog(@"Not supporting VBR");
            player.packetDescs = (AudioStreamPacketDescription*) malloc(sizeof(AudioStreamPacketDescription) * player.numPacketsToRead);
        } else {
            player.packetDescs = NULL;
        }
        
        // END PLAYBACK
        
        recorder.running = TRUE;
        player.isDone = false;
        
        
        CheckError(AudioQueueStart(playbackQueue, NULL), "AudioQueueStart failed");
        CheckError(AudioQueueStart(queue, NULL), "AudioQueueStart failed");
        
        
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10, TRUE);
        
        
        
    }
}
-(void)stop{
    if(recorder.running==TRUE){
        
        printf("* recording done *\n");
        recorder.running = FALSE;
        player.isDone = true;
        CheckError(AudioQueueStop(player.queue, false), "Failed to stop playback queue");
        CheckError(AudioQueueStop(recorder.recordQueue, TRUE), "AudioQueueStop failed");
    
    }
}


@end
