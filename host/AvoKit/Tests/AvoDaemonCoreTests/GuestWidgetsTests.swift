import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Library › Widgets: what Avo Widgets answers, and how a panel's widget starts.
@Suite struct GuestWidgetsTests {
    /// `content read` of Avo Widgets' providers, as on Android 17 (preview shortened).
    static let output = """
        [{"provider":"com.android.deskclock/com.android.alarmclock.DigitalAppWidgetProvider","package":"com.android.deskclock",\
        "label":"Digital clock","appLabel":"Clock","minWidth":206,"minHeight":129,"cellWidth":0,"cellHeight":0,"resizable":true,\
        "configurable":false,"preview":"iVBORw0KGgo="},\
        {"provider":"com.android.calendar/com.android.calendar.widget.CalendarAppWidgetProvider","package":"com.android.calendar",\
        "label":"Calendar","appLabel":"Calendar","minWidth":110,"minHeight":180,"cellWidth":0,"cellHeight":0,"resizable":true,\
        "configurable":false},\
        {"provider":"com.google.android.apps.wellbeing/.Screen","package":"com.google.android.apps.wellbeing","label":"Your screen time",\
        "appLabel":"Digital Wellbeing","minWidth":100,"minHeight":90,"cellWidth":2,"cellHeight":2,"resizable":true,"configurable":true},\
        {"provider":"com.tencent.ig/com.sirius.meemo.appwidget.pk.MeemoPopularVSWidget","package":"com.tencent.ig",\
        "label":"Popularity Battle Widget","appLabel":"PUBG MOBILE","minWidth":300,"minHeight":110,"cellWidth":4,"cellHeight":2,\
        "resizable":false,"resizing":{"horizontal":false,"vertical":false,"minWidth":300,"minHeight":110,"maxWidth":0,"maxHeight":0},\
        "configurable":false},\
        {"provider":"com.google.android.googlequicksearchbox/.SearchWidgetProvider","package":"com.google.android.googlequicksearchbox",\
        "label":"Search","appLabel":"Google","minWidth":280,"minHeight":40,"cellWidth":0,"cellHeight":0,"resizable":true,\
        "resizing":{"horizontal":true,"vertical":false,"minWidth":80,"minHeight":40,"maxWidth":600,"maxHeight":0},"configurable":false}]
        """

    @Test func readsTheProvidersSortedByApp() throws {
        let providers = try GuestWidgets.providers(Self.output)
        #expect(providers.map(\.label) == ["Calendar", "Digital clock", "Your screen time", "Search", "Popularity Battle Widget"])
        let clock = try #require(providers.first { $0.label == "Digital clock" })
        #expect(clock.preview == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(providers.first { $0.label == "Your screen time" }?.configurable == true)
        #expect(throws: AvoError.self) { try GuestWidgets.providers("Error: no provider") }
    }

    /// How a widget resizes: as Android says, or (from an Avo Widgets that
    /// said only whether) down to its minimum.
    @Test func readsHowWidgetsResize() throws {
        let providers = try GuestWidgets.providers(Self.output)
        let battle = try #require(providers.first { $0.label == "Popularity Battle Widget" })
        #expect(battle.resizeRules == WidgetResizing(horizontal: false, vertical: false, minWidth: 300, minHeight: 110))
        #expect(PlacedWidget(provider: battle).resizing?.resizes == false)
        var older = battle
        older.resizing = nil
        #expect(older.resizeRules == .fixed)
        let search = try #require(providers.first { $0.label == "Search" })
        #expect(search.resizeRules == WidgetResizing(horizontal: true, vertical: false, minWidth: 80, minHeight: 40, maxWidth: 600))
        let clock = try #require(providers.first { $0.label == "Digital clock" })
        #expect(clock.resizing == nil)
        #expect(clock.resizeRules == WidgetResizing(horizontal: true, vertical: true, minWidth: 206, minHeight: 129))
    }

    /// A widget that does not resize zooms, in its own shape; one that does
    /// lays out within its limits, along the ways it resizes only.
    @Test func aPanelTakesTheSizesItsWidgetAllows() throws {
        let providers = try GuestWidgets.providers(Self.output)
        let battle = PlacedWidget(provider: try #require(providers.first { $0.label == "Popularity Battle Widget" }))
        #expect((battle.width, battle.height) == (320, 200))
        #expect(battle.zooms)
        #expect(battle.panelSizeLimits.min == CGSize(width: 160, height: 100))
        #expect(battle.panelSizeLimits.max == CGSize(width: 800, height: 500))
        // The narrow panel of a free resize becomes the smallest zoom.
        #expect(battle.allowedPanelSize(CGSize(width: 144, height: 201)) == CGSize(width: 160, height: 100))
        #expect(battle.allowedPanelSize(CGSize(width: 480, height: 90)) == CGSize(width: 480, height: 300))
        #expect(battle.zoom(panelWidth: 480) == 1.5)

        let search = PlacedWidget(provider: try #require(providers.first { $0.label == "Search" }))
        #expect(!search.zooms)
        #expect(search.zoom(panelWidth: 480) == 1)
        #expect(search.allowedPanelSize(CGSize(width: 700, height: 300)) == CGSize(width: 600, height: CGFloat(search.height)))
        #expect(search.allowedPanelSize(CGSize(width: 20, height: 10)) == CGSize(width: 80, height: CGFloat(search.height)))

        // Rules not known yet (lists saved before): any panel size.
        var old = battle
        old.resizing = nil
        #expect(!old.zooms)
        #expect(old.allowedPanelSize(CGSize(width: 144, height: 201)) == CGSize(width: 144, height: 201))
    }

    @Test func aNewPanelHasTheSizeTheWidgetAsksFor() throws {
        let providers = try GuestWidgets.providers(Self.output)
        // The cells its minimum takes (206 × 129 dp: 4 × 2), or the cells it wants.
        #expect(providers[1].defaultSize == (320, 200))
        #expect(providers[2].defaultSize == (160, 200))
        // A widget that asks for no height still gets a row.
        let flat = WidgetProvider(provider: "a/.B", package: "a", label: "B", appLabel: "A", minWidth: 136, minHeight: 0)
        #expect(flat.defaultSize == (240, 100))
        let huge = WidgetProvider(provider: "a/.B", package: "a", label: "B", appLabel: "A", minWidth: 4000, minHeight: 20)
        #expect(huge.defaultSize == (AndroidWidgets.sizeRange.upperBound, 100))
    }

    @Test func aPanelStartsItsWidgetInATaskOfItsOwn() {
        let data = AndroidWidgets.launchURI(slot: "5f0c", provider: "com.android.deskclock/com.android.alarmclock.DigitalAppWidgetProvider")
        #expect(data == "avo-widget://5f0c?provider=com.android.deskclock/com.android.alarmclock.DigitalAppWidgetProvider")
        #expect(GuestWidgets.startCommand(data: data, display: 9)
            == "am start --display 9 -f 0x18010000 -n com.avodroid.widgets/.WidgetActivity -d '\(data)'")
        #expect(GuestWidgets.deleteCommand(slot: "5f0c") == "content call --uri content://com.avodroid.widgets --method delete --arg '5f0c'")
    }

    /// A panel is larger while Android shows its widget's settings.
    @Test func findsWhatAWidgetDisplayShows() {
        let stacks = """
            RootTask id=66 bounds=[0,0][592,148] displayId=3 userId=0
              taskId=66: com.avodroid.widgets/com.avodroid.widgets.WidgetActivity bounds=[0,0][592,148] userId=0 visible=true \
            topActivity=ComponentInfo{com.google.android.googlequicksearchbox/com.example.SetupActivity}
            RootTask id=64 bounds=[0,0][416,258] displayId=2 userId=0
              taskId=64: com.avodroid.widgets/com.avodroid.widgets.WidgetActivity bounds=[0,0][416,258] userId=0 visible=true \
            topActivity=ComponentInfo{com.avodroid.widgets/com.avodroid.widgets.WidgetActivity}
            """
        let setup = HostAgent.topActivity(of: AndroidWidgets.package, onDisplay: 3, in: stacks)
        #expect(setup == "com.google.android.googlequicksearchbox/com.example.SetupActivity")
        #expect(!AndroidWidgets.showsWidget(top: setup ?? ""))
        let widget = HostAgent.topActivity(of: AndroidWidgets.package, onDisplay: 2, in: stacks)
        #expect(AndroidWidgets.showsWidget(top: widget ?? ""))
        #expect(HostAgent.topActivity(of: AndroidWidgets.package, onDisplay: 9, in: stacks) == nil)
    }
}
