import Foundation

public enum RouterDefaults {
    public static var routerPassword: String {
        ProcessInfo.processInfo.environment["GLINET_ROUTER_PASSWORD"] ?? ""
    }
}
