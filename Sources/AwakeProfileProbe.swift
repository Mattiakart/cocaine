// The Mac's readings for keep-awake profiles (Sources/AwakeProfiles.swift): only what the enabled profiles use is read.
//  - Wi-Fi network name: CoreWLAN. Since macOS 14 the name is given only to apps allowed in Location Services (Cocaine asks
//    only when a profile uses a Wi-Fi network, from the profile's own row); without it the condition is never met.
//  - Ethernet: interfaces macOS lists as Ethernet (SystemConfiguration) that are up with a routable IPv4 address (an iPhone over
//    USB counts as Ethernet). Personal Hotspot and internet: the Network framework's path (isExpensive, satisfied).
//  - IP addresses: getifaddrs. DNS servers: the system's dynamic store (State:/Network/Global/DNS).
//  - Bluetooth: `system_profiler -json SPBluetoothDataType` (its "connected" list), at most every 20 s, off the main thread: no
//    Bluetooth permission is needed this way (IOBluetooth would need one).
//  - Screen mirroring: CoreGraphics' mirror sets. The app in front: NSWorkspace (Cocaine itself is skipped).
// None of these needs a permission except the Wi-Fi name (Location Services).

import AppKit
import CoreLocation
import CoreWLAN
import Network
import SystemConfiguration

protocol ProfileProbe: AnyObject {
    /// A snapshot with what `needs` asks for (the rest left at its default).
    func snapshot(needs: Set<AwakeCondition.Kind>, base: AwakeProbe, now: Date) -> AwakeSnapshot
}

final class SystemProfileProbe: ProfileProbe {
    private var path: PathWatch?
    private var lastFront: (name: String?, bundle: String?) = (nil, nil)

    func snapshot(needs n: Set<AwakeCondition.Kind>, base: AwakeProbe, now: Date) -> AwakeSnapshot {
        var s = AwakeSnapshot()
        s.now = now
        let netKinds: Set<AwakeCondition.Kind> = [.wifiConnected, .ethernet, .ipAddress, .vpn]
        var addrs: [String: [String]] = [:]
        if !n.isDisjoint(with: netKinds) || n.contains(.wifi) { addrs = NetReadings.addresses() }
        if n.contains(.wifi) || n.contains(.wifiConnected) {
            let w = NetReadings.wifi()
            s.ssid = w.ssid
            s.wifiConnected = w.name.map { NetReadings.routableV4(addrs[$0] ?? []) } ?? false
        }
        if n.contains(.ethernet) {
            let wifiName = NetReadings.wifi().name
            s.ethernet = NetReadings.ethernetNames().contains { $0 != wifiName && NetReadings.routableV4(addrs[$0] ?? []) }
        }
        if n.contains(.ipAddress) { s.addresses = addrs.filter { $0.key != "lo0" }.flatMap(\.value) }
        if n.contains(.dns) { s.dns = NetReadings.dnsServers() }
        if n.contains(.vpn) { s.vpn = VPNRule.connected(base.interfaces()) }
        if n.contains(.hotspot) || n.contains(.internet) {
            if path == nil { path = PathWatch() }
            let p = path!.current
            s.expensive = p.expensive; s.internet = p.satisfied
        } else if path != nil {
            path = nil                                    // nobody asks any more: stop watching
        }
        if n.contains(.usb) { s.usb = base.usbDevices() }
        if n.contains(.bluetooth) { s.bluetooth = BluetoothScan.shared.connected(now: now) }
        if n.contains(.audio) { s.output = base.defaultOutput() }
        if n.contains(.volume) { s.volumes = base.mountedVolumes() }
        if n.contains(.cpu) { s.cpuTicks = base.cpuTicks() }
        if n.contains(.frontApp) {
            if let a = NSWorkspace.shared.frontmostApplication, a.processIdentifier != getpid() {
                lastFront = (a.localizedName, a.bundleIdentifier)
            }
            s.front = lastFront.name; s.frontBundle = lastFront.bundle
        }
        if n.contains(.appRunning) { s.running = System.runningNames() }
        if n.contains(.power) || n.contains(.battery) {
            let b = System.battery
            s.onAC = b?.onAC ?? PowerState.onAC
            s.battery = b?.percent
        }
        if n.contains(.display) { s.externalDisplays = PowerState.externalDisplays }
        if n.contains(.mirroring) { s.mirroring = NetReadings.mirroring() }
        return s
    }
}

enum NetReadings {
    /// Interface → its addresses (IPv4 dotted, IPv6 without the zone), up interfaces only, link-local IPv6 left out.
    static func addresses() -> [String: [String]] {
        var out: [String: [String]] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            let flags = Int32(a.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, let sa = a.pointee.ifa_addr else { continue }
            let fam = Int32(sa.pointee.sa_family)
            guard fam == AF_INET || fam == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(fam == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var s = String(cString: host)
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
            if fam == AF_INET6 && s.lowercased().hasPrefix("fe80") { continue }
            out[String(cString: a.pointee.ifa_name), default: []].append(s)
        }
        return out
    }

    /// An IPv4 address that isn't self-assigned (169.254.x.x) or loopback.
    static func routableV4(_ list: [String]) -> Bool {
        list.contains { a in IPMatch.v4(a) != nil && !a.hasPrefix("169.254.") && !a.hasPrefix("127.") }
    }

    /// The Wi-Fi interface's BSD name and the network's name (nil without Location Services, or not connected).
    static func wifi() -> (name: String?, ssid: String?) {
        let i = CWWiFiClient.shared().interface()
        return (i?.interfaceName, i?.ssid())
    }

    /// BSD names of the interfaces macOS lists as Ethernet (USB/Thunderbolt adapters, an iPhone over USB, built-in ports).
    static func ethernetNames() -> [String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return all.compactMap { i in
            guard let t = SCNetworkInterfaceGetInterfaceType(i), CFEqual(t, kSCNetworkInterfaceTypeEthernet) else { return nil }
            return SCNetworkInterfaceGetBSDName(i) as String?
        }
    }

    static func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Cocaine" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] else { return [] }
        return Array(((v["ServerAddresses"] as? [String]) ?? []).prefix(20))
    }

    static func mirroring() -> Bool {
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }
}

/// The Network framework's view of the current path, kept fresh by a monitor while a profile needs it.
final class PathWatch {
    struct Path { var satisfied = false; var expensive = false }
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var latest = Path()

    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            self.lock.lock(); self.latest = Path(satisfied: p.status == .satisfied, expensive: p.isExpensive); self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "cocaine.path"))
        let p = monitor.currentPath
        latest = Path(satisfied: p.status == .satisfied, expensive: p.isExpensive)
    }

    deinit { monitor.cancel() }

    var current: Path { lock.lock(); defer { lock.unlock() }; return latest }
}

/// Connected Bluetooth devices, from system_profiler (no Bluetooth permission needed), refreshed in the background.
final class BluetoothScan {
    static let shared = BluetoothScan()
    static let every: TimeInterval = 20
    private var names: [String]?
    private var readAt = Date.distantPast
    private var busy = false

    /// The last list (nil until the first reading); starts a new reading when it is older than 20 s.
    func connected(now: Date) -> [String]? {
        if !busy && now.timeIntervalSince(readAt) >= Self.every {
            busy = true
            DispatchQueue.global(qos: .utility).async {
                let r = Proc.run("/usr/sbin/system_profiler", ["-json", "-detailLevel", "mini", "SPBluetoothDataType"], timeout: 15, capture: true, limit: 2 << 20)
                let list = r.status == 0 ? Self.parse(r.output) : nil
                DispatchQueue.main.async {
                    self.busy = false
                    self.readAt = Date()
                    if let list { self.names = list }
                }
            }
        }
        return names
    }

    /// The names under "device_connected" (every controller).
    static func parse(_ data: Data) -> [String]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ctrls = o["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var out: [String] = []
        for c in ctrls {
            for entry in (c["device_connected"] as? [[String: Any]]) ?? [] { out.append(contentsOf: entry.keys) }
        }
        return Array(Set(out)).sorted().prefix(100).map { $0 }
    }

    /// Every device the Mac knows (connected or not), for the picker; read now, off the main thread.
    static func known(_ done: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Proc.run("/usr/sbin/system_profiler", ["-json", "-detailLevel", "mini", "SPBluetoothDataType"], timeout: 15, capture: true, limit: 2 << 20)
            var out: [String] = []
            if r.status == 0, let o = (try? JSONSerialization.jsonObject(with: r.output)) as? [String: Any],
               let ctrls = o["SPBluetoothDataType"] as? [[String: Any]] {
                for c in ctrls {
                    for k in ["device_connected", "device_not_connected"] {
                        for entry in (c[k] as? [[String: Any]]) ?? [] { out.append(contentsOf: entry.keys) }
                    }
                }
            }
            DispatchQueue.main.async { done(Array(Set(out)).sorted()) }
        }
    }
}

/// Location Services, only to read the Wi-Fi network's name (macOS gives it to no app without it).
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()
    private lazy var manager: CLLocationManager = { let m = CLLocationManager(); m.delegate = self; return m }()
    var changed: () -> Void = {}

    var allowed: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }
    var denied: Bool { [.denied, .restricted].contains(manager.authorizationStatus) }

    /// macOS asks once; after a refusal only System Settings can change it.
    func request() {
        if denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { changed() }
}
