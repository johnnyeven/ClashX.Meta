//
//  StatusItemUpdatePolicy.swift
//  ClashX
//
//  Copyright © 2026 west2online. All rights reserved.
//

import AppKit
import Foundation
import ObjectiveC
import QuartzCore

private var statusItemUsesLeftIconLayoutKey: UInt8 = 0

@available(macOS 26, *)
private enum StatusItemNativeIconLayout {
    private static let iconInsetX: CGFloat = 3
    private static let iconSize: CGFloat = 18
    private static var didSwizzle = false

    static func activate(on cell: NSCell) {
        installSwizzleIfNeeded()
        objc_setAssociatedObject(
            cell,
            &statusItemUsesLeftIconLayoutKey,
            true,
            .OBJC_ASSOCIATION_RETAIN
        )
    }

    private static func installSwizzleIfNeeded() {
        guard !didSwizzle else { return }
        didSwizzle = true
        guard
            let original = class_getInstanceMethod(NSButtonCell.self, #selector(NSCell.imageRect(forBounds:))),
            let swizzled = class_getInstanceMethod(NSButtonCell.self, #selector(NSButtonCell.cx_statusItemImageRect(forBounds:)))
        else { return }
        method_exchangeImplementations(original, swizzled)
    }

    static func leftIconRect(in bounds: NSRect) -> NSRect {
        let y = (bounds.height - iconSize) / 2
        return NSRect(x: iconInsetX, y: y, width: iconSize, height: iconSize)
    }
}

@available(macOS 26, *)
extension NSButtonCell {
    @objc func cx_statusItemImageRect(forBounds rect: NSRect) -> NSRect {
        if objc_getAssociatedObject(self, &statusItemUsesLeftIconLayoutKey) != nil, image != nil {
            return StatusItemNativeIconLayout.leftIconRect(in: rect)
        }
        return cx_statusItemImageRect(forBounds: rect)
    }
}

protocol StatusItemPresenting: AnyObject {
    func applyProxyEnabled(_ enabled: Bool)
    func applySpeed(up: Int, down: Int)
    func applySpeedVisible(_ visible: Bool)
    func applyWidth(_ width: CGFloat)
    func applyLayout(showSpeed: Bool, width: CGFloat)
}

enum StatusItemPresenterFactory {
    static func make(statusItem: NSStatusItem) -> StatusItemPresenting {
        if #available(macOS 26, *) {
            return NativeStatusItemPresenter(statusItem: statusItem)
        }
        return LegacyStatusItemPresenter(statusItem: statusItem)
    }
}

// MARK: - Traffic throttle

final class StatusItemTrafficThrottler {
    static let shared = StatusItemTrafficThrottler()

    private let interval: TimeInterval = 1.0
    private var lastFlushTime: TimeInterval = 0
    private var pendingUp: Int?
    private var pendingDown: Int?
    private var pendingWorkItem: DispatchWorkItem?

    private init() {}

    func submit(up: Int, down: Int, apply: @escaping (Int, Int) -> Void) {
        pendingUp = up
        pendingDown = down
        pendingWorkItem?.cancel()

        let now = CACurrentMediaTime()
        let elapsed = now - lastFlushTime
        if elapsed >= interval {
            flush(apply: apply)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flush(apply: apply)
        }
        pendingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (interval - elapsed), execute: workItem)
    }

    func flushImmediately(apply: @escaping (Int, Int) -> Void) {
        pendingWorkItem?.cancel()
        flush(apply: apply)
    }

    private func flush(apply: (Int, Int) -> Void) {
        guard let up = pendingUp, let down = pendingDown else { return }
        pendingUp = nil
        pendingDown = nil
        pendingWorkItem = nil
        lastFlushTime = CACurrentMediaTime()
        apply(up, down)
    }
}

// MARK: - Legacy (custom subview)

final class LegacyStatusItemPresenter: StatusItemPresenting {
    private weak var statusItem: NSStatusItem?
    private let view: StatusItemViewProtocol

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        view = StatusItemView.create(statusItem: statusItem)
        if let statusView = view as? StatusItemView {
            statusView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        }
    }

    func applyProxyEnabled(_ enabled: Bool) {
        view.updateViewStatus(enableProxy: enabled)
    }

    func applySpeed(up: Int, down: Int) {
        view.updateSpeedLabel(up: up, down: down)
    }

    func applySpeedVisible(_ visible: Bool) {
        view.showSpeedContainer(show: visible)
    }

    func applyWidth(_ width: CGFloat) {
        view.updateSize(width: width)
    }

    func applyLayout(showSpeed: Bool, width: CGFloat) {
        view.showSpeedContainer(show: showSpeed)
        view.updateSize(width: width)
        statusItem?.length = width
    }
}

// MARK: - macOS 26+ (system template icon + draw-based speed overlay)

/// Draws speed text only; does not intercept clicks (passes through to `NSStatusBarButton`).
@available(macOS 26, *)
private final class NativeSpeedOverlayView: NSView {
    private var uploadText = ""
    private var downloadText = ""
    private let rightAlignedStyle: NSMutableParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        return style
    }()

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: StatusItemTool.font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: rightAlignedStyle,
        ]
        let width = bounds.width
        uploadText.draw(
            with: NSRect(x: 0, y: 11, width: width, height: 10),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        downloadText.draw(
            with: NSRect(x: 0, y: 1, width: width, height: 10),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
    }

    func setSpeed(upload: String, download: String) {
        var needsRedraw = false
        if uploadText != upload {
            uploadText = upload
            needsRedraw = true
        }
        if downloadText != download {
            downloadText = download
            needsRedraw = true
        }
        if needsRedraw {
            needsDisplay = true
        }
    }
}

@available(macOS 26, *)
final class NativeStatusItemPresenter: StatusItemPresenting {
    private static let barHeight: CGFloat = 22
    private static let speedOriginX: CGFloat = 38
    private static let trailingInset: CGFloat = 3

    private let statusItem: NSStatusItem
    private let speedOverlay = NativeSpeedOverlayView(frame: .zero)
    private var proxyEnabled = false
    private var speedVisible = true
    private var up = 0
    private var down = 0
    private var currentWidth: CGFloat

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        let length = statusItem.length
        currentWidth = length > 0 ? length : 72

        guard let button = statusItem.button else { return }

        let image = StatusItemTool.menuImage
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = nil
        if let cell = button.cell {
            StatusItemNativeIconLayout.activate(on: cell)
            if let buttonCell = cell as? NSButtonCell {
                buttonCell.imageScaling = .scaleProportionallyDown
            }
        }

        speedOverlay.wantsLayer = false
        button.addSubview(speedOverlay)
        updateSpeedOverlayFrame()
    }

    func applyProxyEnabled(_ enabled: Bool) {
        guard proxyEnabled != enabled else { return }
        proxyEnabled = enabled
        guard let button = statusItem.button else { return }
        button.appearsDisabled = !enabled
        button.alphaValue = 1
    }

    func applySpeed(up: Int, down: Int) {
        guard speedVisible else { return }
        guard self.up != up || self.down != down else { return }
        self.up = up
        self.down = down
        speedOverlay.setSpeed(
            upload: SpeedUtils.getSpeedString(for: up),
            download: SpeedUtils.getSpeedString(for: down)
        )
    }

    func applySpeedVisible(_ visible: Bool) {
        guard speedVisible != visible else { return }
        speedVisible = visible
        speedOverlay.isHidden = !visible
        if !visible {
            up = 0
            down = 0
        }
    }

    func applyWidth(_ width: CGFloat) {
        guard currentWidth != width else { return }
        currentWidth = width
        statusItem.length = width
        updateSpeedOverlayFrame()
    }

    func applyLayout(showSpeed: Bool, width: CGFloat) {
        if !showSpeed {
            up = 0
            down = 0
        }
        speedVisible = showSpeed
        currentWidth = width
        statusItem.length = width
        speedOverlay.isHidden = !showSpeed
        updateSpeedOverlayFrame()
        applyProxyEnabled(proxyEnabled)
    }

    private func updateSpeedOverlayFrame() {
        let speedWidth = max(0, currentWidth - Self.speedOriginX - Self.trailingInset)
        speedOverlay.frame = NSRect(
            x: Self.speedOriginX,
            y: 0,
            width: speedWidth,
            height: Self.barHeight
        )
    }
}
