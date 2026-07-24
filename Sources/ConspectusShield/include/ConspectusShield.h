#import <Foundation/Foundation.h>

/// Wrap QuickLook's private `-[QLScrollController _teardownScrollers]` in
/// @try/@catch. Its KVO deregistration can throw an NSException while macOS
/// switches the recommended scroller style mid WebKit layer commit (fast
/// wheel-scrolling a Web2/markdown preview); the exception crosses noexcept
/// C++ frames in WebKit and aborts the app. Swift cannot catch ObjC
/// exceptions, hence this ObjC shim.
///
/// Returns true if the shield was installed; false when the private class or
/// method no longer exists (macOS update) — the caller must warn loudly, the
/// crash is then possible again.
bool conspectus_installQLTeardownShield(void);
