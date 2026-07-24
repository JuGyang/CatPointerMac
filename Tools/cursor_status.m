#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>

int main(void) {
    printf("%d\n", CGCursorIsVisible() != 0);
    return 0;
}
