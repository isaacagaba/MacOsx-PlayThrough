//
//  ViewController.m
//  MicrophoneTest
//
//  Created by agaba isaac on 4/11/18.
//  Copyright © 2018 agaba isaac. All rights reserved.
//

#import "ViewController.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Recorder.h"


@implementation ViewController{
 
    Recorder * recorder;
    
}
- (IBAction)buttonClicked:(id)sender {
    
     [recorder stop];
    
}


- (IBAction)Record:(id)sender {
   
    recorder = [[Recorder alloc] init];
    [recorder start];
    
    
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    
}


- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}


@end
