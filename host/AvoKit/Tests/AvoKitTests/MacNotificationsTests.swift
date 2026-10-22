import Foundation
import Testing
@testable import AvoKit

@Suite struct MacNotificationsTests {
    /// Launch Services marks apps in these folders `in-temp-dir` and does not
    /// find them by bundle identifier, so Notification Center refuses them.
    @Test func temporaryFoldersAreTheOnesMacOSIgnores() {
        let temporary = URL(filePath: "/private/var/folders/z3/0z9q/T/", directoryHint: .isDirectory)
        for path in ["/private/tmp/build-501/DerivedData/Build/Products/Debug/Avo.app",
                     "/tmp/Avo.app",
                     "/private/var/tmp/Avo.app",
                     "/private/var/folders/z3/0z9q/T/avo-shims-1/Android Apps/F-Droid.app",
                     "/var/folders/z3/0z9q/T/AppTranslocation/0A1B2C3D/d/Avo.app"] {
            #expect(TemporaryFolder.contains(URL(filePath: path), temporaryDirectory: temporary), "\(path)")
        }
        for path in ["/Applications/Avo.app",
                     "/Users/me/Applications/Avo.app",
                     "/Users/me/Library/Developer/Avo/Live/Avo.app",
                     "/Users/me/Library/Developer/Xcode/DerivedData/Avo-abc/Build/Products/Debug/Avo.app",
                     "/Volumes/Avo/Avo.app",
                     "/Users/me/tmp/Avo.app",
                     "/private/tmpfiles/Avo.app"] {
            #expect(!TemporaryFolder.contains(URL(filePath: path), temporaryDirectory: temporary), "\(path)")
        }
    }

    @Test func permissionTravelsToTheControlPanel() throws {
        let permissions = [
            MacNotificationPermission.allowed,
            MacNotificationPermission(state: .notDetermined),
            MacNotificationPermission(state: .notDetermined, asking: true),
            MacNotificationPermission(state: .denied),
            MacNotificationPermission(state: .unavailable, temporaryFolder: "/private/tmp/Avo.app",
                                      refusal: "Notifications are not allowed for this application"),
        ]
        for permission in permissions {
            let event = DaemonEvent.macNotifications(permission)
            #expect(try AvoXPC.decode(DaemonEvent.self, from: AvoXPC.encode(event)) == event)
        }
        #expect(MacNotificationPermission.allowed.isAllowed)
        #expect(!MacNotificationPermission(state: .notDetermined, asking: true).isAllowed)
        #expect(!MacNotificationPermission(state: .denied).isAllowed)
    }
}

@Suite struct NotificationGroupTests {
    private func notification(_ package: String, _ n: Int) -> AndroidNotification {
        AndroidNotification(key: "0|\(package)|\(n)|null|10124", package: package, appName: package == "com.avodroid.hello" ? "Avo Hello" : "F-Droid",
                            title: "Title \(n)", body: "Body \(n)", postedAt: Date(timeIntervalSince1970: Double(n)))
    }

    /// One chatty app is one group: groups follow their newest notification.
    @Test func groupsPerAppNewestFirst() {
        let list = [notification("com.avodroid.hello", 9), notification("org.fdroid.fdroid", 8), notification("com.avodroid.hello", 7),
                    notification("com.avodroid.hello", 6), notification("org.fdroid.fdroid", 5)]
        let groups = NotificationGroup.grouping(list)
        #expect(groups.map(\.package) == ["com.avodroid.hello", "org.fdroid.fdroid"])
        #expect(groups[0].appName == "Avo Hello")
        #expect(groups[0].notifications.map(\.title) == ["Title 9", "Title 7", "Title 6"])
        #expect(groups[0].newest.title == "Title 9")
        #expect(groups[1].notifications.map(\.title) == ["Title 8", "Title 5"])
        #expect(NotificationGroup.grouping([]).isEmpty)
    }
}
