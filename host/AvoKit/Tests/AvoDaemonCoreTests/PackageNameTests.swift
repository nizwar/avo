import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// A package name from Android becomes file names on the Mac (its icon,
/// its key mapping, its App Shim): only a real one is taken.
@Suite struct PackageNameTests {
    @Test func onlyAndroidsPackageNamesAreTaken() {
        for name in ["com.example.app", "android", "com.google.android.gms", "a.b_c.D9", "org.fdroid.fdroid"] {
            #expect(AndroidPackageName.isValid(name), "\(name)")
        }
        for name in ["", "../../Pictures/x", "com..app", ".com.x", "com.x.", "com/evil", "com.example app", "1com.x",
                     "com.1x", "é.x", "com.x\0", String(repeating: "a", count: 256)] {
            #expect(!AndroidPackageName.isValid(name), "\(name.debugDescription)")
        }
    }

    /// `cmd package list packages`: a line whose name is not one (a guest
    /// with root can print anything) is left out.
    @Test func aListingKeepsOnlyRealPackageNames() {
        let listing = """
        package:/data/app/~~a/com.example.app-1/base.apk=com.example.app versionCode:42
        package:/data/app/~~b/x/base.apk=../../../../Pictures/x versionCode:1
        package:/system/framework/framework-res.apk=android versionCode:37
        """
        let packages = HostAgent.parsePackages(listing, system: false)
        #expect(packages.map(\.package) == ["com.example.app", "android"])
        #expect(packages.first?.versionCode == 42)
    }
}
