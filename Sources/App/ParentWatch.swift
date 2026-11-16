import Foundation

/// Ends a helper process with the app that started it. If the app is gone (it crashed or
/// was forced to quit), the helper is sent the SIGTERM the app would have sent to stop
/// it, so each helper stops the way it already does when cancelled: the scrolling
/// capture deletes its scratch files, the others simply end. Nothing keeps capturing the
/// screen or covering the desktop icons for an app that is no longer there.
enum ParentWatch {
    private static var source: DispatchSourceProcess?

    static func start() {
        let parent = getppid()
        let stop = { _ = kill(getpid(), SIGTERM) }
        // An orphan is adopted by launchd (pid 1).
        guard parent > 1 else { stop(); return }
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        watch.setEventHandler(handler: stop)
        watch.resume()
        source = watch
        // The app may have gone before the watch began.
        if getppid() != parent { stop() }
    }
}
