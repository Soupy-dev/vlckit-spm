#import "VLCKitSPMObjCBridge.h"
#import <objc/message.h>

typedef struct libvlc_media_player_t libvlc_media_player_t;

extern void libvlc_video_set_callbacks(libvlc_media_player_t *mp,
                                       VLCKitSPMVideoLockCallback lock,
                                       VLCKitSPMVideoUnlockCallback unlock,
                                       VLCKitSPMVideoDisplayCallback display,
                                       void *opaque);

extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *mp,
                                              VLCKitSPMVideoFormatCallback setup,
                                              VLCKitSPMVideoCleanupCallback cleanup);

static libvlc_media_player_t *VLCKitSPMMediaPlayerInstance(id mediaPlayer)
{
    if (mediaPlayer == nil) {
        return NULL;
    }

    SEL playerInstanceSelector = NSSelectorFromString(@"playerInstance");
    if ([mediaPlayer respondsToSelector:playerInstanceSelector]) {
        void *(*send)(id, SEL) = (void *(*)(id, SEL))objc_msgSend;
        return (libvlc_media_player_t *)send(mediaPlayer, playerInstanceSelector);
    }

    SEL libVLCMediaPlayerSelector = NSSelectorFromString(@"libVLCMediaPlayer");
    if ([mediaPlayer respondsToSelector:libVLCMediaPlayerSelector]) {
        void *(*send)(id, SEL) = (void *(*)(id, SEL))objc_msgSend;
        return (libvlc_media_player_t *)send(mediaPlayer, libVLCMediaPlayerSelector);
    }

    return NULL;
}

BOOL VLCKitSPMInstallVideoCallbacks(id mediaPlayer,
                                    VLCKitSPMVideoLockCallback lockCallback,
                                    VLCKitSPMVideoUnlockCallback unlockCallback,
                                    VLCKitSPMVideoDisplayCallback displayCallback,
                                    VLCKitSPMVideoFormatCallback formatCallback,
                                    VLCKitSPMVideoCleanupCallback cleanupCallback,
                                    void *opaque)
{
    libvlc_media_player_t *player = VLCKitSPMMediaPlayerInstance(mediaPlayer);
    if (player == NULL || lockCallback == NULL || formatCallback == NULL) {
        return NO;
    }

    libvlc_video_set_callbacks(player, lockCallback, unlockCallback, displayCallback, opaque);
    libvlc_video_set_format_callbacks(player, formatCallback, cleanupCallback);
    return YES;
}

void VLCKitSPMClearVideoCallbacks(id mediaPlayer)
{
    libvlc_media_player_t *player = VLCKitSPMMediaPlayerInstance(mediaPlayer);
    if (player == NULL) {
        return;
    }

    libvlc_video_set_callbacks(player, NULL, NULL, NULL, NULL);
    libvlc_video_set_format_callbacks(player, NULL, NULL);
}
