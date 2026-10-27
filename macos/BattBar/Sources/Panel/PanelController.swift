import AppKit
import SwiftUI

final class PanelController: NSObject, NSPopoverDelegate {
    let model: AppModel
    let actions: PanelActions
    let anchorProvider: () -> NSStatusBarButton?

    var onVisibilityChanged: ((Bool) -> Void)?
    var onOpen: (() -> Void)?

    private let popover = NSPopover()
    private var generation = 0

    init(model: AppModel, actions: PanelActions, anchorProvider: @escaping () -> NSStatusBarButton?) {
        self.model = model
        self.actions = actions
        self.anchorProvider = anchorProvider
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentSize = NSSize(width: 372, height: 560)
    }

    var isShown: Bool { popover.isShown }

    func toggle() {
        if popover.isShown {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard let button = anchorProvider(), !popover.isShown else { return }
        generation += 1
        let root = PanelView(model: model, actions: actions)
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 372, height: 560)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor(calibratedRed: 0.030, green: 0.038, blue: 0.030, alpha: 1).cgColor
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 372, height: 560)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        onVisibilityChanged?(true)
        onOpen?()
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        onVisibilityChanged?(false)
        // Release the SwiftUI hierarchy while the menu bar app is idle. The
        // generation check keeps a quick re-open from being torn down by the
        // previous close's deferred cleanup.
        let closedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == closedGeneration, !self.popover.isShown else { return }
            self.popover.contentViewController = nil
        }
    }
}
