import AppKit
import Combine
import GLiNetCore
import SwiftUI

@main
struct GLiNetMenuBarApp: App {
    @StateObject private var appModel = MenuBarAppModel()

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appModel.viewModel)
                .frame(width: 430)
        }
    }
}

@MainActor
private final class MenuBarAppModel: ObservableObject {
    let viewModel: StatusViewModel
    private let statusBarController: StatusBarController

    init() {
        let viewModel = StatusViewModel()
        self.viewModel = viewModel
        self.statusBarController = StatusBarController(viewModel: viewModel)
        viewModel.start()
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuBarIconDescriptor: Equatable {
    var base: Base
    var tone: Tone
    var badges: [Badge]

    var identity: String {
        let badgeText = badges.map { "\($0.kind.rawValue):\($0.isPrimary)" }.joined(separator: ",")
        return "\(base.identity)-\(tone)-\(badgeText)"
    }

    var accessibilityLabel: String {
        switch base {
        case .gliRouting:
            return "GL.iNet routing"
        case .speedify:
            return "Speedify protected"
        case .tailscale:
            return "Tailscale protected"
        case .wireGuard:
            return "WireGuard protected"
        case .openVPN:
            return "OpenVPN protected"
        case .tor:
            return "Tor protected"
        case .system:
            return tone == .bad ? "Network problem" : "Network status"
        }
    }

    init(snapshot: StatusSnapshot) {
        let internetUp: Bool
        if case .online = snapshot.reachability.value?.state {
            internetUp = true
        } else {
            internetUp = false
        }

        let speedify = snapshot.speedify.value
        let routerVPN = snapshot.vpn.value
        let interfaces = InternetInterfaceStatus.overview(
            router: snapshot.router.value,
            speedify: speedify?.isConnected == true ? speedify : nil
        )
        let activeInterfaces = interfaces.filter(\.isConnected)

        if snapshot.router.value == nil, snapshot.router.errorMessage != nil {
            self.base = .system("shield.slash")
            self.tone = .bad
            self.badges = []
            return
        }
        if !internetUp {
            self.base = .system("wifi.slash")
            self.tone = .bad
            self.badges = Self.badges(from: activeInterfaces)
            return
        }

        if speedify?.isConnected == true {
            self.base = .speedify
            self.tone = .protected
            self.badges = Self.badges(from: activeInterfaces)
            return
        }

        if routerVPN?.isConnected == true {
            self.base = Self.protectedBase(for: routerVPN?.vpnProtocol)
            self.tone = .protected
            self.badges = Self.badges(from: activeInterfaces)
            return
        }

        self.base = .gliRouting
        self.tone = .routing
        self.badges = []
    }

    enum Base: Equatable {
        case gliRouting
        case speedify
        case tailscale
        case wireGuard
        case openVPN
        case tor
        case system(String)

        var identity: String {
            switch self {
            case .gliRouting: return "gli"
            case .speedify: return "speedify"
            case .tailscale: return "tailscale"
            case .wireGuard: return "wireguard"
            case .openVPN: return "openvpn"
            case .tor: return "tor"
            case .system(let value): return "system-\(value)"
            }
        }

        var resource: (name: String, extension: String)? {
            switch self {
            case .gliRouting:
                return ("glinet", "png")
            case .speedify:
                return ("speedify", "png")
            case .tailscale:
                return ("tailscale", "png")
            case .wireGuard:
                return ("wireguard", "svg")
            case .openVPN:
                return ("openvpn", "svg")
            case .tor:
                return ("torproject", "svg")
            case .system:
                return nil
            }
        }
    }

    enum Tone: Equatable {
        case routing
        case protected
        case bad
    }

    struct Badge: Equatable, Identifiable {
        var kind: InternetInterfaceKind
        var isPrimary: Bool

        var id: String {
            "\(kind.rawValue)-\(isPrimary)"
        }
    }

    private static func protectedBase(for vpnProtocol: VPNProtocol?) -> Base {
        switch vpnProtocol {
        case .tailscale:
            return .tailscale
        case .wireGuard, .wireGuardServer:
            return .wireGuard
        case .openVPN, .openVPNServer:
            return .openVPN
        case .tor:
            return .tor
        default:
            return .system("checkmark.shield.fill")
        }
    }

    private static func routingBase(from interfaces: [InternetInterfaceStatus]) -> Base {
        let primary = interfaces.first(where: \.isPrimary) ?? interfaces.first
        guard interfaces.filter(\.isConnected).count <= 1 else {
            return .system("network")
        }
        switch primary?.kind {
        case .cellular:
            return .system("cellularbars")
        case .starlink:
            return .system("antenna.radiowaves.left.and.right")
        case .repeater:
            return .system("wifi")
        case .tethering:
            return .system("personalhotspot")
        case .ethernet:
            return .system("cable.connector")
        case .unknown, .none:
            return .gliRouting
        }
    }

    private static func badges(from interfaces: [InternetInterfaceStatus]) -> [Badge] {
        Array(
            interfaces
                .filter(\.isConnected)
                .sorted { lhs, rhs in
                    if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                    return rank(lhs.kind) < rank(rhs.kind)
                }
                .prefix(2)
                .map { Badge(kind: $0.kind, isPrimary: $0.isPrimary) }
        )
    }

    private static func rank(_ kind: InternetInterfaceKind) -> Int {
        switch kind {
        case .cellular: return 0
        case .starlink: return 1
        case .tethering: return 2
        case .ethernet: return 3
        case .repeater: return 4
        case .unknown: return 5
        }
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private let popover = NSPopover()
    private let viewModel: StatusViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: StatusViewModel) {
        self.viewModel = viewModel
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 460, height: 720)
        popover.contentViewController = NSHostingController(
            rootView: MenuContent()
                .environmentObject(viewModel)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        updateIcon(snapshot: viewModel.snapshot)
        viewModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateIcon(snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon(snapshot: StatusSnapshot) {
        let descriptor = MenuBarIconDescriptor(snapshot: snapshot)
        statusItem.button?.image = StatusIconRenderer.image(for: descriptor)
        statusItem.button?.toolTip = descriptor.accessibilityLabel
    }
}

private enum StatusIconRenderer {
    static func image(for descriptor: MenuBarIconDescriptor) -> NSImage {
        if let resource = descriptor.base.resource {
            return resourceImage(named: resource.name, extension: resource.extension) ?? fallbackImage(for: descriptor)
        }
        return fallbackImage(for: descriptor)
    }

    private static func resourceImage(named name: String, extension fileExtension: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "StatusIcons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        return resized(image, size: NSSize(width: 20, height: 20), template: false)
    }

    private static func fallbackImage(for descriptor: MenuBarIconDescriptor) -> NSImage {
        let symbolName: String
        switch descriptor.base {
        case .system(let name):
            symbolName = name
        case .wireGuard:
            symbolName = "shield.lefthalf.filled"
        case .openVPN:
            symbolName = "shield.fill"
        case .tor:
            symbolName = "circle.dotted"
        default:
            symbolName = "network"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: descriptor.accessibilityLabel)
            ?? NSImage(size: NSSize(width: 20, height: 20))
        image.isTemplate = descriptor.tone != .bad
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    private static func resized(_ image: NSImage, size: NSSize, template: Bool) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: fittedRect(for: image.size, in: NSRect(origin: .zero, size: size)))
        output.unlockFocus()
        output.isTemplate = template
        return output
    }

    private static func fittedRect(for imageSize: NSSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return NSRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

private struct MenuBarStatusIcon: View {
    let descriptor: MenuBarIconDescriptor

    var body: some View {
        ZStack {
            baseIcon
                .frame(width: baseSize, height: baseSize)

            ForEach(Array(descriptor.badges.enumerated()), id: \.element.id) { index, badge in
                badgeView(badge)
                    .frame(width: 6.5, height: 6.5)
                    .offset(x: index == 0 ? -10 : 10, y: 6.5)
            }
        }
        .frame(width: 32, height: 22)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var baseIcon: some View {
        switch descriptor.base {
        case .gliRouting:
            GLiRoutingGlyph(color: color)
        case .speedify:
            SpeedifyGlyph(color: color)
        case .tailscale:
            TailscaleGlyph(color: color)
        case .wireGuard:
            ProtectedTextGlyph(text: "WG", color: color)
        case .openVPN:
            ProtectedTextGlyph(text: "OV", color: color)
        case .tor:
            TorGlyph(color: color)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch descriptor.tone {
        case .routing:
            return .primary
        case .protected:
            return .primary
        case .bad:
            return .red
        }
    }

    private var baseSize: CGFloat {
        switch descriptor.base {
        case .speedify, .tailscale, .wireGuard, .openVPN, .tor:
            return 22
        default:
            return 18
        }
    }

    private var accessibilityLabel: String {
        switch descriptor.base {
        case .gliRouting:
            return "GL.iNet routing"
        case .speedify:
            return "Speedify protected"
        case .tailscale:
            return "Tailscale protected"
        case .wireGuard:
            return "WireGuard protected"
        case .openVPN:
            return "OpenVPN protected"
        case .tor:
            return "Tor protected"
        case .system:
            return descriptor.tone == .bad ? "Network problem" : "Network status"
        }
    }

    private func badgeView(_ badge: MenuBarIconDescriptor.Badge) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
            Circle()
                .fill(badgeColor(badge.kind).opacity(badge.isPrimary ? 1 : 0.72))
                .padding(0.8)
            Image(systemName: badgeSymbol(badge.kind))
                .font(.system(size: 3.9, weight: .black))
                .foregroundStyle(.white)
        }
    }

    private func badgeSymbol(_ kind: InternetInterfaceKind) -> String {
        switch kind {
        case .cellular:
            return "cellularbars"
        case .starlink:
            return "antenna.radiowaves.left.and.right"
        case .tethering:
            return "personalhotspot"
        case .ethernet:
            return "cable.connector"
        case .repeater:
            return "wifi"
        case .unknown:
            return "network"
        }
    }

    private func badgeColor(_ kind: InternetInterfaceKind) -> Color {
        switch kind {
        case .cellular:
            return .pink
        case .starlink:
            return .cyan
        case .tethering:
            return .purple
        case .ethernet:
            return .blue
        case .repeater:
            return .mint
        case .unknown:
            return .gray
        }
    }
}

private struct GLiRoutingGlyph: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.7)
            Text("gl")
                .font(.system(size: 8, weight: .black, design: .rounded))
                .textCase(.lowercase)
                .foregroundStyle(color)
                .offset(y: -0.2)
        }
    }
}

private struct SpeedifyGlyph: View {
    let color: Color

    var body: some View {
        ZStack {
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(color)
            HStack {
                ArcGlyph(side: .left, color: color)
                Spacer(minLength: 11)
                ArcGlyph(side: .right, color: color)
            }
            .frame(width: 26, height: 18)
        }
    }
}

private struct ArcGlyph: View {
    enum Side {
        case left
        case right
    }

    let side: Side
    let color: Color

    var body: some View {
        Path { path in
            switch side {
            case .left:
                path.addArc(
                    center: CGPoint(x: 11, y: 9),
                    radius: 8,
                    startAngle: .degrees(124),
                    endAngle: .degrees(236),
                    clockwise: false
                )
            case .right:
                path.addArc(
                    center: CGPoint(x: -1, y: 9),
                    radius: 8,
                    startAngle: .degrees(-56),
                    endAngle: .degrees(56),
                    clockwise: false
                )
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .frame(width: 8, height: 18)
    }
}

private struct TailscaleGlyph: View {
    let color: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(4)), GridItem(.fixed(4))], spacing: 2) {
            ForEach(0..<4, id: \.self) { _ in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
            }
        }
    }
}

private struct ProtectedTextGlyph: View {
    let text: String
    let color: Color

    var body: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 6, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: -0.2)
        }
    }
}

private struct TorGlyph: View {
    let color: Color

    var body: some View {
        ZStack {
            ForEach([15.0, 10.5, 6.0], id: \.self) { size in
                Circle()
                    .stroke(color, lineWidth: 1.3)
                    .frame(width: size, height: size)
            }
            Circle()
                .fill(color)
                .frame(width: 3.2, height: 3.2)
        }
    }
}
