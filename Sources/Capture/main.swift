import AppKit

let args = CommandLine.arguments
if NativeHost.isLaunchedByChrome(args) { exit(NativeHost.run()) }            // Chrome started the helper: no app, no window

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)                                       // menu bar only, no Dock icon
    let delegate: NSApplicationDelegate
    if let i = args.firstIndex(of: "--selftest") { delegate = SelfTestRunner(only: i + 1 < args.count ? args[i + 1] : nil) }
    else { delegate = AppDelegate() }
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
