// AppBundles tests — the `.desktop` → `.app` rules, with no filesystem
// (PHASE15 P15.1). The entries are the ones the 16 guest actually has.

import XCTest
@testable import AppBundles

final class AppBundlesTests: XCTestCase {
    let kcalc = """
    [Desktop Entry]
    Name=KCalc
    Name[fr]=KCalc (fr)
    Exec=kcalc
    Icon=accessories-calculator
    Type=Application
    Comment=Scientific Calculator
    """

    func testAnEntryIsReadAndItsLocalisedKeysAreNotTheDefault() throws {
        let e = try XCTUnwrap(DesktopEntry.parse(kcalc))
        XCTAssertEqual(e.name, "KCalc")
        XCTAssertEqual(e.icon, "accessories-calculator")
        XCTAssertNil(e.skipReason())
        XCTAssertEqual(e.command()?.argv, ["kcalc"])
        XCTAssertEqual(e.command()?.takesFiles, false)
        XCTAssertNil(DesktopEntry.parse("Name=nothing\n"), "no [Desktop Entry] group, no entry")
    }

    /// Half the guest's entries are URL handlers, daemons and Xwayland.
    func testWhatIsNotAnApplicationSaysWhy() throws {
        func why(_ extra: String) -> String? {
            DesktopEntry.parse("[Desktop Entry]\nName=X\nExec=x\nType=Application\n" + extra)?.skipReason()
        }
        XCTAssertEqual(why("NoDisplay=true\n"), "NoDisplay (a handler or a service, not an application)")
        XCTAssertEqual(why("Hidden=true\n"), "Hidden")
        XCTAssertEqual(why("OnlyShowIn=KDE;GNOME;\n"), "only for KDE, GNOME")
        XCTAssertEqual(why("NotShowIn=AbyssBSD;\n"), "not for AbyssBSD")
        XCTAssertEqual(why("Terminal=true\n"), "needs a terminal, and there is none yet (P15.4)")
        XCTAssertNil(DesktopEntry.parse("[Desktop Entry]\nName=X\nExec=x\nType=Application\nTerminal=true\n")?
            .skipReason(haveTerminal: true))
        XCTAssertEqual(DesktopEntry.parse("[Desktop Entry]\nName=L\nType=Link\n")?.skipReason(), "a Link, not an application")
        XCTAssertEqual(DesktopEntry.parse("[Desktop Entry]\nName=K\nType=Application\nExec=\n")?.skipReason(), "no Exec")
    }

    /// The spec's quoting, and its field codes: one file code becomes where the
    /// Finder's files go; the rest are dropped; `%%` is a percent sign.
    func testExecIsSplitAsTheSpecSaysAndFieldCodesPlaced() throws {
        let e = try XCTUnwrap(DesktopEntry.parse("""
        [Desktop Entry]
        Type=Application
        Name=Geo
        Exec=kde-geo-uri-handler --query-template "https://maps/?q=<Q> \\"x\\"" --pct 100%% %u %F %i
        """))
        let cmd = try XCTUnwrap(e.command())
        XCTAssertEqual(cmd.argv, ["kde-geo-uri-handler", "--query-template", "https://maps/?q=<Q> \"x\"",
                                  "--pct", "100%", DesktopEntry.filesMarker])
        XCTAssertTrue(cmd.takesFiles)
        XCTAssertNil(DesktopEntry.parse("[Desktop Entry]\nType=Application\nName=Q\nExec=a \"unterminated\n")?.command())
        XCTAssertNil(DesktopEntry.parse("[Desktop Entry]\nType=Application\nName=F\nExec=%f\n")?.command(),
                     "a file code where the program should be")
    }

    func testTheLauncherExecsTheCommandWithTheFilesWhereTheyGo() {
        let s = AppBundle.launcher(argv: ["designer6", "--style", "it's", DesktopEntry.filesMarker],
                                   source: "/usr/local/share/applications/designer.desktop")
        XCTAssertTrue(s.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(s.hasSuffix("exec designer6 --style 'it'\\''s' \"$@\"\n"))
        XCTAssertEqual(AppBundle.directoryName("Qt Widgets Designer"), "Qt Widgets Designer.app")
        XCTAssertEqual(AppBundle.directoryName("a/b"), "a-b.app")
        XCTAssertEqual(AppBundle.directoryName(".hidden"), "hidden.app")
    }

    /// Which running windows are this application's (P15.2): kcalc by its
    /// desktop-file ID, Firefox ESR by its program's name and a suffix.
    func testARunningWindowIsMatchedToItsApplication() throws {
        let k = try XCTUnwrap(DesktopEntry.parse(kcalc)).appIDs(desktopFile: "/usr/local/share/applications/org.kde.kcalc.desktop")
        XCTAssertEqual(k, ["org.kde.kcalc", "kcalc"])
        XCTAssertTrue(AppBundle.matches(appID: "org.kde.kcalc", candidates: k))
        let ff = try XCTUnwrap(DesktopEntry.parse("[Desktop Entry]\nType=Application\nName=Firefox Web Browser\nExec=firefox %U\n"))
            .appIDs(desktopFile: "firefox.desktop")
        XCTAssertEqual(ff, ["firefox"])
        XCTAssertTrue(AppBundle.matches(appID: "firefox-esr", candidates: ff))
        XCTAssertFalse(AppBundle.matches(appID: "firefoxy", candidates: ff))
        XCTAssertFalse(AppBundle.matches(appID: "", candidates: ff))
        let w = try XCTUnwrap(DesktopEntry.parse("[Desktop Entry]\nType=Application\nName=W\nStartupWMClass=org.x.W\nExec=env A=1 /opt/bin/wprog\n"))
            .appIDs(desktopFile: "w.desktop")
        XCTAssertEqual(w, ["org.x.W", "w", "wprog"])
    }

    /// kcalc's icon on the guest: small PNGs in one theme, an SVG in another.
    /// 48 px is too small for the Dock, so the SVG is rasterised.
    func testTheIconIsABigEnoughPNGElseAnSVGElseTheBiggestPNG() {
        let kcalc = ["/i/AdwaitaLegacy/16x16/apps/accessories-calculator.png",
                     "/i/AdwaitaLegacy/48x48/apps/accessories-calculator.png",
                     "/i/breeze/apps/48/accessories-calculator.svg",
                     "/i/Adwaita/symbolic/apps/accessories-calculator-symbolic.svg"]
        XCTAssertEqual(IconLookup.choose(from: kcalc), .svg("/i/breeze/apps/48/accessories-calculator.svg", size: 256))
        let demo = ["/i/hicolor/48x48/apps/gtk3-demo.png", "/i/hicolor/256x256/apps/gtk3-demo.png"]
        XCTAssertEqual(IconLookup.choose(from: demo), .png("/i/hicolor/256x256/apps/gtk3-demo.png"))
        XCTAssertEqual(IconLookup.choose(from: ["/i/x/32x32/apps/a.png", "/i/x/64x64@2x/apps/a.png"]),
                       .png("/i/x/64x64@2x/apps/a.png"), "@2x doubles its size: 128")
        XCTAssertEqual(IconLookup.choose(from: ["/i/x/32x32/apps/a.png"]), .png("/i/x/32x32/apps/a.png"),
                       "nothing better: the best there is")
        XCTAssertNil(IconLookup.choose(from: ["/i/x/scalable/a-symbolic.svg"]))
    }
}
