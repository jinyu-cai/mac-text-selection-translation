import ServiceManagement

/// "Launch at login" via the modern SMAppService API (macOS 13+).
/// The system is the source of truth — read `isEnabled` / `status` fresh.
enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Registers/unregisters the app itself as a login item. Throws on failure
    /// (e.g. the user disabled it in System Settings → it needs re-approval).
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
