import Foundation
import ServiceManagement

/// System-backed launch-at-login state. SMAppService is the source of truth;
/// no duplicate UserDefaults flag is kept because users can revoke approval
/// directly in System Settings.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var statusText = "正在读取系统状态…"

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
            statusText = "已启用，将在登录 Mac 后自动启动"
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
            statusText = "等待你在“系统设置 → 登录项”中批准"
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
            statusText = "未启用"
        case .notFound:
            isEnabled = false
            requiresApproval = false
            statusText = "尚未建立登录项；打开开关时会由系统自动创建"
        @unknown default:
            isEnabled = false
            requiresApproval = false
            statusText = "无法读取开机自启状态"
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else {
                    if service.status == .notFound {
                        // On a freshly installed command-line packaged app,
                        // the first registration can initialise the Background
                        // Task Management record and leave it notRegistered.
                        // A second registration completes the requested state.
                        try service.register()
                    }
                    if service.status == .notRegistered {
                        try service.register()
                    }
                }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            statusText = "设置失败：\(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
