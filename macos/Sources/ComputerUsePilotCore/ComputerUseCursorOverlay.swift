import AppKit
import CoreGraphics
import Foundation
import QuartzCore

func computerUseCursorAnimationDuration(for distance: CGFloat) -> TimeInterval {
  min(0.55, max(0.16, TimeInterval(distance / 1_400)))
}

/// A visible, click-through marker for actions injected by the Computer Use
/// helper. This is deliberately an overlay rather than a macOS cursor: macOS
/// has one hardware cursor and moving it would interfere with the user.
@MainActor
public final class ComputerUseCursorOverlay: NSObject {
  private var canvasView: ComputerUseCursorCanvasView?
  private var panel: NSPanel?

  // Keep the former argument for binary-compatible incremental rebuilds. The
  // cursor now lives for the helper session rather than a fixed duration.
  public init(displayDuration _: TimeInterval = .infinity) {
    super.init()
  }

  public func showAtMainScreenCenter() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
      return
    }
    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
      .map { CGDirectDisplayID($0.uint32Value) }
    let bounds = displayID.map(CGDisplayBounds) ?? screen.frame
    showClick(at: CGPoint(x: bounds.midX, y: bounds.midY))
  }

  public func hide() {
    panel?.orderOut(nil)
  }

  @discardableResult
  public func showClick(at point: CGPoint) -> TimeInterval {
    let overlayFrame = screen(containing: point)?.frame ?? NSScreen.main?.frame ?? .zero
    let panel = panel ?? makePanel(frame: overlayFrame)
    let canvasView = canvasView ?? ComputerUseCursorCanvasView(frame: NSRect(origin: .zero, size: overlayFrame.size))
    self.canvasView = canvasView
    self.panel = panel
    updatePanelFrame(panel, canvasView: canvasView, to: overlayFrame)

    let globalDestination = cursorOrigin(for: point)
    let destination = NSPoint(
      x: globalDestination.x - overlayFrame.minX,
      y: globalDestination.y - overlayFrame.minY
    )
    let wasVisible = panel.isVisible
    let movementDuration: TimeInterval
    if wasVisible {
      movementDuration = canvasView.moveCursor(to: destination, animated: true)
    } else {
      movementDuration = canvasView.moveCursor(to: destination, animated: false)
    }
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    canvasView.animateActivity()
    CATransaction.flush()
    return movementDuration
  }

  private func makePanel(frame: NSRect) -> NSPanel {
    let canvasView = ComputerUseCursorCanvasView(frame: NSRect(origin: .zero, size: frame.size))
    let panel = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .screenSaver
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    panel.contentView = canvasView
    self.canvasView = canvasView
    return panel
  }

  private func updatePanelFrame(
    _ panel: NSPanel,
    canvasView: ComputerUseCursorCanvasView,
    to frame: NSRect
  ) {
    guard panel.frame != frame else {
      return
    }

    let previousFrame = panel.frame
    let previousCursorOrigin = canvasView.cursorOrigin
    panel.setFrame(frame, display: false)
    canvasView.frame = NSRect(origin: .zero, size: frame.size)
    canvasView.moveCursor(
      to: NSPoint(
        x: previousFrame.minX + previousCursorOrigin.x - frame.minX,
        y: previousFrame.minY + previousCursorOrigin.y - frame.minY
      ),
      animated: false
    )
  }

  private func cursorOrigin(for point: CGPoint) -> NSPoint {
    guard let screen = screen(containing: point) else {
      return NSPoint(x: point.x - ComputerUseCursorCanvasView.tip.x, y: point.y - ComputerUseCursorCanvasView.tip.y)
    }

    let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
      .map { CGDirectDisplayID($0.uint32Value) }
    let bounds = displayID.map(CGDisplayBounds) ?? .zero
    // Accessibility and CoreGraphics already report positions in the desktop
    // coordinate space used by NSScreen.frame.  `backingScaleFactor` only
    // applies when converting view points to backing pixels; applying it here
    // halves the marker position on Retina displays.
    let localX = point.x - bounds.minX
    let localY = point.y - bounds.minY
    return NSPoint(
      x: screen.frame.minX + localX - ComputerUseCursorCanvasView.tip.x,
      y: screen.frame.maxY - localY - ComputerUseCursorCanvasView.tip.y
    )
  }

  private func screen(containing point: CGPoint) -> NSScreen? {
    var displayID = CGDirectDisplayID()
    var displayCount: UInt32 = 0
    guard CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount) == .success,
          displayCount == 1 else {
      return NSScreen.main
    }
    return NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    } ?? NSScreen.main
  }
}

private final class ComputerUseCursorCanvasView: NSView {
  /// The panel leaves enough transparent space for the SVG's blue glow.
  static let size = NSSize(width: 32, height: 32)
  private static let cursorRect = NSRect(x: 7, y: 7, width: 18, height: 18)
  /// The SVG tip is (3, 3) in its 24×24 top-left-origin viewBox.
  static let tip = NSPoint(
    x: cursorRect.minX + cursorRect.width * 3 / 24,
    y: cursorRect.maxY - cursorRect.height * 3 / 24
  )

  private static let cursorImage: NSImage? = {
    guard let url = Bundle.main.url(forResource: "computer-use-cursor", withExtension: "svg") else {
      return nil
    }
    return NSImage(contentsOf: url)
  }()

  private let cursorView = ComputerUseCursorView(
    frame: NSRect(origin: .zero, size: ComputerUseCursorCanvasView.size)
  )

  var cursorOrigin: NSPoint {
    guard let layer = cursorView.layer else {
      return cursorView.frame.origin
    }
    let position = layer.presentation()?.position ?? layer.position
    return NSPoint(x: position.x - Self.size.width / 2, y: position.y - Self.size.height / 2)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    addSubview(cursorView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @discardableResult
  func moveCursor(to origin: NSPoint, animated: Bool) -> TimeInterval {
    guard let cursorLayer = cursorView.layer else {
      cursorView.setFrameOrigin(origin)
      return 0
    }
    let start = cursorLayer.presentation()?.position ?? cursorLayer.position
    cursorLayer.removeAnimation(forKey: "computer-use-position")

    // Keep the AppKit view frame and its layer's model position in sync.
    // Updating only the layer lets AppKit restore the old (usually 0,0) frame
    // when the panel is ordered front, which makes the cursor appear at the
    // bottom-left corner after the animation starts.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cursorView.setFrameOrigin(origin)
    CATransaction.commit()
    // Use the model layer's actual post-AppKit position. Computing this from
    // the requested frame origin can differ by backing alignment, causing the
    // presentation layer to stop short and jump when the animation is removed.
    let destination = cursorLayer.position
    let distance = hypot(destination.x - start.x, destination.y - start.y)

    guard animated, distance >= 0.5 else {
      return 0
    }

    let duration = computerUseCursorAnimationDuration(for: distance)
    let position = CABasicAnimation(keyPath: "position")
    position.fromValue = start
    position.toValue = destination
    position.duration = duration
    position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    cursorLayer.add(position, forKey: "computer-use-position")
    return duration
  }

  func animateActivity() {
    guard let cursorLayer = cursorView.layer else {
      return
    }
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0.25
    opacity.toValue = 1
    opacity.duration = 0.22
    opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    cursorLayer.add(opacity, forKey: "computer-use-opacity")
  }

  private final class ComputerUseCursorView: NSView {
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard let image = ComputerUseCursorCanvasView.cursorImage,
            let context = NSGraphicsContext.current?.cgContext else {
        return
      }

      context.saveGState()
      context.setShadow(
        offset: .zero,
        blur: 6,
        color: NSColor.systemBlue.withAlphaComponent(0.8).cgColor
      )
      image.draw(in: ComputerUseCursorCanvasView.cursorRect, from: .zero, operation: .sourceOver, fraction: 1)
      context.restoreGState()

      image.draw(in: ComputerUseCursorCanvasView.cursorRect, from: .zero, operation: .sourceOver, fraction: 1)
    }
  }
}
