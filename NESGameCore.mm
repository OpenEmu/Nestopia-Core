/*
 Copyright (c) 2009, OpenEmu Team


 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "NESGameCore.h"
#import "NESGameController.h"
#import <OpenEmuBase/OERingBuffer.h>
#include <sys/time.h>
#include <NstBase.hpp>
#include <NstApiEmulator.hpp>
#include <NstApiMachine.hpp>
#include <NstApiCartridge.hpp>
#include <NstApiVideo.hpp>
#include <NstApiSound.hpp>
#include <NstApiUser.hpp>
#include <NstApiCheats.hpp>
#include <NstApiRewinder.hpp>
//#include <NstApiRam.h>
#include <NstApiMovie.hpp>
#include <NstApiFds.hpp>
#include <NstMachine.hpp>
#include <iostream>
#include <fstream>
#include <sstream>
#include <map>
#import <OpenGL/gl.h>
#import "OENESSystemResponderClient.h"
#import "OEFDSSystemResponderClient.h"

#define SAMPLERATE 48000

NSUInteger NESControlValues[] = { Nes::Api::Input::Controllers::Pad::UP, Nes::Api::Input::Controllers::Pad::DOWN, Nes::Api::Input::Controllers::Pad::LEFT, Nes::Api::Input::Controllers::Pad::RIGHT, Nes::Api::Input::Controllers::Pad::A, Nes::Api::Input::Controllers::Pad::B, Nes::Api::Input::Controllers::Pad::START, Nes::Api::Input::Controllers::Pad::SELECT
};

@implementation NESGameCore

@synthesize romPath;

UInt32 bufInPos, bufOutPos, bufUsed;
char biosFilePath[2048];
int displayMode = 0;

static bool NST_CALLBACK VideoLock(void *userData, Nes::Api::Video::Output& video)
{
    DLog(@"Locking: %@", userData);
    return [(__bridge NESGameCore *)userData lockVideo:&video];
}

static void NST_CALLBACK VideoUnlock(void *userData, Nes::Api::Video::Output& video)
{
    [(__bridge NESGameCore *)userData unlockVideo:&video];
}

static bool NST_CALLBACK SoundLock(void *userData, Nes::Api::Sound::Output& sound)
{
    return [(__bridge NESGameCore *)userData lockSound];
}

static void NST_CALLBACK SoundUnlock(void *userData, Nes::Api::Sound::Output& sound)
{
    [(__bridge NESGameCore *)userData unlockSound];
}

- (id)init;
{
    if((self = [super init]))
    {
        _nesSound = new Nes::Api::Sound::Output();
        _nesVideo = new Nes::Api::Video::Output();
        _controls = new Nes::Api::Input::Controllers();
        _emu = new Nes::Api::Emulator();
        soundLock = [[NSLock alloc] init];
        videoLock = [[NSLock alloc] init];
    }
    return self;
}

// for various file operations, usually called during image file load, power on/off and reset
void NST_CALLBACK doFileIO(void *userData, Nes::Api::User::File& file)
{
    NESGameCore *self = (__bridge NESGameCore *)userData;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *path = self->romPath;

    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

    NSData *theData;
    NSString *filePath;

    DLog(@"Doing file IO");
    switch(file.GetAction())
    {
        case Nes::Api::User::File::LOAD_SAMPLE :
        {
            /*
             XADArchive* romArchive = (XADArchive*)userData;
             const wchar_t* romInZip = file.GetName();
             NSString *romName =
             (NSString *) CFStringCreateWithBytes(kCFAllocatorDefault,
             (const UInt8 *) romInZip,
             wcslen(romInZip) * sizeof(wchar_t),
             kCFStringEncodingUTF32LE, false);
             DLog(romName);
             int fileIndex = -1;
             for(int i = 0; i < [romArchive numberOfEntries]; i++)
             {
             if([[romArchive nameOfEntry:i] isEqualToString:romName] )
             {
             fileIndex = i;
             break;
             }
             }
             theData = [romArchive contentsOfEntry:fileIndex];
             file.SetSampleContent([theData bytes] , [theData length], false, 32, 44100);
             */
            break;
        }
        case Nes::Api::User::File::LOAD_ROM :
        {
            /*
             XADArchive* romArchive = (XADArchive*)userData;
             const wchar_t* romInZip = file.GetName();
             NSString *romName =
             (NSString *) CFStringCreateWithBytes(kCFAllocatorDefault,
             (const UInt8 *) romInZip,
             wcslen(romInZip) * sizeof(wchar_t),
             kCFStringEncodingUTF32LE, false);
             DLog(romName);
             int fileIndex = -1;
             for(int i = 0; i < [romArchive numberOfEntries]; i++)
             {
             if([[romArchive nameOfEntry:i] isEqualToString:romName] )
             {
             fileIndex = i;
             break;
             }
             }
             theData = [romArchive contentsOfEntry:fileIndex];
             file.SetContent([theData bytes] , [theData length]);
             */
            break;
        }

        case Nes::Api::User::File::LOAD_BATTERY : // load in battery data from a file
        case Nes::Api::User::File::LOAD_EEPROM : // used by some Bandai games, can be treated the same as battery files
        {
            NSLog(@"Trying to load EEPROM");
            filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            NSLog(@"File path: %@", filePath);
            if(![fileManager fileExistsAtPath:filePath])
            {
                NSLog(@"Couldn't find save");
                return;
            }
            theData = [NSData dataWithContentsOfFile:filePath];
            file.SetContent([theData bytes], [theData length]);
            break;
        }
        case Nes::Api::User::File::SAVE_BATTERY : // save battery data to a file
        case Nes::Api::User::File::SAVE_EEPROM : // can be treated the same as battery files
        {
            NSLog(@"Trying to save EEPROM");
            const void *savedata;
            unsigned long savedatasize;
            file.GetContent( savedata, savedatasize );
            filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            theData = [NSData dataWithBytes:savedata length:savedatasize];
            [theData writeToFile:filePath atomically:YES];
            break;
        }
        case Nes::Api::User::File::LOAD_FDS:
        {
            NSLog(@"Trying to load FDS");
            filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            std::ifstream in_tmp([filePath UTF8String], std::ifstream::in|std::ifstream::binary);
            
            if (!in_tmp.is_open())
                return;
            
            file.SetPatchContent(in_tmp);
            break;
        }
        case Nes::Api::User::File::SAVE_FDS: // for saving modified Famicom Disk System files
        {
            NSLog(@"Trying to save FDS");
            filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            std::ofstream out_tmp([filePath UTF8String], std::ifstream::out|std::ifstream::binary);
            
            if (out_tmp.is_open())
                file.GetPatchContent(Nes::Api::User::File::PATCH_UPS, out_tmp);
            break;
        }
        case Nes::Api::User::File::LOAD_TAPE : // for loading Famicom cassette tapes
            DLog(@"Loading tape");
            break;
        case Nes::Api::User::File::SAVE_TAPE : // for saving Famicom cassette tapes
        case Nes::Api::User::File::LOAD_TURBOFILE : // for loading turbofile data
        case Nes::Api::User::File::SAVE_TURBOFILE : // for saving turbofile data
            break;
        case Nes::Api::User::File::LOAD_SAMPLE_MOERO_PRO_YAKYUU :

            DLog(@"Asked for sample Moreo");
            break;
        case Nes::Api::User::File::LOAD_SAMPLE_MOERO_PRO_YAKYUU_88 :
            DLog(@"Asked for sample Moreo 88");
            break;
        case Nes::Api::User::File::LOAD_SAMPLE_MOERO_PRO_TENNIS :
            DLog(@"Asked for sample Moreo Tennis");
            break;
        case Nes::Api::User::File::LOAD_SAMPLE_TERAO_NO_DOSUKOI_OOZUMOU :
        case Nes::Api::User::File::LOAD_SAMPLE_AEROBICS_STUDIO :
            break;
    }
}


Nes::Api::User::Answer NST_CALLBACK doQuestion(void *userData, Nes::Api::User::Question question)
{
    switch(question)
    {
        case Nes::Api::User::QUESTION_NST_PRG_CRC_FAIL_CONTINUE :
            break;
        case Nes::Api::User::QUESTION_NSV_PRG_CRC_FAIL_CONTINUE :
            break;
    }

    NSLog(@"CRC Failed");
    return Nes::Api::User::ANSWER_DEFAULT;
}

void NST_CALLBACK doLog(void *userData, const char *text,unsigned long length)
{
    NSLog(@"%@",[NSString stringWithUTF8String:text]);
}

void NST_CALLBACK doEvent(void *userData, Nes::Api::Machine::Event event, Nes::Result result)
{
    switch(event)
    {
        case Nes::Api::Machine::EVENT_LOAD :
            NSLog(@"Load returned : %d", result);
            break;
        case Nes::Api::Machine::EVENT_UNLOAD :
            NSLog(@"Unload returned : %d", result);
            break;
        case Nes::Api::Machine::EVENT_POWER_ON :
            NSLog(@"Power on returned : %d", result);
            break;
        case Nes::Api::Machine::EVENT_POWER_OFF :
            NSLog(@"Power off returned : %d", result);
            break;
        case Nes::Api::Machine::EVENT_RESET_SOFT :
        case Nes::Api::Machine::EVENT_RESET_HARD :
        case Nes::Api::Machine::EVENT_MODE_NTSC :
        case Nes::Api::Machine::EVENT_MODE_PAL :
            break;
    }
}

- (const void *)videoBuffer
{
    return videoBuffer;
}

- (BOOL)lockVideo:(void *)_video
{
    Nes::Api::Video::Output *video = (Nes::Api::Video::Output *)_video;
    [videoLock lock];
    video->pixels = (void*)videoBuffer;
    video->pitch = width*4;
    return true;
}

- (void)unlockVideo:(void *)_video
{
    Nes::Api::Video::Output *video = (Nes::Api::Video::Output *)_video;
    [videoLock unlock];
    video->pitch = NULL;
}

- (BOOL)lockSound
{
    return [soundLock tryLock];
}

- (void)unlockSound
{
    [soundLock unlock];
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

- (NSTimeInterval)frameInterval
{
    Nes::Api::Machine machine(*emu);

    if(machine.GetMode() == Nes::Api::Machine::NTSC)
        return Nes::Api::Machine::CLK_NTSC_DOT / Nes::Api::Machine::CLK_NTSC_VSYNC; // 60.0988138974
    else
        return Nes::Api::Machine::CLK_PAL_DOT / Nes::Api::Machine::CLK_PAL_VSYNC; // 50.0069789082
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    Nes::Result result;

    Nes::Api::Machine machine(*emu);

    Nes::Api::Cartridge::Database database(*emu);

    if(!database.IsLoaded())
    {
        NSString *databasePath = [[NSBundle bundleForClass:[self class]] pathForResource:@"NstDatabase" ofType:@"xml"];
        if(databasePath != nil)
        {
            DLog(@"Loading database");
            std::ifstream databaseStream([databasePath cStringUsingEncoding:NSUTF8StringEncoding], std::ifstream::in | std::ifstream::binary);
            database.Load(databaseStream);
            database.Enable(true);
            databaseStream.close();
        }
    }

    [self setRomPath:path];

    void *userData = (__bridge void *)self;
    Nes::Api::User::fileIoCallback.Set(doFileIO, userData);
    Nes::Api::User::logCallback.Set(doLog, userData);
    Nes::Api::Machine::eventCallback.Set(doEvent, userData);
    Nes::Api::User::questionCallback.Set(doQuestion, userData);
    
    Nes::Api::Fds fds(*emu);
    NSString *appSupportPath = [NSString pathWithComponents:@[
                                [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject],
                                @"OpenEmu", @"BIOS"]];
    
    strcpy(biosFilePath, [[appSupportPath stringByAppendingPathComponent:@"disksys.rom"] UTF8String]);
    std::ifstream biosFile(biosFilePath, std::ios::in | std::ios::binary);
    fds.SetBIOS(&biosFile);

    std::ifstream romFile([path cStringUsingEncoding:NSUTF8StringEncoding], std::ios::in | std::ios::binary);
    result = machine.Load(romFile, Nes::Api::Machine::FAVORED_NES_NTSC, Nes::Api::Machine::ASK_PROFILE);

    if(NES_FAILED(result))
    {
        NSString *errorDescription = nil;
        switch(result)
        {
            case Nes::RESULT_ERR_INVALID_FILE :
                errorDescription = NSLocalizedString(@"Invalid file.", @"Invalid file.");
                break;
            case Nes::RESULT_ERR_OUT_OF_MEMORY :
                errorDescription = NSLocalizedString(@"Out of memory.", @"Out of memory.");
                break;
            case Nes::RESULT_ERR_CORRUPT_FILE :
                errorDescription = NSLocalizedString(@"Corrupt file.", @"Corrupt file.");
                break;
            case Nes::RESULT_ERR_UNSUPPORTED_MAPPER :
                errorDescription = NSLocalizedString(@"Unsupported mapper.", @"Unsupported mapper.");
                break;
            case Nes::RESULT_ERR_MISSING_BIOS :
                errorDescription = NSLocalizedString(@"Can't find disksys.rom for FDS game.", @"Can't find disksys.rom for FDS game.");
                break;
            default :
                errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Unknown nestopia error #%d.", @"Unknown nestopia error #%d."), result];
                break;
        }
        NSLog(@"%@",errorDescription);

        return NO;
    }
    machine.Power(true);
    
    if (machine.Is(Nes::Api::Machine::DISK))
        fds.InsertDisk(0, 0);

    return YES;
}


- (void)setupAudio:(Nes::Api::Emulator*)emulator
{
    Nes::Api::Sound sound( *emulator );
    //Nes::Api::Machine machine( *emulator );
    sound.SetSampleBits( 16 );
    sound.SetSampleRate( SAMPLERATE );
    sound.SetVolume(Nes::Api::Sound::ALL_CHANNELS, 100);
    sound.SetSpeaker( Nes::Api::Sound::SPEAKER_MONO );
    sound.SetSpeed( [self frameInterval] );

    bufFrameSize = (SAMPLERATE / [self frameInterval]);

    soundBuffer = new UInt16[bufFrameSize * [self channelCount]];
    [[self ringBufferAtIndex:0] setLength:(sizeof(UInt16) * bufFrameSize * [self channelCount] * 5)];

    memset(soundBuffer, 0, bufFrameSize * [self channelCount] * sizeof(UInt16));
    nesSound->samples[0] = soundBuffer;
    nesSound->length[0] = bufFrameSize;
    nesSound->samples[1] = NULL;
    nesSound->length[1] = 0;
}

static Nes::Api::Video::RenderState::Filter filters[2] =
{
    Nes::Api::Video::RenderState::FILTER_NONE,
    Nes::Api::Video::RenderState::FILTER_NTSC,
    //Nes::Api::Video::RenderState::FILTER_SCALE2X,
    //Nes::Api::Video::RenderState::FILTER_SCALE3X,
    //Nes::Api::Video::RenderState::FILTER_HQ2X,
    //Nes::Api::Video::RenderState::FILTER_HQ3X,
    //Nes::Api::Video::RenderState::FILTER_HQ4X
};

static int Widths[2] =
{
    Nes::Api::Video::Output::WIDTH,
    Nes::Api::Video::Output::NTSC_WIDTH,
    //Nes::Api::Video::Output::WIDTH*2,
    //Nes::Api::Video::Output::WIDTH*3,
    //Nes::Api::Video::Output::WIDTH*2,
    //Nes::Api::Video::Output::WIDTH*3,
    //Nes::Api::Video::Output::WIDTH*4,
};

static int Heights[2] =
{
    Nes::Api::Video::Output::HEIGHT,
    Nes::Api::Video::Output::HEIGHT,
    //Nes::Api::Video::Output::HEIGHT*2,
    //Nes::Api::Video::Output::HEIGHT*3,
    //Nes::Api::Video::Output::HEIGHT*2,
    //Nes::Api::Video::Output::HEIGHT*3,
    //Nes::Api::Video::Output::HEIGHT*4,
};

- (void)setupVideo:(void *)_emulator withFilter:(int)filter
{
    Nes::Api::Emulator *emulator = (Nes::Api::Emulator *)_emulator;
    // renderstate structure
    Nes::Api::Video::RenderState *renderState = new Nes::Api::Video::RenderState();

    Nes::Api::Machine machine(*emulator);
    Nes::Api::Cartridge::Database database(*emulator);


    //machine.SetMode(Nes::Api::Machine::NTSC);

    width =Widths[filter];
    height = Heights[filter];
    DLog(@"buffer dim width: %d, height: %d\n", width, height);
    [videoLock lock];
    if(videoBuffer)
        delete[] videoBuffer;
    videoBuffer = new unsigned char[width * height * 4];
    [videoLock unlock];

    renderState->bits.count = 32;
    renderState->bits.mask.r = 0xFF0000;
    renderState->bits.mask.g = 0x00FF00;
    renderState->bits.mask.b = 0x0000FF;

    renderState->filter = filters[filter];
    renderState->width = Widths[filter];
    renderState->height = Heights[filter];

    Nes::Api::Video video(*emulator);

    [self toggleUnlimitedSprites:nil];

    // set up the NTSC type
    /*
     switch (0)
     {

     case 0:    // composite
     video.SetSharpness(Nes::Api::Video::DEFAULT_SHARPNESS_COMP);
     video.SetColorResolution(Nes::Api::Video::DEFAULT_COLOR_RESOLUTION_COMP);
     video.SetColorBleed(Nes::Api::Video::DEFAULT_COLOR_BLEED_COMP);
     video.SetColorArtifacts(Nes::Api::Video::DEFAULT_COLOR_ARTIFACTS_COMP);
     video.SetColorFringing(Nes::Api::Video::DEFAULT_COLOR_FRINGING_COMP);
     break;

     case 1:    // S-Video
     video.SetSharpness(Nes::Api::Video::DEFAULT_SHARPNESS_SVIDEO);
     video.SetColorResolution(Nes::Api::Video::DEFAULT_COLOR_RESOLUTION_SVIDEO);
     video.SetColorBleed(Nes::Api::Video::DEFAULT_COLOR_BLEED_SVIDEO);
     video.SetColorArtifacts(Nes::Api::Video::DEFAULT_COLOR_ARTIFACTS_SVIDEO);
     video.SetColorFringing(Nes::Api::Video::DEFAULT_COLOR_FRINGING_SVIDEO);
     break;

     case 2:    // RGB
     video.SetSharpness(Nes::Api::Video::DEFAULT_SHARPNESS_RGB);
     video.SetColorResolution(Nes::Api::Video::DEFAULT_COLOR_RESOLUTION_RGB);
     video.SetColorBleed(Nes::Api::Video::DEFAULT_COLOR_BLEED_RGB);
     video.SetColorArtifacts(Nes::Api::Video::DEFAULT_COLOR_ARTIFACTS_RGB);
     video.SetColorFringing(Nes::Api::Video::DEFAULT_COLOR_FRINGING_RGB);
     break;
     }*/
    /*
     video.SetSharpness([self sharpness]);
     video.SetColorResolution([self colorRes]);
     video.SetColorBleed([self colorBleed]);
     video.SetBrightness([self brightness]);
     video.SetContrast([self contrast]);
     video.SetColorArtifacts([self colorArtifacts]);
     video.SetHue([self hue]);
     video.SetColorFringing([self colorFringing]);
     video.SetSaturation([self saturation]);
     */
    // set the render state, make use of the NES_FAILED macro, expands to: "if(function(...) < Nes::RESULT_OK)"
    if(NES_FAILED(video.SetRenderState(*renderState)))
    {
        printf("NEStopia core rejected render state\n");
        exit(0);
    }

    DLog(@"Loaded video");

    nesVideo->pixels = (void *)videoBuffer;
    nesVideo->pitch = width * 4;
}

- (void)setupEmulation
{
    //soundLock = [[NSLock alloc] init];
    // Lets set up the database!

    Nes::Api::Cartridge::Database database(*emu);

    if(!database.IsLoaded())
    {
        NSString *databasePath = [[NSBundle bundleForClass:[self class]] pathForResource:@"NstDatabase" ofType:@"xml"];
        if(databasePath != nil)
        {
            DLog(@"Loading database");
            std::ifstream databaseStream([databasePath cStringUsingEncoding:NSUTF8StringEncoding], std::ifstream::in | std::ifstream::binary);
            database.Load(databaseStream);
            database.Enable(true);
            databaseStream.close();
        }
    }

    if(database.IsLoaded())
    {
        DLog(@"Database loaded");
        Nes::Api::Input(*emu).AutoSelectControllers();
        Nes::Api::Input(*emu).AutoSelectAdapter();
    }
    else
        Nes::Api::Input(*emu).ConnectController(0, Nes::Api::Input::PAD1);

    Nes::Api::Machine machine(*emu);
    machine.SetMode(machine.GetDesiredMode());

    //nesControls = new Nes::Api::Input::Controllers;
    //[inputController setupNesController:nesControls];
    if([self isNTSCEnabled])
        [self setupVideo:emu withFilter:1];//[[[OpenNestopiaPreferencesController sharedPreferencesController:self] filter] intValue]];
    else
        [self setupVideo:emu withFilter:0];

    [self setupAudio:emu];

    DLog(@"Setup");
}

- (void)stopEmulation
{
    Nes::Api::Machine machine(*emu);
    //machine.Power(false);
    machine.Unload(); // this allows FDS to save
    [super stopEmulation];
}

# pragma mark -

- (void)executeFrame
{
    //Get a reference to the emulator
    [videoLock lock];
    [soundLock lock];
    emu->Execute(nesVideo, nesSound, controls);
    [[self ringBufferAtIndex:0] write:soundBuffer maxLength:[self channelCount] * bufFrameSize * sizeof(UInt16)];
    //DLog(@"Wrote %d frames", frames);
    [videoLock unlock];
    [soundLock unlock];
}

# pragma mark -

- (void)resetEmulation
{
    DLog(@"Resetting NES");
    Nes::Api::Machine machine(*emu);
    machine.Reset(true);
    
    // put the disk system back to disk 0 side 0
    if (machine.Is(Nes::Api::Machine::DISK))
    {
        Nes::Api::Fds fds(*emu);
        fds.EjectDisk();
        fds.InsertDisk(0, 0);
    }
}

- (void)dealloc
{
    delete[] soundBuffer;
    delete[] videoBuffer;
    delete emu;
    delete nesSound;
    delete nesVideo;
    delete controls;
}

- (oneway void)didPushNESButton:(OENESButton)button forPlayer:(NSUInteger)player;
{
    controls->pad[player - 1].buttons |=  NESControlValues[button];
}

- (oneway void)didReleaseNESButton:(OENESButton)button forPlayer:(NSUInteger)player;
{
    controls->pad[player - 1].buttons &= ~NESControlValues[button];
}

- (oneway void)didTriggerGunAtPoint:(OEIntPoint)aPoint
{
    [self mouseMovedAtPoint:aPoint];

    controls->paddle.button = 1;
    controls->zapper.x = aPoint.x * 0.800000;
    controls->zapper.y = aPoint.y;
    controls->zapper.fire = 1;
    controls->bandaiHyperShot.x = aPoint.x * 0.800000;
    controls->bandaiHyperShot.y = aPoint.y;
    controls->bandaiHyperShot.fire = 1;
}

- (oneway void)didReleaseTrigger
{
    controls->paddle.button = 0;
    controls->zapper.fire = 0;
    controls->bandaiHyperShot.fire = 0;
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)aPoint
{
    controls->paddle.x = aPoint.x * 0.800000;
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point
{
    controls->bandaiHyperShot.move = 1;
}

- (oneway void)rightMouseUp;
{
    controls->bandaiHyperShot.move = 0;
}

- (double)audioSampleRate
{
    return SAMPLERATE;
}

- (NSUInteger)channelCount
{
    return 1;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, 256, 240);
}

- (OEIntSize)bufferSize
{
    return [self isNTSCEnabled] ? OEIntSizeMake(Widths[1], Heights[1] * 2)
    : OEIntSizeMake(Widths[0], Heights[0]);
}

#pragma mark - Save state

- (NSData *)serializeStateWithError:(NSError **)outError
{
    NSError *error = nil;
    Nes::Result result;
    Nes::Api::Machine machine(*emu);
    
    std::stringstream stateStream(std::ios::in|std::ios::out|std::ios::binary);
    
    result = machine.SaveState(stateStream, Nes::Api::Machine::NO_COMPRESSION);
    
    if(NES_FAILED(result))
    {
        NSString *errorDescription = nil;
        switch(result)
        {
            case Nes::RESULT_ERR_NOT_READY :
                errorDescription = NSLocalizedString(@"Not ready to save state.", @"Not ready to save state.");
                break;
            case Nes::RESULT_ERR_OUT_OF_MEMORY :
                errorDescription = NSLocalizedString(@"Out of memory.", @"Out of memory.");
                break;
            default :
                errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Unknown nestopia error #%d.", @"Unknown nestopia error #%d."), result];
                break;
        }
        
        error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                    code:OEGameCoreCouldNotSaveStateError
                                userInfo:@{
                                           NSLocalizedDescriptionKey : @"The save state data could not be read",
                                           NSLocalizedRecoverySuggestionErrorKey : errorDescription
                                           }];
        
    }
    
    if(error)
    {
        if(outError)
        {
            *outError = error;
        }
        return nil;
    }
    else
    {
        stateStream.seekg(0, std::ios::end);
        NSUInteger length = stateStream.tellg();
        stateStream.seekg(0, std::ios::beg);
        
        char *bytes = (char *)malloc(length);
        stateStream.read(bytes, length);
        
        return [NSData dataWithBytesNoCopy:bytes length:length];
    }
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    NSError *error;
    Nes::Result result;
    Nes::Api::Machine machine(*emu);
    
    std::stringstream stateStream(std::ios::in|std::ios::out|std::ios::binary);
    
    char const *bytes = (char const *)([state bytes]);
    std::streamsize size = [state length];
    stateStream.write(bytes, size);
    
    result = machine.LoadState(stateStream);
    
    if(NES_FAILED(result))
    {
        NSString *errorDescription = nil;
        switch(result)
        {
            case Nes::RESULT_ERR_NOT_READY :
                errorDescription = NSLocalizedString(@"Not ready to save state.", @"Not ready to save state.");
                break;
            case Nes::RESULT_ERR_INVALID_CRC :
                errorDescription = NSLocalizedString(@"Invalid CRC checksum.", @"Invalid CRC checksum.");
                break;
            case Nes::RESULT_ERR_OUT_OF_MEMORY :
                errorDescription = NSLocalizedString(@"Out of memory.", @"Out of memory.");
                break;
            default :
                errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Unknown nestopia error #%d.", @"Unknown nestopia error #%d."), result];
                break;
        }
        error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                    code:OEGameCoreStateHasWrongSizeError
                                userInfo:@{
                                           NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                                           NSLocalizedRecoverySuggestionErrorKey : errorDescription,
                                           }];
    }
    
    if(error)
    {
        if(outError)
        {
            *outError = error;
        }
        return false;
    }
    else
    {
        return true;
    }
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    const char* filename = [fileName fileSystemRepresentation];
    
    Nes::Result result;
    
    Nes::Api::Machine machine(*emu);
    std::ofstream stateFile(filename, std::ifstream::out|std::ifstream::binary);
    
    if(stateFile.is_open())
        result = machine.SaveState(stateFile, Nes::Api::Machine::NO_COMPRESSION);
    else
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
                                                                                                                         NSLocalizedDescriptionKey : NSLocalizedString(@"The save state file could not be written", @"Nestopia state file could not be written description."),
                                                                                                                         NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:NSLocalizedString(@"Could not write the file state in %@.", @"Nestopia state file could not be written suggestion."), fileName]
                                                                                                                         }];
        block(NO, error);
        return;
    }
    
    if(NES_FAILED(result))
    {
        NSString *errorDescription = nil;
        switch(result)
        {
            case Nes::RESULT_ERR_NOT_READY :
                errorDescription = NSLocalizedString(@"Not ready to save state.", @"Not ready to save state.");
                break;
            case Nes::RESULT_ERR_OUT_OF_MEMORY :
                errorDescription = NSLocalizedString(@"Out of memory.", @"Out of memory.");
                break;
            default :
                errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Unknown nestopia error #%d.", @"Unknown nestopia error #%d."), result];
                break;
        }
        
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
                                                                                                                         NSLocalizedDescriptionKey : @"The save state data could not be read",
                                                                                                                         NSLocalizedRecoverySuggestionErrorKey : errorDescription
                                                                                                                         }];
        
        block(NO, error);
        return;
    }
    
    stateFile.close();
    block(YES, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    Nes::Result result;
    
    Nes::Api::Machine machine(*emu);
    std::ifstream stateFile( [fileName UTF8String], std::ifstream::in|std::ifstream::binary );
    
    if(stateFile.is_open())
        result = machine.LoadState(stateFile);
    else
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
                                                                                                                         NSLocalizedDescriptionKey : NSLocalizedString(@"The save state file could not be opened", @"Nestopia state file could not be opened description."),
                                                                                                                         NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:NSLocalizedString(@"Could not read the file state in %@.", @"Nestopia state file could not be opened suggestion."), fileName]
                                                                                                                         }];
        block(NO, error);
        return;
    }
    
    if(NES_FAILED(result))
    {
        NSString *errorDescription = nil;
        switch(result)
        {
            case Nes::RESULT_ERR_NOT_READY :
                errorDescription = NSLocalizedString(@"Not ready to save state.", @"Not ready to save state.");
                break;
            case Nes::RESULT_ERR_INVALID_CRC :
                errorDescription = NSLocalizedString(@"Invalid CRC checksum.", @"Invalid CRC checksum.");
                break;
            case Nes::RESULT_ERR_OUT_OF_MEMORY :
                errorDescription = NSLocalizedString(@"Out of memory.", @"Out of memory.");
                break;
            default :
                errorDescription = [NSString stringWithFormat:NSLocalizedString(@"Unknown nestopia error #%d.", @"Unknown nestopia error #%d."), result];
                break;
        }
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
                                                                                                                         NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                                                                                                                         NSLocalizedRecoverySuggestionErrorKey : errorDescription,
                                                                                                                         }];
        
        block(NO, error);
        return;
    }
    
    block(YES, nil);
}

#pragma mark - Cheats

NSMutableDictionary *cheatList = [[NSMutableDictionary alloc] init];

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];
    
    Nes::Api::Cheats cheater(*emu);
    Nes::Api::Cheats::Code ggCode;
    
    if (enabled)
        [cheatList setValue:@YES forKey:code];
    else
        [cheatList removeObjectForKey:code];
    
    cheater.ClearCodes();
    
    NSArray *multipleCodes = [[NSArray alloc] init];
    
    // Apply enabled cheats found in dictionary
    for (id key in cheatList)
    {
        if ([[cheatList valueForKey:key] isEqual:@YES])
        {
            // Handle multi-line cheats
            multipleCodes = [key componentsSeparatedByString:@"+"];
            for (NSString *singleCode in multipleCodes) {
                const char *cCode = [singleCode UTF8String];
                
                Nes::Api::Cheats::GameGenieDecode(cCode, ggCode);
                cheater.SetCode(ggCode);
            }
        }
    }
}

- (oneway void)didPushFDSChangeSideButton;
{
    Nes::Api::Fds fds(*emu);
    //fds.ChangeSide();
    //NSLog(@"didPushFDSChangeSideButton");
	Nes::Result result;
	if (fds.IsAnyDiskInserted() && fds.CanChangeDiskSide())
		result = fds.ChangeSide();
	else
		result = fds.InsertDisk(0, 0);
	NSLog(@"didPushFDSChangeSideButton: %d", result);
}

- (oneway void)didReleaseFDSChangeSideButton;
{
    
}

- (oneway void)didPushFDSChangeDiskButton;
{
    Nes::Api::Fds fds(*emu);
    // if multi-disk game, eject and insert the other disk
	if (fds.GetNumDisks() > 1)
    {
        int currdisk = fds.GetCurrentDisk();
        fds.EjectDisk();
        fds.InsertDisk(!currdisk, 0);
        
        NSLog(@"didPushFDSChangeDiskButton");
    }
}

- (oneway void)didReleaseFDSChangeDiskButton;
{
    
}

- (void)changeDisplayMode
{
    Nes::Api::Video video(*emu);
    
	switch (displayMode)
    {
        case 0:
            video.GetPalette().SetMode(Nes::Api::Video::Palette::MODE_YUV);
            video.SetDecoder(Nes::Api::Video::DECODER_CONSUMER);
            displayMode++;
            break;
			
        case 1:
            video.GetPalette().SetMode(Nes::Api::Video::Palette::MODE_YUV);
            video.SetDecoder(Nes::Api::Video::DECODER_ALTERNATIVE);
            displayMode++;
            break;
			
        case 2:
            video.GetPalette().SetMode(Nes::Api::Video::Palette::MODE_RGB);
            displayMode++;
            break;
            
        case 3:
            video.GetPalette().SetMode(Nes::Api::Video::Palette::MODE_YUV);
            video.SetDecoder(Nes::Api::Video::DECODER_CANONICAL);
            displayMode = 0;
            break;
			
        default:
            return;
            break;
    }
}

@end
