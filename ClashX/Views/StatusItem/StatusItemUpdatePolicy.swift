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

// MARK: - macOS 26+ (layout view: icon left + speed right, same geometry as StatusItemView.xib)

@available(macOS 26, *)
private final class NativeStatusBarLayoutView: NSView {
    private static let barHeight: CGFloat = 22
    private static let iconInsetX: CGFloat = 3
    private static let iconSize: CGFloat = 18
    private static let speedOriginX: CGFloat = 38
    private static let trailingInset: CGFloat = 3

    private let iconView = NSImageView(frame: .zero)
    private let speedOverlay = NativeSpeedOverlayView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = false

        let image = StatusItemTool.menuImage
        image.isTemplate = true
        iconView.image = image
        iconView.imageFrameStyle = .none
        iconView.wantsLayer = false
        addSubview(iconView)

        speedOverlay.wantsLayer = false
        addSubview(speedOverlay)

        updateLayout(width: bounds.width)
    }

    func updateLayout(width: CGFloat) {
        frame.size.width = width
        let iconY = (Self.barHeight - Self.iconSize) / 2
        iconView.frame = NSRect(x: Self.iconInsetX, y: iconY, width: Self.iconSize, height: Self.iconSize)

        let speedWidth = max(0, width - Self.speedOriginX - Self.trailingInset)
        speedOverlay.frame = NSRect(x: Self.speedOriginX, y: 0, width: speedWidth, height: Self.barHeight)
    }

    func applyProxyEnabled(_ enabled: Bool) {
        if enabled {
            iconView.contentTintColor = .labelColor
        } else {
            iconView.contentTintColor = .labelColor.withSystemEffect(.disabled)
        }
    }

    func applySpeedVisible(_ visible: Bool) {
        speedOverlay.isHidden = !visible
    }

    func setSpeed(upload: String, download: String) {
        speedOverlay.setSpeed(upload: upload, download: download)
    }
}

/// Speed labels only (right side of layout view).
@available(macOS 26, *)
private final class NativeSpeedOverlayView: NSView {
    private let uploadLabel = NSTextField(labelWithString: "")
    private let downloadLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = false
        for label in [uploadLabel, downloadLabel] {
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.drawsBackground = false
            label.isBordered = false
            label.font = StatusItemTool.font
            label.textColor = .labelColor
            label.alignment = .right
            label.lineBreakMode = .byClipping
            label.wantsLayer = false
            addSubview(label)
        }
        layoutLabels()
    }

    private func layoutLabels() {
        let w = bounds.width
        uploadLabel.frame = NSRect(x: 0, y: 11, width: w, height: 10)
        downloadLabel.frame = NSRect(x: 0, y: 1, width: w, height: 10)
    }

    override func layout() {
        super.layout()
        layoutLabels()
    }

    func setSpeed(upload: String, download: String) {
        if uploadLabel.stringValue != upload {
            uploadLabel.stringValue = upload
        }
        if downloadLabel.stringValue != download {
            downloadLabel.stringValue = download
        }
    }

}

@available(macOS 26, *)
final class NativeStatusItemPresenter: StatusItemPresenting {
    private let statusItem: NSStatusItem
    private let layoutView: NativeStatusBarLayoutView
    private var proxyEnabled = false
    private var speedVisible = true
    private var up = 0
    private var down = 0
    private var currentWidth: CGFloat

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        let length = statusItem.length
        currentWidth = length > 0 ? length : 72
        layoutView = NativeStatusBarLayoutView(
            frame: NSRect(x: 0, y: 0, width: currentWidth, height: 22)
        )

        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.imagePosition = .imageOverlaps
        button.contentTintColor = nil

        layoutView.autoresizingMask = [.width, .height]
        button.addSubview(layoutView)
        layoutView.updateLayout(width: currentWidth)
    }

    func applyProxyEnabled(_ enabled: Bool) {
        guard proxyEnabled != enabled else { return }
        proxyEnabled = enabled
        layoutView.applyProxyEnabled(enabled)
    }

    func applySpeed(up: Int, down: Int) {
        guard speedVisible else { return }
        guard self.up != up || self.down != down else { return }
        self.up = up
        self.down = down
        layoutView.setSpeed(
            upload: SpeedUtils.getSpeedString(for: up),
            download: SpeedUtils.getSpeedString(for: down)
        )
    }

    func applySpeedVisible(_ visible: Bool) {
        guard speedVisible != visible else { return }
        speedVisible = visible
        layoutView.applySpeedVisible(visible)
        if !visible {
            up = 0
            down = 0
        }
    }

    func applyWidth(_ width: CGFloat) {
        guard currentWidth != width else { return }
        currentWidth = width
        statusItem.length = width
        layoutView.updateLayout(width: width)
    }

    func applyLayout(showSpeed: Bool, width: CGFloat) {
        if !showSpeed {
            up = 0
            down = 0
        }
        speedVisible = showSpeed
        currentWidth = width
        statusItem.length = width
        layoutView.applySpeedVisible(showSpeed)
        layoutView.updateLayout(width: width)
        layoutView.applyProxyEnabled(proxyEnabled)
    }
}
