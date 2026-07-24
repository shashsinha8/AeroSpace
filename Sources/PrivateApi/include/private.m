// This file exists purely because xcode doesn't like header only targets, SPM is fine with them
#import "private.h"
#import <dlfcn.h>

typedef int32_t SLSConnectionID;
typedef SLSConnectionID (*SLSMainConnectionIDFn)(void);
typedef CGError (*SLSSetWindowLevelFn)(SLSConnectionID, uint32_t, int32_t);

bool aerospaceSetWindowLevel(uint32_t windowId, int32_t level) {
    static SLSMainConnectionIDFn mainConnectionId = NULL;
    static SLSSetWindowLevelFn setWindowLevel = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        );
        if (skyLight == NULL) {
            return;
        }
        mainConnectionId = (SLSMainConnectionIDFn)dlsym(skyLight, "SLSMainConnectionID");
        setWindowLevel = (SLSSetWindowLevelFn)dlsym(skyLight, "SLSSetWindowLevel");
    });

    if (mainConnectionId == NULL || setWindowLevel == NULL) {
        return false;
    }
    return setWindowLevel(mainConnectionId(), windowId, level) == kCGErrorSuccess;
}
