import Foundation
import ServiceManagement

struct LoginItemService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool, refresh: Bool = false) throws {
        if enabled {
            if refresh, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
