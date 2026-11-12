import AppKit

guard let instanceLock = InstanceLock.acquire() else {
    DistributedNotificationCenter.default().postNotificationName(
        .typemoreOpenSettings, object: Bundle.main.bundleIdentifier, userInfo: nil, deliverImmediately: true
    )
    print("[Typemore] Opened settings in the running instance.")
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated {
    let delegate = TypemoreApp()
    app.delegate = delegate
    return delegate
}
// NSApplication.delegate 不持有强引用；显式覆盖整个 run loop 生命周期，
// 避免 release 优化在启动回调后释放 delegate 与单实例锁。
withExtendedLifetime((delegate, instanceLock)) {
    app.run()
}
