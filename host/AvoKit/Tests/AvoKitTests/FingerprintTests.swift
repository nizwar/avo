import AvoKit
import Foundation
import Testing

@Suite struct FingerprintTests {
    static let fingers = [Fingerprint(id: 1, name: "Right thumb"), Fingerprint(id: 2, name: "Left index finger")]

    @Test func namesAreTrimmedAndChecked() throws {
        #expect(try FingerprintName.validated("  Right index  ", among: Self.fingers).get() == "Right index")
        #expect(FingerprintName.validated("   ", among: Self.fingers) == .failure(.emptyName))
        #expect(FingerprintName.validated("", among: []) == .failure(.emptyName))
        let long = String(repeating: "x", count: FingerprintName.maximumLength + 1)
        #expect(FingerprintName.validated(long, among: []) == .failure(.nameTooLong(maximum: FingerprintName.maximumLength)))
        #expect((try? FingerprintName.validated(String(repeating: "x", count: FingerprintName.maximumLength), among: []).get()) != nil)
        #expect(FingerprintName.validated("Right\nthumb", among: []) == .failure(.invalidName))
        #expect(FingerprintName.validated("Tab\there", among: []) == .failure(.invalidName))
        // Emoji and accents are fine.
        #expect(try FingerprintName.validated("Jempol kanan 👍", among: []).get() == "Jempol kanan 👍")
    }

    @Test func namesAreUniqueIgnoringCaseAndAccents() throws {
        #expect(FingerprintName.validated("right THUMB", among: Self.fingers) == .failure(.duplicateName("Right thumb")))
        #expect(FingerprintName.validated(" Left Index Finger ", among: Self.fingers) == .failure(.duplicateName("Left index finger")))
        #expect(FingerprintName.validated("Rïght thumb", among: Self.fingers) == .failure(.duplicateName("Right thumb")))
        // A finger keeps (or recases) its own name.
        #expect(try FingerprintName.validated("Right Thumb", among: Self.fingers, renaming: 1).get() == "Right Thumb")
        #expect(FingerprintName.validated("Right thumb", among: Self.fingers, renaming: 2) == .failure(.duplicateName("Right thumb")))
    }

    @Test func avoKeepsTwoHandsOfFingers() throws {
        let ten = (1...10).map { Fingerprint(id: $0, name: "Finger \($0)", enrolled: $0 <= 5) }
        #expect(FingerprintName.validated("Eleventh", among: ten) == .failure(.tooManyFingers(maximum: 10)))
        // Renaming one of the ten is still fine.
        #expect(try FingerprintName.validated("Eleventh", among: ten, renaming: 3).get() == "Eleventh")
        #expect(FingerprintStatus.androidMaximum == 5)
    }

    @Test func fingersSavedBeforeAvoKeptItsOwnWereAndroids() throws {
        let old = try JSONDecoder().decode(Fingerprint.self, from: Data(#"{"id":1,"name":"Right thumb"}"#.utf8))
        #expect(old == Fingerprint(id: 1, name: "Right thumb", enrolled: true))
        let mine = Fingerprint(id: 2, name: "Left thumb", enrolled: false)
        #expect(try JSONDecoder().decode(Fingerprint.self, from: JSONEncoder().encode(mine)) == mine)
    }

    @Test func suggestionsSkipTakenNames() {
        let suggestions = FingerprintName.unusedSuggestions(among: [Fingerprint(id: 1, name: "right thumb")])
        #expect(suggestions.count == FingerprintName.suggestions.count - 1)
        #expect(!suggestions.contains("Right thumb"))
        #expect(suggestions.first == "Right index finger")
    }

    @Test func statusSaysWhenATouchCanGoIn() {
        var status = FingerprintStatus(availability: .ready, fingers: Self.fingers)
        #expect(status.canEdit && status.canTouch && !status.enrolling)
        status.lockout = .timed
        #expect(status.canEdit && !status.canTouch)
        status.lockout = .none
        status.credentialRequired = true
        #expect(!status.canTouch)
        // Fingers are Avo's: they change while Android is stopped or has no screen lock too.
        #expect(FingerprintStatus.androidStopped.canEdit && !FingerprintStatus.androidStopped.canTouch)
        #expect(FingerprintStatus(availability: .noScreenLock).canEdit)
        #expect(!FingerprintStatus(availability: .unsupported).canEdit)
        #expect(FingerprintStatus(availability: .ready, request: FingerprintRequest(purpose: .enroll, package: "com.android.settings")).enrolling)
        #expect(status.finger(2)?.name == "Left index finger")
        #expect(status.finger(3) == nil)
        #expect(FingerprintRequest(purpose: .authenticate, package: "com.android.systemui").isLockScreen)
        #expect(!FingerprintRequest(purpose: .authenticate, package: "com.avodroid.hello").isLockScreen)
    }

    @Test func statusAndErrorsCrossXPC() throws {
        let status = FingerprintStatus(availability: .ready, fingers: Self.fingers, lockout: .permanent, credentialRequired: true,
                                       request: FingerprintRequest(purpose: .enroll, package: "com.android.settings"))
        let event = DaemonEvent.fingerprints(status)
        #expect(try AvoXPC.decode(DaemonEvent.self, from: AvoXPC.encode(event)) == event)
        for problem: FingerprintProblem in [.emptyName, .nameTooLong(maximum: 40), .invalidName, .duplicateName("A"), .tooManyFingers(maximum: 10),
                                            .unsupported, .unknownFinger, .unregisteredFinger, .alreadyInAndroid("Right thumb"), .androidRefused("why")] {
            let error = AvoError.fingerprint(problem)
            #expect(try AvoXPC.decode(AvoError.self, from: AvoXPC.encode(error)) == error)
            #expect(error.errorDescription == problem.message)
            #expect(!problem.message.isEmpty)
        }
        #expect(AvoXPC.avoError(AvoXPC.nsError(AvoError.fingerprint(.unregisteredFinger))) == .fingerprint(.unregisteredFinger))
        #expect(FingerprintProblem.duplicateName("Right thumb").message.contains("Right thumb"))
        #expect(FingerprintProblem.alreadyInAndroid("Right thumb").message.contains("Right thumb"))
        for result in [FingerprintTouchResult.recognized, .notRecognized, .enrolled, .lockedOut, .credentialRequired, .nobodyAsked, .touched] {
            #expect(try AvoXPC.decode(FingerprintTouchResult.self, from: AvoXPC.encode(result)) == result)
        }
    }

    @Test func problemsSpeakIndonesian() throws {
        let path = try #require(Bundle.avoKit.path(forResource: "id", ofType: "lproj"))
        let indonesian = try #require(Bundle(path: path))
        let name = "Ibu jari kanan"
        #expect(String(localized: "A finger named “\(name)” is already registered.", bundle: indonesian)
            == "Jari bernama “Ibu jari kanan” sudah terdaftar.")
        #expect(String(localized: "Right thumb", bundle: indonesian) == "Ibu jari kanan")
        #expect(FingerprintProblem.duplicateName(name).message == "A finger named “Ibu jari kanan” is already registered.") // tests run in English
    }

    @Test func controlPanelLinksNameAPane() {
        let url = ControlPanelLink.url(pane: ControlPanelLink.fingerprintsPane)
        #expect(url.absoluteString == "avo-control-panel://fingerprints")
        #expect(ControlPanelLink.pane(in: url) == "fingerprints")
        #expect(ControlPanelLink.pane(in: URL(string: "AVO-CONTROL-PANEL://Fingerprints")!) == "fingerprints")
        #expect(ControlPanelLink.pane(in: URL(string: "https://fingerprints")!) == nil)
        #expect(ControlPanelLink.pane(in: URL(filePath: "/tmp/app.apk")) == nil)
        #expect(ControlPanelLink.pane(in: URL(string: "avo-control-panel:")!) == nil)
    }

    @Test func aLinkOpensAnAppsPage() {
        let url = ControlPanelLink.url(appPage: "com.Example.Game")
        #expect(url.absoluteString == "avo-control-panel://app/com.Example.Game")
        #expect(ControlPanelLink.appPage(in: url) == "com.Example.Game")
        #expect(ControlPanelLink.appPage(in: URL(string: "AVO-CONTROL-PANEL://App/com.example.game")!) == "com.example.game")
        #expect(ControlPanelLink.appPage(in: URL(string: "avo-control-panel://app")!) == nil)
        #expect(ControlPanelLink.appPage(in: URL(string: "avo-control-panel://app/a/b")!) == nil)
        #expect(ControlPanelLink.appPage(in: ControlPanelLink.url(pane: ControlPanelLink.fingerprintsPane)) == nil)
        #expect(ControlPanelLink.appPage(in: URL(string: "https://app/com.example.game")!) == nil)
        // Not a Settings pane.
        #expect(ControlPanelLink.pane(in: url) == ControlPanelLink.appPageHost)
    }
}
