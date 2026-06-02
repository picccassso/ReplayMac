import UI

@MainActor
extension AppDelegate {
    func checkForAvailableUpdate() {
        guard let currentVersion = UpdateChecker.currentAppVersion else {
            print("Skipping update check: app version is unavailable.")
            return
        }

        Task {
            do {
                let update = try await UpdateChecker.checkForUpdate(currentVersion: currentVersion)
                menuBarState.setAvailableUpdate(update)
                statusItemController.refreshPresentation()
            } catch {
                print("Update check failed: \(error.localizedDescription)")
            }
        }
    }
}

