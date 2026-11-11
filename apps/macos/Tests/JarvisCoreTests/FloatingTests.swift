import XCTest
@testable import JarvisCore

final class FloatingTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: Defaults and persistence
    func testDefaults() {
        let s = FloatingSettings()
        XCTAssertEqual(s.displayMode, .petWithChat)
        XCTAssertFalse(s.shareScreen)
        XCTAssertEqual(s.hotKey, HotKeyCombo.default)
        XCTAssertEqual(HotKeyCombo.default.display, "⌃⌥J")
        XCTAssertTrue(HotKeyCombo.default.isValid)
    }

    func testSettingsSurviveRestart() {
        let suite = UserDefaults(suiteName: "floating-test-\(UUID().uuidString)")!
        let store = FloatingSettingsStore(defaults: suite)
        var s = FloatingSettings()
        s.displayMode = .petOnly; s.petStyle = .buddy; s.petColor = .pink; s.petSize = 96
        s.hotKey = HotKeyCombo(keyCode: 49, modifiers: [.command, .shift]); s.chatWidth = 450; s.chatWasOpen = true; s.shareScreen = true
        store.save(s)
        XCTAssertEqual(FloatingSettingsStore(defaults: suite).load(), s)
    }

    func testMissingOrCorruptDataGivesDefaults() {
        let suite = UserDefaults(suiteName: "floating-test-\(UUID().uuidString)")!
        XCTAssertEqual(FloatingSettingsStore(defaults: suite).load(), FloatingSettings())
        suite.set(Data("not json".utf8), forKey: FloatingSettingsStore.key)
        XCTAssertEqual(FloatingSettingsStore(defaults: suite).load(), FloatingSettings())
    }

    func testUnknownModeAndMissingFieldsKeepTheRest() throws {
        let json = #"{"displayMode":"somethingNew","petColor":"green","petSize":90}"#
        let s = try JSONDecoder().decode(FloatingSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.displayMode, .petWithChat)
        XCTAssertEqual(s.petColor, .green)
        XCTAssertEqual(s.petSize, 90)
        XCTAssertEqual(s.hotKey, .default)
    }

    func testSanitizeClampsBadValues() throws {
        let json = #"{"petSize":9999,"petIdleOpacity":-4,"chatWidth":1,"chatHeight":99999,"petAnchor":{"fx":5,"fy":-2},"hotKey":{"keyCode":38,"modifiers":0},"chatOrigin":[1]}"#
        let s = try JSONDecoder().decode(FloatingSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.petSize, FloatingSettings.petSizeRange.upperBound)
        XCTAssertEqual(s.petIdleOpacity, FloatingSettings.idleOpacityRange.lowerBound)
        XCTAssertEqual(s.chatWidth, FloatingSettings.chatMinSize.width)
        XCTAssertEqual(s.chatHeight, 1600)
        XCTAssertEqual(s.petAnchor.fx, 1); XCTAssertEqual(s.petAnchor.fy, 0)
        XCTAssertEqual(s.hotKey, .default)           // no modifiers: not a usable shortcut
        XCTAssertNil(s.chatOrigin)
    }

    // MARK: Shortcut
    func testShortcutValidity() {
        XCTAssertFalse(HotKeyCombo(keyCode: 38, modifiers: []).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 38, modifiers: [.shift]).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 38, modifiers: [.option]).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 38, modifiers: [.option, .shift]).isValid)
        XCTAssertTrue(HotKeyCombo(keyCode: 38, modifiers: [.control]).isValid)
        XCTAssertTrue(HotKeyCombo(keyCode: 49, modifiers: [.command, .shift]).isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 200, modifiers: [.control]).isValid)       // a key we cannot name
    }
    func testShortcutDisplay() {
        XCTAssertEqual(HotKeyCombo(keyCode: 49, modifiers: [.command, .shift, .option, .control]).display, "⌃⌥⇧⌘Space")
        XCTAssertEqual(HotKeyCombo.default.spoken, "Control + Option + J")
    }

    // MARK: What shows when
    func testPetVisibility() {
        XCTAssertTrue(FloatingPolicy.petVisible(mode: .petWithChat, petHidden: false))
        XCTAssertTrue(FloatingPolicy.petVisible(mode: .petOnly, petHidden: false))
        XCTAssertFalse(FloatingPolicy.petVisible(mode: .chatOnly, petHidden: false))
        XCTAssertFalse(FloatingPolicy.petVisible(mode: .petWithChat, petHidden: true))
    }
    func testLaunchState() {
        XCTAssertFalse(FloatingPolicy.chatOpenAtLaunch(mode: .petOnly, wasOpen: true, hasSavedState: true))
        XCTAssertTrue(FloatingPolicy.chatOpenAtLaunch(mode: .petWithChat, wasOpen: true, hasSavedState: true))
        XCTAssertFalse(FloatingPolicy.chatOpenAtLaunch(mode: .petWithChat, wasOpen: false, hasSavedState: false))
        XCTAssertTrue(FloatingPolicy.chatOpenAtLaunch(mode: .chatOnly, wasOpen: false, hasSavedState: false))
        XCTAssertFalse(FloatingPolicy.chatOpenAtLaunch(mode: .chatOnly, wasOpen: false, hasSavedState: true))
    }
    func testModeChange() {
        XCTAssertTrue(FloatingPolicy.chatOpenAfterModeChange(to: .chatOnly, currentlyOpen: false))
        XCTAssertFalse(FloatingPolicy.chatOpenAfterModeChange(to: .petOnly, currentlyOpen: true))
        XCTAssertTrue(FloatingPolicy.chatOpenAfterModeChange(to: .petWithChat, currentlyOpen: true))
        XCTAssertFalse(FloatingPolicy.chatOpenAfterModeChange(to: .petWithChat, currentlyOpen: false))
    }
    func testOnlyPetOnlyDismissesOnFocusLoss() {
        XCTAssertTrue(FloatingPolicy.dismissOnFocusLoss(mode: .petOnly, pinned: false))
        XCTAssertFalse(FloatingPolicy.dismissOnFocusLoss(mode: .petOnly, pinned: true))
        XCTAssertFalse(FloatingPolicy.dismissOnFocusLoss(mode: .petWithChat, pinned: false))
        XCTAssertFalse(FloatingPolicy.dismissOnFocusLoss(mode: .chatOnly, pinned: false))
    }
    func testChatAttachment() {
        XCTAssertTrue(FloatingPolicy.chatAttachesToPet(mode: .petWithChat, petHidden: false))
        XCTAssertFalse(FloatingPolicy.chatAttachesToPet(mode: .petWithChat, petHidden: true))
        XCTAssertFalse(FloatingPolicy.chatAttachesToPet(mode: .chatOnly, petHidden: false))
    }

    // MARK: Geometry
    func testClamp() {
        let f = FloatingLayout.clamp(CGRect(x: 1400, y: -50, width: 100, height: 100), to: screen)
        XCTAssertEqual(f, CGRect(x: 1340, y: 0, width: 100, height: 100))
        XCTAssertEqual(FloatingLayout.clamp(CGRect(x: 0, y: 0, width: 5000, height: 5000), to: screen).size, screen.size)
    }
    func testPetFrameStaysOnScreenInEveryCorner() {
        for c in PetCorner.allCases {
            let f = FloatingLayout.petFrame(anchor: PetAnchor(fx: c.fractions.fx, fy: c.fractions.fy), petSize: 72, visible: screen)
            XCTAssertTrue(screen.contains(f), "\(c)")
            XCTAssertEqual(f.width, 72 + FloatingLayout.petMargin * 2)
        }
    }
    func testAnchorRoundTrip() {
        let f = FloatingLayout.petFrame(anchor: PetAnchor(fx: 0.3, fy: 0.6), petSize: 80, visible: screen)
        let a = FloatingLayout.anchor(for: f, visible: screen, screenID: 7)
        XCTAssertEqual(a.fx, 0.3, accuracy: 0.001); XCTAssertEqual(a.fy, 0.6, accuracy: 0.001); XCTAssertEqual(a.screenID, 7)
    }
    func testSettleSnapsToNearEdgeOnly() {
        let near = CGRect(x: 10, y: 400, width: 96, height: 96)
        XCTAssertEqual(FloatingLayout.settle(near, visible: screen, snap: true).minX, FloatingLayout.screenInset - FloatingLayout.petMargin, accuracy: 0.001)
        let far = CGRect(x: 500, y: 400, width: 96, height: 96)
        XCTAssertEqual(FloatingLayout.settle(far, visible: screen, snap: true), far)
        XCTAssertEqual(FloatingLayout.settle(near, visible: screen, snap: false), near)
        XCTAssertTrue(screen.contains(FloatingLayout.settle(CGRect(x: 2000, y: 2000, width: 96, height: 96), visible: screen, snap: true)))
    }
    func testChatOpensBesidePet() {
        let size = CGSize(width: 380, height: 540)
        // pet on the left, low: chat to its right, bottoms aligned
        let petLow = CGRect(x: 40, y: 40, width: 96, height: 96)
        let a = FloatingLayout.chatFrame(besidePet: petLow, chatSize: size, visible: screen)
        XCTAssertGreaterThanOrEqual(a.minX, petLow.maxX - FloatingLayout.petMargin)
        XCTAssertEqual(a.minY, petLow.minY + FloatingLayout.petMargin, accuracy: 0.001)
        // pet on the right edge: chat to its left
        let petRight = CGRect(x: 1440 - 108, y: 40, width: 96, height: 96)
        let b = FloatingLayout.chatFrame(besidePet: petRight, chatSize: size, visible: screen)
        XCTAssertLessThanOrEqual(b.maxX, petRight.minX + FloatingLayout.petMargin)
        // pet high: chat hangs down from the pet
        let petHigh = CGRect(x: 40, y: 780, width: 96, height: 96)
        let c = FloatingLayout.chatFrame(besidePet: petHigh, chatSize: size, visible: screen)
        XCTAssertTrue(screen.contains(c))
        XCTAssertEqual(c.maxY, min(petHigh.maxY - FloatingLayout.petMargin, screen.maxY), accuracy: 0.001)
    }
    func testChatAlwaysFullyOnScreen() {
        for x in stride(from: 0.0, through: 1344.0, by: 112) {
            for y in stride(from: 0.0, through: 804.0, by: 134) {
                let f = FloatingLayout.chatFrame(besidePet: CGRect(x: x, y: y, width: 96, height: 96), chatSize: CGSize(width: 380, height: 540), visible: screen)
                XCTAssertTrue(screen.contains(f), "pet at \(x),\(y) -> \(f)")
            }
        }
    }
    func testChatLargerThanScreenIsShrunk() {
        let small = CGRect(x: 0, y: 0, width: 300, height: 300)
        let f = FloatingLayout.chatFrame(besidePet: CGRect(x: 100, y: 100, width: 96, height: 96), chatSize: CGSize(width: 900, height: 900), visible: small)
        XCTAssertTrue(small.contains(f))
    }
    func testDefaultChatFrameOnScreen() {
        XCTAssertTrue(screen.contains(FloatingLayout.defaultChatFrame(chatSize: CGSize(width: 380, height: 540), visible: screen)))
    }
}
