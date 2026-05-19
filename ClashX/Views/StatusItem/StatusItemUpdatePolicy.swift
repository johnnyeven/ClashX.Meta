//
//  StatusItemUpdatePolicy.swift
//  ClashX
//
//  Copyright © 2026 west2online. All rights reserved.
//

import AppKit
import Foundation
import QuartzCore

protocol StatusItemPresenting: AnyObject {
    func applyProxyEnabled(_ enabled: Bool)
    func applySpeed(up: Int, down: Int)
    func applySpeedVisible(_ visible: Bool)
    func applyWidth(_ width: CGFloat)
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
    private let view: StatusItemViewProtocol

    init(statusItem: NSStatusItem) {
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
}

// MARK: - macOS 26+ (composite template image, no subviews)

/// Renders icon + speed into one template image to avoid NSStatusItem subview redraw storms.
@available(macOS 26, *)
private enum StatusItemCompositeRenderer {
    static let height: CGFloat = 22
    static let iconInset: CGFloat = 3
    static let iconSize: CGFloat = 18
    static let speedLeading: CGFloat = 24
    static let trailingInset: CGFloat = 3
    static let lineHeight: CGFloat = 10

    static func render(
        width: CGFloat,
        showSpeed: Bool,
        upload: String,
        download: String,
        enabled: Bool
    ) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelW = max(1, Int(width * scale))
        let pixelH = max(1, Int(height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return StatusItemTool.menuImage
        }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        ctx.cgContext.scaleBy(x: scale, y: scale)
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let iconY = (height - iconSize) / 2
        StatusItemTool.menuImage.draw(
            in: NSRect(x: iconInset, y: iconY, width: iconSize, height: iconSize),
            from: .zero,
            operation: .sourceOver,
            fraction: enabled ? 1 : 0.45
        )

        if showSpeed {
            let textWidth = width - speedLeading - trailingInset
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            let textAlpha = enabled ? 1.0 : 0.45
            let attrs: [NSAttributedString.Key: Any] = [
                .font: StatusItemTool.font,
                .foregroundColor: NSColor.black.withAlphaComponent(textAlpha),
                .paragraphStyle: style,
            ]
            let uploadRect = NSRect(x: speedLeading, y: height - 1 - lineHeight, width: textWidth, height: lineHeight)
            let downloadRect = NSRect(x: speedLeading, y: 1, width: textWidth, height: lineHeight)
            (upload as NSString).draw(with: uploadRect, options: .usesLineFragmentOrigin, attributes: attrs)
            (download as NSString).draw(with: downloadRect, options: .usesLineFragmentOrigin, attributes: attrs)
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

@available(macOS 26, *)
final class NativeStatusItemPresenter: StatusItemPresenting {
    private struct RenderState: Equatable {
        var width: CGFloat
        var showSpeed: Bool
        var upload: String
        var download: String
        var enabled: Bool
    }

    private let statusItem: NSStatusItem
    private var proxyEnabled = false
    private var speedVisible = true
    private var up = 0
    private var down = 0
    private var currentWidth: CGFloat = 25
    private var lastRenderState: RenderState?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = nil
        refreshImageIfNeeded()
    }

    func applyProxyEnabled(_ enabled: Bool) {
        guard proxyEnabled != enabled else { return }
        proxyEnabled = enabled
        refreshImageIfNeeded()
    }

    func applySpeed(up: Int, down: Int) {
        guard speedVisible else { return }
        guard self.up != up || self.down != down else { return }
        self.up = up
        self.down = down
        refreshImageIfNeeded()
    }

    func applySpeedVisible(_ visible: Bool) {
        guard speedVisible != visible else { return }
        speedVisible = visible
        if !visible {
            up = 0
            down = 0
        }
        refreshImageIfNeeded()
    }

    func applyWidth(_ width: CGFloat) {
        guard currentWidth != width else { return }
        currentWidth = width
        statusItem.length = width
        refreshImageIfNeeded()
    }

    private func refreshImageIfNeeded() {
        guard let button = statusItem.button else { return }

        let upload = SpeedUtils.getSpeedString(for: up)
        let download = SpeedUtils.getSpeedString(for: down)
        let state = RenderState(
            width: currentWidth,
            showSpeed: speedVisible,
            upload: upload,
            download: download,
            enabled: proxyEnabled
        )
        guard state != lastRenderState else { return }
        lastRenderState = state

        button.contentTintColor = nil
        button.alphaValue = 1
        button.image = StatusItemCompositeRenderer.render(
            width: currentWidth,
            showSpeed: speedVisible,
            upload: upload,
            download: download,
            enabled: proxyEnabled
        )
    }
}
