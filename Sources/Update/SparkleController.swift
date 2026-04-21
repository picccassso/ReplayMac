import Foundation
import Sparkle
import os.log

@MainActor
public final class SparkleController {
    private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
        var appcastURLString: String?

        func feedURLString(for updater: SPUUpdater) -> String? {
            appcastURLString
        }
    }

    private let logger = Logger(subsystem: "com.replaymac", category: "Update")
    private let updaterDelegate = UpdaterDelegate()
    private var updaterController: SPUStandardUpdaterController?
    private var didStart = false

    public init() {}

    public func start(appcastURLString: String?, checkInterval: TimeInterval = 24 * 60 * 60) {
        updaterDelegate.appcastURLString = appcastURLString

        guard let appcastURLString, !appcastURLString.isEmpty else {
            logger.info("Sparkle disabled: no appcast URL configured")
            return
        }

        guard !didStart else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = checkInterval

        updaterController = controller
        didStart = true
        logger.info("Sparkle started for direct distribution updates")
    }

    public func checkForUpdates() {
        guard let updaterController else {
            logger.info("Check for updates skipped: Sparkle not configured")
            return
        }
        updaterController.checkForUpdates(nil)
    }
}
