import AppKit
import Foundation

// Each invocation runs exactly one suite in its own process and defaults domain.
@main enum AppRegressionMain {
    @MainActor static func finish(_ status: Int32) -> Never {
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: domain)
        exit(status)
    }

    @MainActor static func main() {
        switch ProcessInfo.processInfo.environment["HERMES_REGRESSION_SUITE"] {
        case "model":
            Task { @MainActor in
                do {
                    try await ModelSafetyRegression.main()
                    finish(0)
                } catch {
                    FileHandle.standardError.write(Data("Model regression failed: \(error)\n".utf8))
                    finish(1)
                }
            }
            NSApplication.shared.run()
        case "uiux":
            UIUXRegression.main()
        case "native":
            NativeMediaRegression.main()
        default:
            FileHandle.standardError.write(Data("Unknown HERMES regression suite\n".utf8))
            finish(2)
        }
    }
}
