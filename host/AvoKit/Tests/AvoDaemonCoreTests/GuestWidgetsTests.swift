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
        "appLabel":"Digital Wellbeing","minWidth":100,"minHeight":90,"cellWidth":2,"cellHeight":2,"resizable":true,"configurable":true}]
        """

    @Test func readsTheProvidersSortedByApp() throws {
        let providers = try GuestWidgets.providers(Self.output)
        #expect(providers.map(\.label) == ["Calendar", "Digital clock", "Your screen time"])
        let clock = try #require(providers.first { $0.label == "Digital clock" })
        #expect(clock.preview == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(providers.last?.configurable == true)
        #expect(throws: AvoError.self) { try GuestWidgets.providers("Error: no provider") }
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
            == "am start --display 9 -f 0x18000000 -n dev.avo.widgets/.WidgetActivity -d '\(data)'")
        #expect(GuestWidgets.deleteCommand(slot: "5f0c") == "content call --uri content://dev.avo.widgets --method delete --arg '5f0c'")
    }

    /// A panel is larger while Android shows its widget's settings.
    @Test func findsWhatAWidgetDisplayShows() {
        let stacks = """
            RootTask id=66 bounds=[0,0][592,148] displayId=3 userId=0
              taskId=66: dev.avo.widgets/dev.avo.widgets.WidgetActivity bounds=[0,0][592,148] userId=0 visible=true \
            topActivity=ComponentInfo{com.google.android.googlequicksearchbox/com.example.SetupActivity}
            RootTask id=64 bounds=[0,0][416,258] displayId=2 userId=0
              taskId=64: dev.avo.widgets/dev.avo.widgets.WidgetActivity bounds=[0,0][416,258] userId=0 visible=true \
            topActivity=ComponentInfo{dev.avo.widgets/dev.avo.widgets.WidgetActivity}
            """
        let setup = HostAgent.topActivity(of: AndroidWidgets.package, onDisplay: 3, in: stacks)
        #expect(setup == "com.google.android.googlequicksearchbox/com.example.SetupActivity")
        #expect(!AndroidWidgets.showsWidget(top: setup ?? ""))
        let widget = HostAgent.topActivity(of: AndroidWidgets.package, onDisplay: 2, in: stacks)
        #expect(AndroidWidgets.showsWidget(top: widget ?? ""))
        #expect(HostAgent.topActivity(of: AndroidWidgets.package, onDisplay: 9, in: stacks) == nil)
    }
}
