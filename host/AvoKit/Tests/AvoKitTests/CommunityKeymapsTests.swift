import Foundation
import Testing
import AvoKeymap

/// The key mappings Avo ships (profiles/keymaps) and the sample app's,
/// read by avo_kit's AvoKeymap as Avo.app reads them.
@Suite struct CommunityKeymapsTests {
    @Test func communityProfilesAreValid() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardizedFileURL
        let directory = root.appending(path: "profiles/keymaps")
        // Plus the sample app's profile (guest/samples/hello), which uses every kind of control.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" } + [root.appending(path: "guest/samples/hello/keymap/com.avodroid.hello.json")]
        #expect(files.count > 1)
        for file in files {
            let profile = try KeymapProfile.decode(Data(contentsOf: file))
            #expect(profile.validate().isEmpty, "\(file.lastPathComponent): \(profile.validate())")
            #expect(file.deletingPathExtension().lastPathComponent == profile.package)
        }
    }
}
