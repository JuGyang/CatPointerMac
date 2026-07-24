#import <Foundation/Foundation.h>
#import <dlfcn.h>

int main(void) {
    @autoreleasepool {
        const char *names[] = {
            "CGSMainConnectionID",
            "_CGSDefaultConnection",
            "CGSRegisterCursorWithImages",
            "CGSRemoveRegisteredCursor",
            "CGSCopyRegisteredCursorImages",
            "CGSGetRegisteredCursorImages",
            "CGSSetRegisteredCursor",
            "CGSCreateRegisteredCursorImage",
            "CGSGetRegisteredCursorData2",
            "CGSGetGlobalCursorDataSize",
            "CGSGetGlobalCursorData",
            "CGSCurrentCursorSeed",
            "CoreCursorUnregisterAll",
            "CoreCursorSet",
            "CoreCursorCopyImages",
            "CGCursorIsVisible",
            NULL,
        };

        BOOL allRequired = YES;
        for (NSUInteger index = 0; names[index] != NULL; index++) {
            void *symbol = dlsym(RTLD_DEFAULT, names[index]);
            printf("%-36s %s\n", names[index],
                   symbol == NULL ? "missing" : "available");
            if (index < 4 && symbol == NULL) {
                allRequired = NO;
            }
        }
        return allRequired ? 0 : 1;
    }
}
