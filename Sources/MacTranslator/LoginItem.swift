import MacTranslatorCore
import ServiceManagement

/// "Launch at login" via the modern SMAppService API (macOS 13+).
/// The system is the source of truth — read `isEnabled` / `status` fresh.
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        LoginItemRegistrationPolicy.isRegistered(status)
    }

    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    /// Registers/unregisters the app itself as a login item. Throws on failure
    /// (e.g. the user disabled it in System Settings → it needs re-approval).
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if !LoginItemRegistrationPolicy.isRegistered(service.status) {
                try service.register()
            }
        } else {
            if LoginItemRegistrationPolicy.isRegistered(service.status) {
                try service.unregister()
            }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
