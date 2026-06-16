import Observation

@MainActor
@Observable
final class AppCommands {
    static let shared = AppCommands()
    private init() {}

    var runOrRefresh = 0
    var focusSearch = 0
    var focusWhere = 0
    var openDbPicker = 0

    func runOrRefreshPulse() { runOrRefresh &+= 1 }
    func focusSearchPulse()  { focusSearch &+= 1 }
    func focusWherePulse()   { focusWhere &+= 1 }
    func openDbPickerPulse() { openDbPicker &+= 1 }
}
