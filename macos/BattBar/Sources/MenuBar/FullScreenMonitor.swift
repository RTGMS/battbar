import AppKit
import CoreGraphics

final class FullScreenMonitor {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var scheduledCheck: DispatchWorkItem?
    private var followUpCheck: DispatchWorkItem?
    private var lastValue = false

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleCheck()
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleCheck(delay: 0.15)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleCheck()
        })
        scheduleCheck(delay: 0.2)
    }

    func stop() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { token in
            workspaceCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        scheduledCheck?.cancel()
        followUpCheck?.cancel()
    }

    private func scheduleCheck(delay: TimeInterval = 0.08) {
        scheduledCheck?.cancel()
        followUpCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        scheduledCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

        // The frontmost application / window list can lag behind the
        // activation notification by a few hundred milliseconds. Re-check
        // once more so entering a fullscreen app is not missed.
        let followUp = DispatchWorkItem { [weak self] in self?.check() }
        followUpCheck = followUp
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.8, execute: followUp)
    }

    private func check() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              !front.isTerminated else {
            publish(false)
            return
        }

        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let screens = NSScreen.screens.map(\.frame)
        let fullscreen = windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == front.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return false
            }
            // Window bounds use Core Graphics' top-left origin while NSScreen
            // uses AppKit's bottom-left origin. Matching the size is enough to
            // identify a fullscreen window and avoids cross-screen origin bugs.
            return screens.contains { screen in
                rect.width >= screen.width - 2 && rect.height >= screen.height - 2
            }
        }
        publish(fullscreen)
    }

    private func publish(_ fullscreen: Bool) {
        guard lastValue != fullscreen else { return }
        lastValue = fullscreen
        onChange?(fullscreen)
    }
}
