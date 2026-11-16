import AppKit

/// The app's side of `DesktopCover`: starts the helper and takes it away again.
final class DesktopCoverSession {
    private let helper = Process()
    private var waiting: (() -> Void)?

    /// Covers the icons, then calls `ready` on the main thread. If the helper cannot
    /// start or takes too long, `ready` is called anyway: a capture with icons in it is
    /// better than none.
    func start(then ready: @escaping () -> Void) {
        waiting = ready
        let output = Pipe()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--desktop-cover"]
        helper.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            _ = handle.availableData
            handle.readabilityHandler = nil
            DispatchQueue.main.async { self?.proceed() }
        }
        do { try helper.run() } catch {
            proceed()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.proceed() }
    }

    private func proceed() {
        let ready = waiting
        waiting = nil
        ready?()
    }

    func stop() {
        waiting = nil
        if helper.isRunning { helper.terminate() }
    }
}
