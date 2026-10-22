import AppKit

// Runtime Daemon entry point (LaunchAgent com.avodroid.daemon.agent). It runs as an
// accessory app so it can own the menu bar item and post notifications.
let application = NSApplication.shared
let delegate = DaemonAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
