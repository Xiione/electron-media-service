#include "module.h"
#include "nan.h"
#import <AppKit/AppKit.h>

static std::string trackID;

@implementation NativeMediaController
  DarwinMediaService* _service;

- (void)associateService:(DarwinMediaService*)service {
  _service = service;
}

- (MPRemoteCommandHandlerStatus)remotePlay { _service->Emit("play"); return MPRemoteCommandHandlerStatusSuccess; }
- (MPRemoteCommandHandlerStatus)remotePause { _service->Emit("pause"); return MPRemoteCommandHandlerStatusSuccess; }
- (MPRemoteCommandHandlerStatus)remoteTogglePlayPause { _service->Emit("playPause"); return MPRemoteCommandHandlerStatusSuccess; }
- (MPRemoteCommandHandlerStatus)remoteNext { _service->Emit("next"); return MPRemoteCommandHandlerStatusSuccess; }
- (MPRemoteCommandHandlerStatus)remotePrev { _service->Emit("previous"); return MPRemoteCommandHandlerStatusSuccess; }

- (MPRemoteCommandHandlerStatus)remoteChangePlaybackPosition:(MPChangePlaybackPositionCommandEvent*)event {
  _service->EmitWithInt("seek", event.positionTime);
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)move:(MPChangePlaybackPositionCommandEvent*)event {
  return MPRemoteCommandHandlerStatusSuccess;
}

@end

static Nan::Persistent<v8::Function> persistentCallback;

NAN_METHOD(DarwinMediaService::Hook) {
  Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  v8::Local<v8::Function> cb = Nan::To<v8::Function>(info[0]).ToLocalChecked();
  persistentCallback.Reset(cb);
}

void DarwinMediaService::Emit(std::string eventName) {
  EmitWithInt(eventName, 0);
}

void DarwinMediaService::EmitWithInt(std::string eventName, int details) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::HandleScope handleScope(isolate);

  v8::Local<v8::Value> argv[2] = {
    Nan::New<v8::String>(eventName.c_str()).ToLocalChecked(),
    Nan::New<v8::Integer>(details)
  };

  v8::Local<v8::Function> callback = Nan::New(persistentCallback);

  Nan::AsyncResource resource("auryo:addon.callback");
  resource.runInAsyncScope(Nan::GetCurrentContext()->Global(), callback, 2, argv);
}

NAN_METHOD(DarwinMediaService::New) {
  DarwinMediaService *service = new DarwinMediaService();
  service->Wrap(info.This());
  info.GetReturnValue().Set(info.This());
}

NAN_METHOD(DarwinMediaService::StartService) {
  DarwinMediaService *self = Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  NativeMediaController* controller = [[NativeMediaController alloc] init];
  [controller associateService:self];

  MPRemoteCommandCenter *remoteCommandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  [remoteCommandCenter playCommand].enabled = true;
  [remoteCommandCenter pauseCommand].enabled = true;
  [remoteCommandCenter togglePlayPauseCommand].enabled = true;
  [remoteCommandCenter changePlaybackPositionCommand].enabled = true;
  [remoteCommandCenter nextTrackCommand].enabled = true;
  [remoteCommandCenter previousTrackCommand].enabled = true;

  [[remoteCommandCenter playCommand] addTarget:controller action:@selector(remotePlay)];
  [[remoteCommandCenter pauseCommand] addTarget:controller action:@selector(remotePause)];
  [[remoteCommandCenter togglePlayPauseCommand] addTarget:controller action:@selector(remoteTogglePlayPause)];
  [[remoteCommandCenter changePlaybackPositionCommand] addTarget:controller action:@selector(remoteChangePlaybackPosition:)];
  [[remoteCommandCenter nextTrackCommand] addTarget:controller action:@selector(remoteNext)];
  [[remoteCommandCenter previousTrackCommand] addTarget:controller action:@selector(remotePrev)];
}

NAN_METHOD(DarwinMediaService::StopService) {
  Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());
  
  MPRemoteCommandCenter *remoteCommandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  [remoteCommandCenter playCommand].enabled = false;
  [remoteCommandCenter pauseCommand].enabled = false;
  [remoteCommandCenter togglePlayPauseCommand].enabled = false;
  [remoteCommandCenter changePlaybackPositionCommand].enabled = false;
}

NAN_METHOD(DarwinMediaService::SetMetaData) {
  Nan::ObjectWrap::Unwrap<DarwinMediaService>(info.This());

  std::string songTitle = *Nan::Utf8String(info[0]);
  std::string songArtist = *Nan::Utf8String(info[1]);
  std::string songAlbum = *Nan::Utf8String(info[2]);
  std::string songState = *Nan::Utf8String(info[3]);
  std::string songID = *Nan::Utf8String(info[4]);
  double currentTime = info[5]->NumberValue(Nan::GetCurrentContext()).ToChecked();
  double duration = info[6]->NumberValue(Nan::GetCurrentContext()).ToChecked();

  std::string newPosterUrl;
  if (!info[7]->IsUndefined() && !info[7]->IsNull())
   newPosterUrl = *Nan::Utf8String(info[7]);

  NSMutableDictionary *songInfo = [[NSMutableDictionary alloc] init];
  [songInfo setObject:[NSString stringWithUTF8String:songTitle.c_str()] forKey:MPMediaItemPropertyTitle];
  [songInfo setObject:[NSString stringWithUTF8String:songArtist.c_str()] forKey:MPMediaItemPropertyArtist];
  [songInfo setObject:[NSString stringWithUTF8String:songAlbum.c_str()] forKey:MPMediaItemPropertyAlbumTitle];
  [songInfo setObject:[NSNumber numberWithFloat:currentTime] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
  [songInfo setObject:[NSNumber numberWithFloat:duration] forKey:MPMediaItemPropertyPlaybackDuration];
  [songInfo setObject:[NSString stringWithUTF8String:songID.c_str()] forKey:MPMediaItemPropertyPersistentID];
  songInfo[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);

  if (songState == "playing") 
  {
    [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePlaying;
    [songInfo setObject:[NSNumber numberWithFloat:1.0f] forKey:MPNowPlayingInfoPropertyPlaybackRate];
  } 
  else if (songState == "paused") 
  {
    [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePaused;
    [songInfo setObject:[NSNumber numberWithFloat:0.0f] forKey:MPNowPlayingInfoPropertyPlaybackRate];
  } 
  else 
  {
    [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStateStopped;
  }

  // Build artwork.
  MPMediaItemArtwork* artwork = nil;
  if (!newPosterUrl.empty())
  {
    NSString* posterUrlStr = [NSString stringWithUTF8String:newPosterUrl.c_str()];
    NSImage* poster = nil;
    
    if ([posterUrlStr hasPrefix:@"file://"])
    {
        // Handle file URLs: strip off "file://"
        NSString* filePath = [posterUrlStr substringFromIndex:7];
        poster = [[NSImage alloc] initWithContentsOfFile:filePath];
    }
    else if ([posterUrlStr hasPrefix:@"data:"])
    {
        // Handle base64 URLs, assuming the format "data:image/png;base64,<base64data>"
        NSRange commaRange = [posterUrlStr rangeOfString:@","];
        if (commaRange.location != NSNotFound)
        {
            NSString* base64DataStr = [posterUrlStr substringFromIndex:commaRange.location + 1];
            NSData* imageData = [[NSData alloc] initWithBase64EncodedString:base64DataStr
                                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (imageData)
            {
                poster = [[NSImage alloc] initWithData:imageData];
            }
        }
    }

    if (poster)
    {
        artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:poster.size requestHandler:^NSImage* _Nonnull(CGSize size) {
            return poster;
        }];
    }
  }

  if (@available(macOS 10.13.2, *))
  {
    if (artwork)
      [songInfo setObject:artwork forKey:MPMediaItemPropertyArtwork];
  }

  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:songInfo];
}
