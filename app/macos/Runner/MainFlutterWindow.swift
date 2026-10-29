import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Home shows the three panes from 980 pt. 1280 pt is the wider list.
    // Applied on every launch, and never smaller, so the phone layout stays off the Mac.
    let visible = (self.screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    var width: CGFloat = 1280
    var height: CGFloat = 800
    let fitted = frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
    if fitted.width > visible.width { width -= fitted.width - visible.width }
    if fitted.height > visible.height { height -= fitted.height - visible.height }
    width = max(width, min(980, visible.width))
    height = max(height, min(640, visible.height))
    contentMinSize = NSSize(width: min(980, width), height: min(640, height))
    // The last size and position are kept in the app's defaults, so they
    // survive restarts and updates. The first start gets the size above.
    if !setFrameUsingName("MainWindow") {
      setContentSize(NSSize(width: width, height: height))
      center()
    }
    setFrameAutosaveName("MainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
