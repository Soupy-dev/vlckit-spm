#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void * _Nullable (*VLCKitSPMVideoLockCallback)(void * _Nullable opaque, void * _Nullable * _Nonnull planes);
typedef void (*VLCKitSPMVideoUnlockCallback)(void * _Nullable opaque, void * _Nullable picture, void * _Nullable const * _Nonnull planes);
typedef void (*VLCKitSPMVideoDisplayCallback)(void * _Nullable opaque, void * _Nullable picture);
typedef unsigned (*VLCKitSPMVideoFormatCallback)(void * _Nullable * _Nonnull opaque, char * _Nonnull chroma, unsigned * _Nonnull width, unsigned * _Nonnull height, unsigned * _Nonnull pitches, unsigned * _Nonnull lines);
typedef void (*VLCKitSPMVideoCleanupCallback)(void * _Nullable opaque);

FOUNDATION_EXPORT BOOL VLCKitSPMInstallVideoCallbacks(
    id mediaPlayer,
    VLCKitSPMVideoLockCallback lockCallback,
    VLCKitSPMVideoUnlockCallback _Nullable unlockCallback,
    VLCKitSPMVideoDisplayCallback _Nullable displayCallback,
    VLCKitSPMVideoFormatCallback formatCallback,
    VLCKitSPMVideoCleanupCallback _Nullable cleanupCallback,
    void *opaque
);

FOUNDATION_EXPORT void VLCKitSPMClearVideoCallbacks(id mediaPlayer);

NS_ASSUME_NONNULL_END
