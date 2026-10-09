import AppKit
import CompanionServer
import Defaults
import XCTest
@testable import UI

final class CompanionUITests: XCTestCase {
    @MainActor
    func testSelectingCompanionPageSetsSettingsTab() {
        let name = "CompanionUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let state = MainWindowState(defaults: defaults)
        XCTAssertEqual(state.page, .home)
        XCTAssertFalse(state.hasVisitedSettings)

        state.select(.companion)
        XCTAssertEqual(state.page, .companion)
        XCTAssertEqual(state.settingsTab, .companion)
        XCTAssertTrue(state.hasVisitedSettings)
        XCTAssertTrue(state.isSettingsPage)
    }

    @MainActor
    func testCompanionServerConnectionStateTracking() {
        let name = "CompanionUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let pairing = CompanionPairingManager(defaults: defaults)
        let server = CompanionServer(pairingManager: pairing, defaults: defaults)

        XCTAssertEqual(server.connectedClientsCount, 0)
        XCTAssertTrue(server.connectedDeviceIds.isEmpty)
        XCTAssertFalse(server.isDeviceConnected(id: "dev-1"))
    }

    @MainActor
    func testCompanionPairingDeviceResolution() {
        let name = "CompanionUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let pairing = CompanionPairingManager(defaults: defaults)
        pairing.approveDevice(id: "phone-1", name: "Alex's iPhone")

        let device = pairing.device(for: "phone-1")
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.name, "Alex's iPhone")
    }
}
