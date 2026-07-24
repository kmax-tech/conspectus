#import "include/ConspectusShield.h"
#import <objc/runtime.h>

// See the header for why this exists. The swizzle replaces the IMP with a
// block that calls the original inside @try/@catch — behavior is unchanged
// except that the (unfixable, framework-internal) KVO exception no longer
// terminates the process. Worst case after a swallowed throw: the preview's
// scrollers are half-torn until the next preview request rebuilds them.
//
// Note: class_getInstanceMethod resolves inherited methods, so if
// _teardownScrollers ever moves to a superclass the swizzle lands there and
// covers all its subclasses. That is acceptable here — the wrapper is
// semantically transparent (original runs unchanged, only the throw is
// contained), so wider coverage widens the protection, not the behavior
// change.
bool conspectus_installQLTeardownShield(void) {
    Class cls = NSClassFromString(@"QLScrollController");
    SEL sel = NSSelectorFromString(@"_teardownScrollers");
    if (cls == Nil) {
        return false;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        return false;
    }
    void (*orig)(id, SEL) = (void (*)(id, SEL))method_getImplementation(m);
    IMP wrapped = imp_implementationWithBlock(^(id _self) {
        @try {
            orig(_self, sel);
        } @catch (NSException *e) {
            NSLog(@"conspectus: swallowed QLScrollController teardown exception (%@): %@",
                  e.name, e.reason);
        }
    });
    method_setImplementation(m, wrapped);
    return true;
}
