/*
 Copyright (c) 2018, OpenEmu Team


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
#import <OpenEmuBase/OERingBuffer.h>
#import "OENESSystemResponderClient.h"
#import "OEFDSSystemResponderClient.h"
#import <OpenGL/gl.h>

#include <NstBase.hpp>
#include <NstApiEmulator.hpp>
#include <NstApiMachine.hpp>
#include <NstApiCartridge.hpp>
#include <NstApiInput.hpp>
#include <NstApiVideo.hpp>
#include <NstApiSound.hpp>
#include <NstApiUser.hpp>
#include <NstApiCheats.hpp>
#include <NstApiFds.hpp>
#include <NstMachine.hpp>
#include <iostream>
#include <fstream>
#include <sstream>

#define SAMPLERATE 48000

@interface NESGameCore () <OENESSystemResponderClient, OEFDSSystemResponderClient>
{
    NSURL               *_romURL;
    int                  _bufFrameSize;
    NSUInteger           _width;
    NSUInteger           _height;
    const unsigned char *_indirectVideoBuffer;
    int16_t             *_soundBuffer;

    Nes::Api::Emulator       _emu;
    Nes::Api::Sound::Output *_nesSound;
    Nes::Api::Video::Output *_nesVideo;
    Nes::Api::Input::Controllers *_controls;

    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
}

@end

@implementation NESGameCore

static __weak NESGameCore *_current;
int displayMode = 0;

- (id)init;
{
    if((self = [super init]))
    {
        _current = self;
        _nesSound = new Nes::Api::Sound::Output;
        _nesVideo = new Nes::Api::Video::Output;
        _controls = new Nes::Api::Input::Controllers;
        _cheatList = [NSMutableDictionary dictionary];
    }

    return self;
}

- (void)dealloc
{
    delete[] _soundBuffer;
    delete[] _indirectVideoBuffer;
    delete _nesSound;
    delete _nesVideo;
    delete _controls;
}

# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    Nes::Result result;
    Nes::Api::Machine machine(_emu);
    Nes::Api::Cartridge::Database database(_emu);

    // Load database
    if(!database.IsLoaded())
    {
        NSLog(@"[Nestopia] loading db");
        NSURL *databaseURL = [[NSBundle bundleForClass:[self class]] URLForResource:@"NstDatabase" withExtension:@"xml"];
        if ([databaseURL checkResourceIsReachableAndReturnError:nil])
        {
            std::ifstream databaseStream(databaseURL.fileSystemRepresentation, std::ifstream::in | std::ifstream::binary);
            database.Load(databaseStream);
            database.Enable(true);
            databaseStream.close();
        }
    }

    _romURL = [NSURL fileURLWithPath:path];

    // Setup callbacks
    Nes::Api::User::fileIoCallback.Set(doFileIO, 0);
    Nes::Api::User::logCallback.Set(doLog, 0);
    Nes::Api::Machine::eventCallback.Set(doEvent, 0);
    Nes::Api::User::questionCallback.Set(doQuestion, 0);

    // Load FDS BIOS
    Nes::Api::Fds fds(_emu);
    if([self.systemIdentifier isEqualToString:@"openemu.system.fds"])
    {
        NSString *biosFilePath = [self.biosDirectoryPath stringByAppendingPathComponent:@"disksys.rom"];
        std::ifstream biosFile(biosFilePath.fileSystemRepresentation, std::ios::in | std::ios::binary);
        fds.SetBIOS(&biosFile);
    }

    // Load ROM
    std::ifstream romFile(path.fileSystemRepresentation, std::ios::in | std::ios::binary);
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

        NSError *outErr = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{
                //NSLocalizedDescriptionKey : @"Could not load ROM.",
                NSLocalizedDescriptionKey : errorDescription,
                //NSLocalizedRecoverySuggestionErrorKey : errorDescription
                }];

            *error = outErr;

        return NO;
    }
    machine.Power(true);
    
    if (machine.Is(Nes::Api::Machine::DISK))
        fds.InsertDisk(0, 0);

    return YES;
}

- (void)setupEmulation
{
    // Auto connect controllers/adapter, info from database
    Nes::Api::Cartridge::Database database(_emu);

    if(database.IsLoaded())
    {
        Nes::Api::Input(_emu).AutoSelectControllers();
        Nes::Api::Input(_emu).AutoSelectAdapter();
    }
    else
        Nes::Api::Input(_emu).ConnectController(0, Nes::Api::Input::PAD1);

    // Auto set video format, info from database
    Nes::Api::Machine machine(_emu);
    machine.SetMode(machine.GetDesiredMode());

    // Setup Video
    Nes::Api::Video::RenderState renderState;

    _width  = Nes::Api::Video::Output::WIDTH;
    _height = Nes::Api::Video::Output::HEIGHT;

    renderState.bits.count = 32;
    renderState.bits.mask.r = 0xFF0000;
    renderState.bits.mask.g = 0x00FF00;
    renderState.bits.mask.b = 0x0000FF;

    renderState.filter = Nes::Api::Video::RenderState::FILTER_NONE;
    renderState.width = Nes::Api::Video::Output::WIDTH;
    renderState.height = Nes::Api::Video::Output::HEIGHT;

    Nes::Api::Video video(_emu);
    // set the render state, make use of the NES_FAILED macro, expands to: "if(function(...) < Nes::RESULT_OK)"
    if(NES_FAILED(video.SetRenderState(renderState)))
    {
        NSLog(@"[Nestopia] core rejected render state");
        exit(0);
    }

    // Setup Audio
    Nes::Api::Sound sound(_emu);
    sound.SetSampleBits(16);
    sound.SetSampleRate(SAMPLERATE);
    sound.SetVolume(Nes::Api::Sound::ALL_CHANNELS, 100);
    sound.SetSpeaker(Nes::Api::Sound::SPEAKER_MONO);
    sound.SetSpeed(self.frameInterval);

    _bufFrameSize = (SAMPLERATE / self.frameInterval);

    _soundBuffer = new int16_t[_bufFrameSize * self.channelCount];
    [[self ringBufferAtIndex:0] setLength:(sizeof(int16_t) * _bufFrameSize * self.channelCount * 5)];

    memset(_soundBuffer, 0, _bufFrameSize * self.channelCount * sizeof(int16_t));
    _nesSound->samples[0] = _soundBuffer;
    _nesSound->length[0] = _bufFrameSize;
    _nesSound->samples[1] = NULL;
    _nesSound->length[1] = 0;
}

- (void)executeFrame
{
    _emu.Execute(_nesVideo, _nesSound, _controls);

    [[self ringBufferAtIndex:0] write:_soundBuffer maxLength:self.channelCount * _bufFrameSize * sizeof(int16_t)];
}

- (void)resetEmulation
{
    Nes::Api::Machine machine(_emu);
    machine.Reset(true);

    // put the disk system back to disk 0 side 0
    if (machine.Is(Nes::Api::Machine::DISK))
    {
        Nes::Api::Fds fds(_emu);
        fds.EjectDisk();
        fds.InsertDisk(0, 0);
    }
}

- (void)stopEmulation
{
    Nes::Api::Machine machine(_emu);
    //machine.Power(false);
    machine.Unload(); // this allows FDS to save
    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    Nes::Api::Machine machine(_emu);

    if(machine.GetMode() == Nes::Api::Machine::NTSC)
        return Nes::Api::Machine::CLK_NTSC_DOT / Nes::Api::Machine::CLK_NTSC_VSYNC; // 60.0988138974
    else
        return Nes::Api::Machine::CLK_PAL_DOT / Nes::Api::Machine::CLK_PAL_VSYNC; // 50.0069789082
}

# pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (!hint)
    {
        if(!_indirectVideoBuffer)
        {
            _indirectVideoBuffer = new unsigned char[_width * _height * 4];
        }
        hint = (void *)_indirectVideoBuffer;
    }
    _nesVideo->pixels = hint;
    _nesVideo->pitch = _width * 4;
    return hint;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, 256, 240);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(Nes::Api::Video::Output::WIDTH, Nes::Api::Video::Output::HEIGHT);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(256 * (8.0/7.0), 240);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

# pragma mark - Audio

- (double)audioSampleRate
{
    return SAMPLERATE;
}

- (NSUInteger)channelCount
{
    return 1;
}

# pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    Nes::Result result;

    Nes::Api::Machine machine(_emu);
    std::ofstream stateFile(fileName.fileSystemRepresentation, std::ifstream::out|std::ifstream::binary);

    if(stateFile.is_open())
        result = machine.SaveState(stateFile, Nes::Api::Machine::NO_COMPRESSION);
    else {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : NSLocalizedString(@"The save state file could not be written", @"Nestopia state file could not be written description."),
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:NSLocalizedString(@"Could not write the file state in %@.", @"Nestopia state file could not be written suggestion."), fileName]
        }];

        block(NO, error);
        return;
    }

    if(NES_FAILED(result))  {
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

    Nes::Api::Machine machine(_emu);
    std::ifstream stateFile(fileName.fileSystemRepresentation, std::ifstream::in|std::ifstream::binary);

    if(stateFile.is_open())
        result = machine.LoadState(stateFile);
    else {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : NSLocalizedString(@"The save state file could not be opened", @"Nestopia state file could not be opened description."),
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:NSLocalizedString(@"Could not read the file state in %@.", @"Nestopia state file could not be opened suggestion."), fileName]
        }];

        block(NO, error);
        return;
    }

    if(NES_FAILED(result)) {
        NSString *errorDescription = nil;
        switch(result) {
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

- (NSData *)serializeStateWithError:(NSError **)outError
{
    Nes::Result result;
    Nes::Api::Machine machine(_emu);

    std::stringstream stateStream(std::ios::in|std::ios::out|std::ios::binary);

    result = machine.SaveState(stateStream, Nes::Api::Machine::NO_COMPRESSION);

    if(NES_FAILED(result)) {
        if (!outError)
            return nil;

        NSString *errorDescription = nil;
        switch(result) {
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

        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : errorDescription
        }];

        return NO;
    }

    stateStream.seekg(0, std::ios::end);
    NSUInteger length = stateStream.tellg();
    stateStream.seekg(0, std::ios::beg);

    NSMutableData *data = [NSMutableData dataWithLength:length];
    stateStream.read((char *)data.mutableBytes, length);
    return data;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    Nes::Result result;
    Nes::Api::Machine machine(_emu);

    std::stringstream stateStream(std::ios::in|std::ios::out|std::ios::binary);

    char const *bytes = (char const *)(state.bytes);
    std::streamsize size = state.length;
    stateStream.write(bytes, size);

    result = machine.LoadState(stateStream);

    if(NES_FAILED(result)) {
        if (!outError)
            return NO;

        NSString *errorDescription = nil;
        switch(result) {
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
        *outError = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state has wrong file size.",
            NSLocalizedRecoverySuggestionErrorKey : errorDescription,
        }];

        return NO;
    }

    return YES;
}

# pragma mark - Input

NSUInteger NESControlValues[] = { Nes::Api::Input::Controllers::Pad::UP, Nes::Api::Input::Controllers::Pad::DOWN, Nes::Api::Input::Controllers::Pad::LEFT, Nes::Api::Input::Controllers::Pad::RIGHT, Nes::Api::Input::Controllers::Pad::A, Nes::Api::Input::Controllers::Pad::B, Nes::Api::Input::Controllers::Pad::START, Nes::Api::Input::Controllers::Pad::SELECT
};
- (oneway void)didPushNESButton:(OENESButton)button forPlayer:(NSUInteger)player
{
    _controls->pad[player - 1].buttons |=  NESControlValues[button];
}

- (oneway void)didReleaseNESButton:(OENESButton)button forPlayer:(NSUInteger)player
{
    _controls->pad[player - 1].buttons &= ~NESControlValues[button];
}

- (oneway void)didTriggerGunAtPoint:(OEIntPoint)aPoint
{
    [self mouseMovedAtPoint:aPoint];

    _controls->paddle.button = 1;
    _controls->zapper.x = aPoint.x * 0.876712;
    _controls->zapper.y = aPoint.y;
    _controls->zapper.fire = 1;
    _controls->bandaiHyperShot.x = aPoint.x * 0.876712;
    _controls->bandaiHyperShot.y = aPoint.y;
    _controls->bandaiHyperShot.fire = 1;
}

- (oneway void)didReleaseTrigger
{
    _controls->paddle.button = 0;
    _controls->zapper.fire = 0;
    _controls->bandaiHyperShot.fire = 0;
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)aPoint
{
    _controls->paddle.x = aPoint.x * 0.876712;
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point
{
    _controls->bandaiHyperShot.move = 1;
}

- (oneway void)rightMouseUp
{
    _controls->bandaiHyperShot.move = 0;
}

- (oneway void)didPushFDSChangeSideButton
{
    Nes::Api::Fds fds(_emu);
    //fds.ChangeSide();
    Nes::Result result;
    if (fds.IsAnyDiskInserted() && fds.CanChangeDiskSide())
        result = fds.ChangeSide();
    else
        result = fds.InsertDisk(0, 0);
    NSLog(@"[Nestopia] didPushFDSChangeSideButton: %d", result);
}

- (oneway void)didReleaseFDSChangeSideButton
{

}

- (oneway void)didPushFDSChangeDiskButton
{
    Nes::Api::Fds fds(_emu);
    // if multi-disk game, eject and insert the other disk
    if (fds.GetNumDisks() > 1)
    {
        int currdisk = fds.GetCurrentDisk();
        fds.EjectDisk();
        fds.InsertDisk(!currdisk, 0);

        NSLog(@"[Nestopia] didPushFDSChangeDiskButton");
    }
}

- (oneway void)didReleaseFDSChangeDiskButton;
{

}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    Nes::Api::Cheats cheater(_emu);
    Nes::Api::Cheats::Code ggCode;

    if (enabled)
        _cheatList[code] = @YES;
    else
        [_cheatList removeObjectForKey:code];

    cheater.ClearCodes();

    NSArray<NSString *> *multipleCodes = [NSArray array];

    // Apply enabled cheats found in dictionary
    for (NSString *key in _cheatList)
    {
        if ([_cheatList[key] boolValue])
        {
            // Handle multi-line cheats
            multipleCodes = [key componentsSeparatedByString:@"+"];
            for (NSString *singleCode in multipleCodes) {
                const char *cCode = singleCode.UTF8String;

                Nes::Api::Cheats::GameGenieDecode(cCode, ggCode);
                cheater.SetCode(ggCode);
            }
        }
    }
}

# pragma mark - Display Mode

- (void)changeDisplayMode
{
    Nes::Api::Video video(_emu);

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

# pragma mark - Callbacks

// for various file operations, usually called during image file load, power on/off and reset
void NST_CALLBACK doFileIO(void *userData, Nes::Api::User::File &file)
{
    GET_CURRENT_OR_RETURN();

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *url = current->_romURL;

    NSString *extensionlessFilename = url.lastPathComponent.stringByDeletingPathExtension;
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:current.batterySavesDirectoryPath];
    [fileManager createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];

    NSData *theData;
    NSURL *saveFileURL;

    switch(file.GetAction())
    {
        case Nes::Api::User::File::LOAD_SAMPLE :
        case Nes::Api::User::File::LOAD_ROM :
            break;

        case Nes::Api::User::File::LOAD_BATTERY : // load in battery data from a file
        case Nes::Api::User::File::LOAD_EEPROM : // used by some Bandai games, can be treated the same as battery files
        {
            saveFileURL = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            if(![saveFileURL checkResourceIsReachableAndReturnError:nil])
            {
                NSLog(@"[Nestopia] Couldn't find Battery/EEPROM save at: %@", saveFileURL);
                return;
            }
            NSLog(@"[Nestopia] Loading Battery/EEPROM save: %@", saveFileURL);
            theData = [NSData dataWithContentsOfURL:saveFileURL];
            file.SetContent(theData.bytes, theData.length);
            break;
        }
        case Nes::Api::User::File::SAVE_BATTERY : // save battery data to a file
        case Nes::Api::User::File::SAVE_EEPROM : // can be treated the same as battery files
        {
            NSLog(@"[Nestopia] Saving Battery/EEPROM");
            const void *saveData;
            unsigned long saveDataSize;
            file.GetContent(saveData, saveDataSize);
            saveFileURL = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            theData = [NSData dataWithBytes:saveData length:saveDataSize];
            [theData writeToURL:saveFileURL atomically:YES];
            break;
        }
        case Nes::Api::User::File::LOAD_FDS:
        {
            NSLog(@"[Nestopia] Loading FDS save");
            saveFileURL = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            std::ifstream in_tmp(saveFileURL.fileSystemRepresentation, std::ifstream::in|std::ifstream::binary);

            if (!in_tmp.is_open())
                return;

            file.SetPatchContent(in_tmp);
            break;
        }
        case Nes::Api::User::File::SAVE_FDS: // for saving modified Famicom Disk System files
        {
            NSLog(@"[Nestopia] Saving FDS");
            saveFileURL = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
            std::ofstream out_tmp(saveFileURL.fileSystemRepresentation, std::ifstream::out|std::ifstream::binary);

            if (out_tmp.is_open())
                file.GetPatchContent(Nes::Api::User::File::PATCH_UPS, out_tmp);
            break;
        }
        case Nes::Api::User::File::LOAD_TAPE : // for loading Famicom cassette tapes
        case Nes::Api::User::File::SAVE_TAPE : // for saving Famicom cassette tapes
        case Nes::Api::User::File::LOAD_TURBOFILE : // for loading turbofile data
        case Nes::Api::User::File::SAVE_TURBOFILE : // for saving turbofile data
            break;

        case Nes::Api::User::File::LOAD_SAMPLE_MOERO_PRO_YAKYUU :
        case Nes::Api::User::File::LOAD_SAMPLE_MOERO_PRO_YAKYUU_88 :
        case Nes::Api::User::File::LOAD_SAMPLE_MOERO_PRO_TENNIS :
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

    NSLog(@"[Nestopia] CRC Failed");
    return Nes::Api::User::ANSWER_DEFAULT;
}

void NST_CALLBACK doLog(void *userData, const char *text, unsigned long length)
{
    NSLog(@"[Nestopia] %@", [NSString stringWithUTF8String:text]);
}

void NST_CALLBACK doEvent(void *userData, Nes::Api::Machine::Event event, Nes::Result result)
{
    switch(event)
    {
        case Nes::Api::Machine::EVENT_LOAD :
        case Nes::Api::Machine::EVENT_UNLOAD :
        case Nes::Api::Machine::EVENT_POWER_ON :
        case Nes::Api::Machine::EVENT_POWER_OFF :
        case Nes::Api::Machine::EVENT_RESET_SOFT :
        case Nes::Api::Machine::EVENT_RESET_HARD :
        case Nes::Api::Machine::EVENT_MODE_NTSC :
        case Nes::Api::Machine::EVENT_MODE_PAL :
            break;
    }
}

@end
