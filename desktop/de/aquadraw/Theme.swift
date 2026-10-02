// Aqua — Mac OS X 10.2 "Jaguar" visual tokens.
//
// Values distilled from the 512pixels Aqua screenshot library. These are the
// single source of truth for the look; widgets read from here so the palette
// stays consistent and tunable. Provisional, refined against references.

public struct Color: Sendable, Equatable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    /// 0xRRGGBB convenience.
    public init(hex: UInt32, a: Double = 1) {
        self.init(Double((hex >> 16) & 0xff) / 255.0,
                  Double((hex >> 8) & 0xff) / 255.0,
                  Double(hex & 0xff) / 255.0, a)
    }
    public func with(a: Double) -> Color { Color(r, g, b, a) }

    /// Parse a config colour string: `#rrggbb` or `#aarrggbb` (alpha first, as
    /// the sibling's `pool` files use, e.g. `#ff202028`). nil if malformed.
    public init?(cssHex: String) {
        var s = Substring(cssHex)
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard let v = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6: self.init(hex: v, a: 1)
        case 8: self.init(hex: v & 0x00ff_ffff, a: Double((v >> 24) & 0xff) / 255.0)
        default: return nil
        }
    }
}

/// Every token a theme sets (PHASE11 P11.2). The defaults are Jaguar's, and
/// they are the compiled fallback — used only when no theme file can be found,
/// and said out loud when they are (`ThemeLoader.announce`). The shipped Aqua
/// theme (`themes/aqua/theme.ini`) states the same values as data, and a test
/// holds the two equal, so neither can drift from the other.
public struct ThemeTokens: Sendable, Equatable {
    // Window chrome. Jaguar title bars are a smooth light-grey gradient with a
    // near-white top edge and very faint horizontal pinstripes.
    public var titleBarTop: Color = Color(hex: 0xf4f4f4)
    public var titleBarBottom: Color = Color(hex: 0xcfcfcf)
    public var titleBarHighlight: Color = Color(hex: 0xfdfdfd)
    public var titleBarPinstripe: Color = Color(0, 0, 0, 0.035)
    public var titleBarInactiveTop: Color = Color(hex: 0xf6f6f6)
    public var titleBarInactiveBottom: Color = Color(hex: 0xe2e2e2)
    public var windowBorder: Color = Color(hex: 0x6f6f6f)
    public var titleText: Color = Color(hex: 0x303030)
    public var titleBarHeight: Double = 22
    public var windowCornerRadius: Double = 7

    // Content area: the flat light grey of a Jaguar system window. (White +
    // pinstripe is the document-window variant, kept available via pinstripe.)
    public var contentBackground: Color = Color(hex: 0xececec)
    public var pinstripe: Color = Color(hex: 0xeef2f7, a: 0.6)
    public var separator: Color = Color(0, 0, 0, 0.12)

    // Traffic lights (close / minimize / zoom): glassy Aqua water-drops.
    public var close: Color = Color(hex: 0xff5f52)
    public var minimize: Color = Color(hex: 0xffbd2e)
    public var zoom: Color = Color(hex: 0x29c440)
    public var trafficInactive: Color = Color(hex: 0xcacaca)
    public var trafficRim: Color = Color(0, 0, 0, 0.22)
    public var trafficRadius: Double = 6.5
    public var trafficSpacing: Double = 20
    public var trafficInset: Double = 10
    // The frame around a foreign window, the resize band along a window's
    // bottom and its corners (P9.4), and the toolbar pill (P11.6).
    public var chromeBorder: Double = 1
    public var chromeResizeBand: Double = 6
    public var chromeResizeCorner: Double = 14
    public var chromePillWidth: Double = 22
    public var chromePillHeight: Double = 13
    public var chromePillInset: Double = 8
    /// The window title's size — measured and drawn at it (P11.9).
    public var chromeTitleSize: Double = 13
    /// Below this many points an icon draws its `.small` variant when it has
    /// one (P11.8) — detail that is only legible at full size.
    public var iconSmallBelow: Double = 24
    /// The pointer's cell, in points (BACKLOG U.7): a cursor list draws in a
    /// `cursor.size` square, and is rasterised at each display's scale.
    public var cursorSize: Double = 24

    // Layer 3: the toolkit's layout metrics (P11.5), once enums in de/aqua.
    public var toastWidth: Double = 300
    public var toastTopInset: Double = 8
    public var toastRightInset: Double = 12
    public var toastGap: Double = 8
    public var toastPadX: Double = 14
    public var toastPadY: Double = 11
    public var toastSummarySize: Double = 13
    public var toastBodySize: Double = 12
    public var toastLineHeight: Double = 16
    public var toastCorner: Double = 10
    public var toastBaseHeight: Double = 42
    public var toastMaxBodyLines: Double = 4
    public var desktopCellW: Double = 96
    public var desktopCellH: Double = 84
    public var desktopIconSize: Double = 48
    public var desktopMargin: Double = 12
    public var desktopTopInset: Double = 26
    public var finderToolbarHeight: Double = 36
    public var finderStatusHeight: Double = 18
    public var finderScrollbarWidth: Double = 15
    public var finderIconSize: Double = 48
    public var finderCellW: Double = 88
    public var finderCellH: Double = 76
    public var finderGridPad: Double = 10
    public var finderRowHeight: Double = 18
    public var finderListIcon: Double = 14
    public var menuBarHeight: Double = 22
    public var menuBarLeftMargin: Double = 8
    public var menuBarSystemSlot: Double = 26
    public var menuBarTitlePadX: Double = 9
    public var menuBarClockMarginRight: Double = 14
    public var menuBarFontSize: Double = 13
    public var dockGap: Double = 6
    public var dockMaxScale: Double = 1.9
    public var dockPanelPadV: Double = 6
    public var dockPanelPadH: Double = 12
    public var dockBottomMargin: Double = 6
    public var menuItemHeight: Double = 20.0
    public var menuSeparatorHeight: Double = 12.0
    public var menuPadV: Double = 4.0
    public var menuTitleX: Double = 22.0
    public var menuKeyGap: Double = 28.0
    public var menuRightInset: Double = 14.0
    public var statusVolumeWidth: Double = 22
    public var statusBatteryWidth: Double = 46
    public var statusGap: Double = 6
    public var statusClockGap: Double = 10

    // Default ("aqua blue") gel button.
    public var buttonBlueTop: Color = Color(hex: 0x9fc3f6)
    public var buttonBlueMid: Color = Color(hex: 0x4e8df0)
    public var buttonBlueBottom: Color = Color(hex: 0x2061c9)
    public var buttonBlueBorder: Color = Color(hex: 0x1b4f9e)
    // White gel button.
    public var buttonWhiteTop: Color = Color(hex: 0xffffff)
    public var buttonWhiteBottom: Color = Color(hex: 0xd7d7d7)
    public var buttonWhiteBorder: Color = Color(hex: 0x9a9a9a)
    public var buttonGloss: Color = Color(1, 1, 1, 0.55)
    public var buttonTextOnBlue: Color = Color(hex: 0x000000)   // black: white failed the floor (P11.10)
    public var buttonTextOnWhite: Color = Color(hex: 0x202020)

    // Text field: white well with a soft inset top-shadow; the focused variant
    // gets the Aqua blue focus ring.
    public var fieldBackground: Color = Color(hex: 0xffffff)
    public var fieldBorder: Color = Color(hex: 0x9a9a9a)
    public var fieldInsetShadow: Color = Color(0, 0, 0, 0.14)
    public var fieldText: Color = Color(hex: 0x141414)
    public var fieldPlaceholder: Color = Color(hex: 0x949494)   // 3:1 on white (P11.10)
    public var fieldFocusRing: Color = Color(hex: 0x74a6ee, a: 0.85)
    public var fieldCaret: Color = Color(hex: 0x2061c9)

    // Controls (checkbox / radio / slider / pop-up / progress). White gel bodies
    // share this palette; the "on" state reuses the blue gel button colours.
    public var controlWhiteTop: Color = Color(hex: 0xffffff)
    public var controlWhiteBottom: Color = Color(hex: 0xe3e3e3)
    public var controlBorder: Color = Color(hex: 0x8b8b8b)
    public var controlInsetShadow: Color = Color(0, 0, 0, 0.13)
    public var controlGlyph: Color = Color(hex: 0xffffff)      // check / dot on blue
    public var controlLabel: Color = Color(hex: 0x1a1a1a)
    public var sliderTrack: Color = Color(hex: 0xcccccc)
    public var sliderTrackEdge: Color = Color(0, 0, 0, 0.30)
    public var progressTrack: Color = Color(hex: 0xd6d6d6)
    public var groupBoxBorder: Color = Color(0, 0, 0, 0.16)
    // Sheet: a modal panel that slides from the title bar; the parent dims.
    public var sheetBackground: Color = Color(hex: 0xededed)
    public var sheetDim: Color = Color(0, 0, 0, 0.30)

    // Tab view: a light pane with rounded-top tabs sitting on its top border.
    // The selected tab's bottom matches the pane so it reads as "connected".
    public var tabPaneBackground: Color = Color(hex: 0xf0f0f0)
    public var tabSelectedTop: Color = Color(hex: 0xffffff)
    public var tabSelectedBottom: Color = Color(hex: 0xf0f0f0)
    public var tabUnselectedTop: Color = Color(hex: 0xdadada)
    public var tabUnselectedBottom: Color = Color(hex: 0xc4c4c4)
    public var tabBorder: Color = Color(hex: 0x8b8b8b)
    public var tabText: Color = Color(hex: 0x1f1f1f)

    // Pop-up menu: white sheet, blue selection highlight (classic Aqua menu blue).
    public var menuBackground: Color = Color(hex: 0xffffff)
    public var menuBorder: Color = Color(hex: 0x8b8b8b)
    public var menuHighlight: Color = Color(hex: 0x3f6fdf)
    public var menuText: Color = Color(hex: 0x1a1a1a)
    public var menuTextOnHighlight: Color = Color(hex: 0xffffff)
    /// A command that cannot run now (P10.1): Jaguar's grey, still legible.
    public var menuTextDisabled: Color = Color(hex: 0x949494)   // 3:1 on white (P11.10)
    public var menuSeparator: Color = Color(hex: 0xd9d9d9)

    // Menu bar: a light, faintly glassy strip at the top of the screen with a
    // 1px darker bottom edge; the open/hovered title takes the menu blue.
    public var menuBarTop: Color = Color(hex: 0xfcfcfc)
    public var menuBarBottom: Color = Color(hex: 0xebebeb)
    public var menuBarBorder: Color = Color(hex: 0xa6a6a6)
    public var menuBarText: Color = Color(hex: 0x161616)

    public var bodyText: Color = Color(hex: 0x202020)
    public var secondaryText: Color = Color(hex: 0x6b6b6b)

    // MARK: Attention
    //
    // Added for the installer's hub (PHASE5 P5.4), where "this row still needs
    // you" has to read differently from "this row is fine" at a glance, without
    // making the whole screen shout. Jaguar's own alert accents are this warm
    // red on a barely-tinted panel.
    public var attentionText: Color = Color(hex: 0x9a3b2e)
    public var attentionBackground: Color = Color(hex: 0xfdf4f1)
    public var rowBackground: Color = Color(hex: 0xfbfbfb)
    // Lists and toolbars (P11.2: these were literals in the Finder and scenes).
    public var listBackground: Color = Color(hex: 0xffffff)
    public var listStripe: Color = Color(hex: 0xedf0f7)
    public var listHeaderTop: Color = Color(hex: 0xf6f6f6)
    public var listHeaderBottom: Color = Color(hex: 0xdedede)
    public var toolbarTop: Color = Color(hex: 0xf0f0f0)
    public var toolbarBottom: Color = Color(hex: 0xdcdcdc)
    public var toolbarGlyph: Color = Color(hex: 0x3a3a3a)
    public var toolbarSeparator: Color = Color(0, 0, 0, 0.25)
    public var toolbarLabelText: Color = Color(hex: 0x303030)
    public var segmentGlyph: Color = Color(hex: 0x4a4a4a)
    public var controlPressedTop: Color = Color(hex: 0xc8c8c8)
    public var controlPressedBottom: Color = Color(hex: 0xe4e4e4)
    public var statusBarTop: Color = Color(hex: 0xeaeaea)
    public var statusBarBottom: Color = Color(hex: 0xd8d8d8)
    public var prefsToolbarTop: Color = Color(hex: 0xededed)
    public var prefsToolbarBottom: Color = Color(hex: 0xd8d8d8)
    public var sectionTitleText: Color = Color(hex: 0x1a1a1a)
    public var iconLabelText: Color = Color(hex: 0x202020)

    // Sheets, toasts and veils.
    public var sheetShadow: Color = Color(0, 0, 0, 0.18)
    public var toastShadow: Color = Color(0, 0, 0, 0.18)
    public var toastTop: Color = Color(hex: 0xfdfdfd, a: 0.96)
    public var toastBottom: Color = Color(hex: 0xe6e8ec, a: 0.96)
    public var toastPinstripe: Color = Color(hex: 0xd8dbe0, a: 0.45)
    public var toastBorder: Color = Color(hex: 0x8a8f96, a: 0.9)
    public var systemMark: Color = Color(hex: 0x4a6fa5)
    public var disabledVeil: Color = Color(0.93, 0.93, 0.93, 0.62)
    public var statusGlyphCutout: Color = Color(1, 1, 1, 0.9)

    // The desktop and the Dock.
    public var desktopTop: Color = Color(0.36, 0.52, 0.75)
    public var desktopMiddle: Color = Color(0.20, 0.34, 0.58)
    public var desktopBottom: Color = Color(0.11, 0.21, 0.42)
    public var desktopGlow: Color = Color(0.68, 0.80, 0.96, 0.55)
    public var desktopLabelText: Color = Color(1, 1, 1)
    public var desktopLabelShadow: Color = Color(0, 0, 0, 0.55)
    public var dockShelfTop: Color = Color(1, 1, 1, 0.55)
    public var dockShelfBottom: Color = Color(0.86, 0.88, 0.92, 0.5)
    public var dockShelfBorder: Color = Color(0, 0, 0, 0.28)
    public var dockSeparator: Color = Color(0, 0, 0, 0.22)
    public var dockRunningMark: Color = Color(0.1, 0.1, 0.1, 0.85)
    /// The Agent tile's badge (PHASE18 P18.13b): waiting for the person (a
    /// count, Mail's red), or working; and its text.
    public var dockBadgeWaiting: Color = Color(0.85, 0.1, 0.08, 1)
    public var dockBadgeWorking: Color = Color(0.45, 0.47, 0.5, 1)
    public var dockBadgeText: Color = Color(1, 1, 1, 1)
    public var dockLabelBackground: Color = Color(0.12, 0.12, 0.14, 0.9)
    public var dockLabelText: Color = Color(1, 1, 1)

    // The compositor's frames.
    public var inactiveFrameWash: Color = Color(1, 1, 1, 0.35)

    // Accents and materials a look beyond Jaguar's needs (P11.9): Aqua's own
    // lists never read them; its values here are only sensible, not Jaguar's.
    public var glowFocus: Color = Color(hex: 0x74a6ee)   // focus: a ring, a glow, an active window's edge
    public var glowSelect: Color = Color(hex: 0x3f6fdf)   // selection's glow
    public var bevelLight: Color = Color(1, 1, 1, 0.6)   // a bevel's lit edge
    public var bevelShade: Color = Color(0, 0, 0, 0.35)   // a bevel's shaded edge
    public var readoutBackground: Color = Color(hex: 0x2b2b2b)   // an LCD's glass
    public var readoutText: Color = Color(hex: 0x9ee06b)   // an LCD's lit segments
    public var ledOn: Color = Color(hex: 0x3cc43c)   // a running LED
    public var ledWarn: Color = Color(hex: 0xe8a33a)   // a degraded LED
    public var alert: Color = Color(hex: 0xd6453b)   // an alert's colour

    public var fontFamily: String = "Lucida Grande"
    // Type by role (P11.7): a family per role, found by name. Jaguar's are
    // Lucida Grande and Monaco — neither ships free, so on this desktop each
    // falls back to the default chain, exactly as all text did before roles.
    public var fontInterface: String = "Lucida Grande"
    public var fontChrome: String = "Lucida Grande"
    public var fontReadout: String = "Lucida Grande"
    public var fontMono: String = "Monaco"
    /// A role's case and tracking (P11.9): `chrome.upper = true`,
    /// `chrome.tracking = 0.14` (em) in `[fonts]`. Applied where the role is
    /// shaped, so what is measured is what is drawn. Jaguar has none.
    public var roleUpper: Set<String> = []
    public var roleTracking: [String: Double] = [:]

    // The window frame's shape (P11.6): which gadgets, on which side, in what
    // order; where the title sits and how heavy it is. `[chrome]` in theme.ini.
    public var chromeLeft: [Gadget] = [.close, .minimize, .zoom]
    public var chromeRight: [Gadget] = [.pill]
    public var titleAlign: TitleAlign = .center
    public var titleBold = false
    public var fontSize: Double = 13

    public init() {}

    /// Jaguar, as compiled in.
    public static let jaguar = ThemeTokens()

    /// Every token by the name a theme file uses for it — the only way a file
    /// reaches a field, so a misspelt name is an error, not a no-op.
    /// (`nonisolated(unsafe)`: immutable tables of key paths, which Swift 6
    /// does not yet call Sendable.)
    nonisolated(unsafe) static let colorKeys: [(String, WritableKeyPath<ThemeTokens, Color>)] = [
        ("titleBarTop", \.titleBarTop),
        ("titleBarBottom", \.titleBarBottom),
        ("titleBarHighlight", \.titleBarHighlight),
        ("titleBarPinstripe", \.titleBarPinstripe),
        ("titleBarInactiveTop", \.titleBarInactiveTop),
        ("titleBarInactiveBottom", \.titleBarInactiveBottom),
        ("windowBorder", \.windowBorder),
        ("titleText", \.titleText),
        ("contentBackground", \.contentBackground),
        ("pinstripe", \.pinstripe),
        ("separator", \.separator),
        ("close", \.close),
        ("minimize", \.minimize),
        ("zoom", \.zoom),
        ("trafficInactive", \.trafficInactive),
        ("trafficRim", \.trafficRim),
        ("buttonBlueTop", \.buttonBlueTop),
        ("buttonBlueMid", \.buttonBlueMid),
        ("buttonBlueBottom", \.buttonBlueBottom),
        ("buttonBlueBorder", \.buttonBlueBorder),
        ("buttonWhiteTop", \.buttonWhiteTop),
        ("buttonWhiteBottom", \.buttonWhiteBottom),
        ("buttonWhiteBorder", \.buttonWhiteBorder),
        ("buttonGloss", \.buttonGloss),
        ("buttonTextOnBlue", \.buttonTextOnBlue),
        ("buttonTextOnWhite", \.buttonTextOnWhite),
        ("fieldBackground", \.fieldBackground),
        ("fieldBorder", \.fieldBorder),
        ("fieldInsetShadow", \.fieldInsetShadow),
        ("fieldText", \.fieldText),
        ("fieldPlaceholder", \.fieldPlaceholder),
        ("fieldFocusRing", \.fieldFocusRing),
        ("fieldCaret", \.fieldCaret),
        ("controlWhiteTop", \.controlWhiteTop),
        ("controlWhiteBottom", \.controlWhiteBottom),
        ("controlBorder", \.controlBorder),
        ("controlInsetShadow", \.controlInsetShadow),
        ("controlGlyph", \.controlGlyph),
        ("controlLabel", \.controlLabel),
        ("sliderTrack", \.sliderTrack),
        ("sliderTrackEdge", \.sliderTrackEdge),
        ("progressTrack", \.progressTrack),
        ("groupBoxBorder", \.groupBoxBorder),
        ("sheetBackground", \.sheetBackground),
        ("sheetDim", \.sheetDim),
        ("tabPaneBackground", \.tabPaneBackground),
        ("tabSelectedTop", \.tabSelectedTop),
        ("tabSelectedBottom", \.tabSelectedBottom),
        ("tabUnselectedTop", \.tabUnselectedTop),
        ("tabUnselectedBottom", \.tabUnselectedBottom),
        ("tabBorder", \.tabBorder),
        ("tabText", \.tabText),
        ("menuBackground", \.menuBackground),
        ("menuBorder", \.menuBorder),
        ("menuHighlight", \.menuHighlight),
        ("menuText", \.menuText),
        ("menuTextOnHighlight", \.menuTextOnHighlight),
        ("menuTextDisabled", \.menuTextDisabled),
        ("menuSeparator", \.menuSeparator),
        ("menuBarTop", \.menuBarTop),
        ("menuBarBottom", \.menuBarBottom),
        ("menuBarBorder", \.menuBarBorder),
        ("menuBarText", \.menuBarText),
        ("bodyText", \.bodyText),
        ("secondaryText", \.secondaryText),
        ("attentionText", \.attentionText),
        ("attentionBackground", \.attentionBackground),
        ("rowBackground", \.rowBackground),
        ("listBackground", \.listBackground),
        ("listStripe", \.listStripe),
        ("listHeaderTop", \.listHeaderTop),
        ("listHeaderBottom", \.listHeaderBottom),
        ("toolbarTop", \.toolbarTop),
        ("toolbarBottom", \.toolbarBottom),
        ("toolbarGlyph", \.toolbarGlyph),
        ("toolbarSeparator", \.toolbarSeparator),
        ("toolbarLabelText", \.toolbarLabelText),
        ("segmentGlyph", \.segmentGlyph),
        ("controlPressedTop", \.controlPressedTop),
        ("controlPressedBottom", \.controlPressedBottom),
        ("statusBarTop", \.statusBarTop),
        ("statusBarBottom", \.statusBarBottom),
        ("prefsToolbarTop", \.prefsToolbarTop),
        ("prefsToolbarBottom", \.prefsToolbarBottom),
        ("sectionTitleText", \.sectionTitleText),
        ("iconLabelText", \.iconLabelText),
        ("sheetShadow", \.sheetShadow),
        ("toastShadow", \.toastShadow),
        ("toastTop", \.toastTop),
        ("toastBottom", \.toastBottom),
        ("toastPinstripe", \.toastPinstripe),
        ("toastBorder", \.toastBorder),
        ("systemMark", \.systemMark),
        ("disabledVeil", \.disabledVeil),
        ("statusGlyphCutout", \.statusGlyphCutout),
        ("desktopTop", \.desktopTop),
        ("desktopMiddle", \.desktopMiddle),
        ("desktopBottom", \.desktopBottom),
        ("desktopGlow", \.desktopGlow),
        ("desktopLabelText", \.desktopLabelText),
        ("desktopLabelShadow", \.desktopLabelShadow),
        ("dockShelfTop", \.dockShelfTop),
        ("dockShelfBottom", \.dockShelfBottom),
        ("dockShelfBorder", \.dockShelfBorder),
        ("dockSeparator", \.dockSeparator),
        ("dockRunningMark", \.dockRunningMark),
        ("dockBadgeWaiting", \.dockBadgeWaiting),
        ("dockBadgeWorking", \.dockBadgeWorking),
        ("dockBadgeText", \.dockBadgeText),
        ("dockLabelBackground", \.dockLabelBackground),
        ("dockLabelText", \.dockLabelText),
        ("inactiveFrameWash", \.inactiveFrameWash),
        ("glowFocus", \.glowFocus),
        ("glowSelect", \.glowSelect),
        ("bevelLight", \.bevelLight),
        ("bevelShade", \.bevelShade),
        ("readoutBackground", \.readoutBackground),
        ("readoutText", \.readoutText),
        ("ledOn", \.ledOn),
        ("ledWarn", \.ledWarn),
        ("alert", \.alert),
    ]
    nonisolated(unsafe) static let metricKeys: [(String, WritableKeyPath<ThemeTokens, Double>)] = [
        ("titleBarHeight", \.titleBarHeight),
        ("windowCornerRadius", \.windowCornerRadius),
        ("trafficRadius", \.trafficRadius),
        ("trafficSpacing", \.trafficSpacing),
        ("trafficInset", \.trafficInset),
        ("chrome.border", \.chromeBorder),
        ("chrome.resizeBand", \.chromeResizeBand),
        ("chrome.resizeCorner", \.chromeResizeCorner),
        ("chrome.pillWidth", \.chromePillWidth),
        ("chrome.pillHeight", \.chromePillHeight),
        ("chrome.pillInset", \.chromePillInset),
        ("chrome.titleSize", \.chromeTitleSize),
        ("icon.smallBelow", \.iconSmallBelow),
        ("cursor.size", \.cursorSize),
        ("toast.width", \.toastWidth),
        ("toast.topInset", \.toastTopInset),
        ("toast.rightInset", \.toastRightInset),
        ("toast.gap", \.toastGap),
        ("toast.padX", \.toastPadX),
        ("toast.padY", \.toastPadY),
        ("toast.summarySize", \.toastSummarySize),
        ("toast.bodySize", \.toastBodySize),
        ("toast.lineHeight", \.toastLineHeight),
        ("toast.corner", \.toastCorner),
        ("toast.baseHeight", \.toastBaseHeight),
        ("toast.maxBodyLines", \.toastMaxBodyLines),
        ("desktop.cellW", \.desktopCellW),
        ("desktop.cellH", \.desktopCellH),
        ("desktop.iconSize", \.desktopIconSize),
        ("desktop.margin", \.desktopMargin),
        ("desktop.topInset", \.desktopTopInset),
        ("finder.toolbarHeight", \.finderToolbarHeight),
        ("finder.statusHeight", \.finderStatusHeight),
        ("finder.scrollbarWidth", \.finderScrollbarWidth),
        ("finder.iconSize", \.finderIconSize),
        ("finder.cellW", \.finderCellW),
        ("finder.cellH", \.finderCellH),
        ("finder.gridPad", \.finderGridPad),
        ("finder.rowHeight", \.finderRowHeight),
        ("finder.listIcon", \.finderListIcon),
        ("menuBar.height", \.menuBarHeight),
        ("menuBar.leftMargin", \.menuBarLeftMargin),
        ("menuBar.systemSlot", \.menuBarSystemSlot),
        ("menuBar.titlePadX", \.menuBarTitlePadX),
        ("menuBar.clockMarginRight", \.menuBarClockMarginRight),
        ("menuBar.fontSize", \.menuBarFontSize),
        ("dock.gap", \.dockGap),
        ("dock.maxScale", \.dockMaxScale),
        ("dock.panelPadV", \.dockPanelPadV),
        ("dock.panelPadH", \.dockPanelPadH),
        ("dock.bottomMargin", \.dockBottomMargin),
        ("menu.itemHeight", \.menuItemHeight),
        ("menu.separatorHeight", \.menuSeparatorHeight),
        ("menu.padV", \.menuPadV),
        ("menu.titleX", \.menuTitleX),
        ("menu.keyGap", \.menuKeyGap),
        ("menu.rightInset", \.menuRightInset),
        ("status.volumeWidth", \.statusVolumeWidth),
        ("status.batteryWidth", \.statusBatteryWidth),
        ("status.gap", \.statusGap),
        ("status.clockGap", \.statusClockGap),
        ("fontSize", \.fontSize),
    ]
    nonisolated(unsafe) static let fontKeys: [(String, WritableKeyPath<ThemeTokens, String>)] = [
        ("fontFamily", \.fontFamily),
        ("interface", \.fontInterface),
        ("chrome", \.fontChrome),
        ("readout", \.fontReadout),
        ("mono", \.fontMono),
    ]
}

/// The current theme, ambient (PHASE11 P11.2).
///
/// **`Theme.x` is spelt exactly as it always was** — 253 call sites across 16
/// files read a token this way — but each is now a read of the theme that was
/// loaded, not a compiled constant. Ambient rather than threaded: a parameter
/// through every paint function would touch every signature in the toolkit to
/// carry one value that changes perhaps once a session.
public enum Theme {
    /// The loaded theme. Set at startup by `ThemeLoader.loadCurrent()`, and
    /// again whenever a person changes it (P14.2, `ThemeLoader.Watch`). The toolkit draws on one thread — the compositor, too,
    /// dispatches and paints on one (PHASE6 P6.5) — which is what makes an
    /// unsynchronised global honest here rather than hopeful.
    nonisolated(unsafe) public private(set) static var current = ThemeTokens.jaguar

    /// The loaded theme's draw lists (layer 2): Jaguar's, with any the theme
    /// ships replacing theirs by name. Set with `current`.
    nonisolated(unsafe) public private(set) static var lists = JaguarLists.file

    /// The tokens by their index in `colorKeys`/`metricKeys`, for the draw-list
    /// runner: a key-path read into a 116-field struct is what a list spent
    /// most of its overhead on (the P11.4 bench).
    nonisolated(unsafe) static var colorTable = ThemeTokens.colorKeys.map { ThemeTokens.jaguar[keyPath: $0.1] }
    nonisolated(unsafe) static var metricTable = ThemeTokens.metricKeys.map { ThemeTokens.jaguar[keyPath: $0.1] }

    /// Replace the current theme. Lists a theme does not ship stay Jaguar's,
    /// as tokens it does not set do.
    /// The loaded theme's parameters (a person's settings, within the theme's
    /// bounds): what a list reads as `$name` when the widget does not pass one.
    nonisolated(unsafe) public private(set) static var parameters: [String: Double] = [:]

    /// Which theme is loaded, as a number that only goes up: bumped by every
    /// `use`. **What a cache of theme-derived pixels keys on** (PHASE14 §6.7)
    /// — a frame, glow or halo rasterised under generation 3 is never the right
    /// picture under generation 4, whatever else about it matches.
    nonisolated(unsafe) public private(set) static var generation = 0

    public static func use(_ tokens: ThemeTokens, lists theirs: DrawListFile? = nil,
                           parameters p: [String: Double] = [:]) {
        generation += 1
        // Masks rasterised from the old theme's shapes and fonts. Noise tiles
        // stay: a seed and a strength are the same picture in every theme.
        DrawListRunner.forgetThemedMasks()
        current = tokens
        parameters = p
        Text.useRoleStyle(upper: tokens.roleUpper, tracking: tokens.roleTracking)
        Text.useRoles([.interface: tokens.fontInterface, .chrome: tokens.fontChrome,
                       .readout: tokens.fontReadout, .mono: tokens.fontMono])
        colorTable = ThemeTokens.colorKeys.map { tokens[keyPath: $0.1] }
        metricTable = ThemeTokens.metricKeys.map { tokens[keyPath: $0.1] }
        lists = theirs.map { JaguarLists.file.merging($0) } ?? JaguarLists.file
    }

    public static var titleBarTop: Color { current.titleBarTop }
    public static var titleBarBottom: Color { current.titleBarBottom }
    public static var titleBarHighlight: Color { current.titleBarHighlight }
    public static var titleBarPinstripe: Color { current.titleBarPinstripe }
    public static var titleBarInactiveTop: Color { current.titleBarInactiveTop }
    public static var titleBarInactiveBottom: Color { current.titleBarInactiveBottom }
    public static var windowBorder: Color { current.windowBorder }
    public static var titleText: Color { current.titleText }
    public static var titleBarHeight: Double { current.titleBarHeight }
    public static var windowCornerRadius: Double { current.windowCornerRadius }
    public static var contentBackground: Color { current.contentBackground }
    public static var pinstripe: Color { current.pinstripe }
    public static var separator: Color { current.separator }
    public static var close: Color { current.close }
    public static var minimize: Color { current.minimize }
    public static var zoom: Color { current.zoom }
    public static var trafficInactive: Color { current.trafficInactive }
    public static var trafficRim: Color { current.trafficRim }
    public static var trafficRadius: Double { current.trafficRadius }
    public static var trafficSpacing: Double { current.trafficSpacing }
    public static var trafficInset: Double { current.trafficInset }
    public static var buttonBlueTop: Color { current.buttonBlueTop }
    public static var buttonBlueMid: Color { current.buttonBlueMid }
    public static var buttonBlueBottom: Color { current.buttonBlueBottom }
    public static var buttonBlueBorder: Color { current.buttonBlueBorder }
    public static var buttonWhiteTop: Color { current.buttonWhiteTop }
    public static var buttonWhiteBottom: Color { current.buttonWhiteBottom }
    public static var buttonWhiteBorder: Color { current.buttonWhiteBorder }
    public static var buttonGloss: Color { current.buttonGloss }
    public static var buttonTextOnBlue: Color { current.buttonTextOnBlue }
    public static var buttonTextOnWhite: Color { current.buttonTextOnWhite }
    public static var fieldBackground: Color { current.fieldBackground }
    public static var fieldBorder: Color { current.fieldBorder }
    public static var fieldInsetShadow: Color { current.fieldInsetShadow }
    public static var fieldText: Color { current.fieldText }
    public static var fieldPlaceholder: Color { current.fieldPlaceholder }
    public static var fieldFocusRing: Color { current.fieldFocusRing }
    public static var fieldCaret: Color { current.fieldCaret }
    public static var controlWhiteTop: Color { current.controlWhiteTop }
    public static var controlWhiteBottom: Color { current.controlWhiteBottom }
    public static var controlBorder: Color { current.controlBorder }
    public static var controlInsetShadow: Color { current.controlInsetShadow }
    public static var controlGlyph: Color { current.controlGlyph }
    public static var controlLabel: Color { current.controlLabel }
    public static var sliderTrack: Color { current.sliderTrack }
    public static var sliderTrackEdge: Color { current.sliderTrackEdge }
    public static var progressTrack: Color { current.progressTrack }
    public static var groupBoxBorder: Color { current.groupBoxBorder }
    public static var sheetBackground: Color { current.sheetBackground }
    public static var sheetDim: Color { current.sheetDim }
    public static var tabPaneBackground: Color { current.tabPaneBackground }
    public static var tabSelectedTop: Color { current.tabSelectedTop }
    public static var tabSelectedBottom: Color { current.tabSelectedBottom }
    public static var tabUnselectedTop: Color { current.tabUnselectedTop }
    public static var tabUnselectedBottom: Color { current.tabUnselectedBottom }
    public static var tabBorder: Color { current.tabBorder }
    public static var tabText: Color { current.tabText }
    public static var menuBackground: Color { current.menuBackground }
    public static var menuBorder: Color { current.menuBorder }
    public static var menuHighlight: Color { current.menuHighlight }
    public static var menuText: Color { current.menuText }
    public static var menuTextOnHighlight: Color { current.menuTextOnHighlight }
    public static var menuTextDisabled: Color { current.menuTextDisabled }
    public static var menuSeparator: Color { current.menuSeparator }
    public static var menuBarTop: Color { current.menuBarTop }
    public static var menuBarBottom: Color { current.menuBarBottom }
    public static var menuBarBorder: Color { current.menuBarBorder }
    public static var menuBarText: Color { current.menuBarText }
    public static var bodyText: Color { current.bodyText }
    public static var secondaryText: Color { current.secondaryText }
    public static var attentionText: Color { current.attentionText }
    public static var attentionBackground: Color { current.attentionBackground }
    public static var rowBackground: Color { current.rowBackground }
    public static var fontFamily: String { current.fontFamily }
    public static var fontSize: Double { current.fontSize }
    public static var listBackground: Color { current.listBackground }
    public static var listStripe: Color { current.listStripe }
    public static var listHeaderTop: Color { current.listHeaderTop }
    public static var listHeaderBottom: Color { current.listHeaderBottom }
    public static var toolbarTop: Color { current.toolbarTop }
    public static var toolbarBottom: Color { current.toolbarBottom }
    public static var toolbarGlyph: Color { current.toolbarGlyph }
    public static var toolbarSeparator: Color { current.toolbarSeparator }
    public static var toolbarLabelText: Color { current.toolbarLabelText }
    public static var segmentGlyph: Color { current.segmentGlyph }
    public static var controlPressedTop: Color { current.controlPressedTop }
    public static var controlPressedBottom: Color { current.controlPressedBottom }
    public static var statusBarTop: Color { current.statusBarTop }
    public static var statusBarBottom: Color { current.statusBarBottom }
    public static var prefsToolbarTop: Color { current.prefsToolbarTop }
    public static var prefsToolbarBottom: Color { current.prefsToolbarBottom }
    public static var sectionTitleText: Color { current.sectionTitleText }
    public static var iconLabelText: Color { current.iconLabelText }
    public static var sheetShadow: Color { current.sheetShadow }
    public static var toastShadow: Color { current.toastShadow }
    public static var toastTop: Color { current.toastTop }
    public static var toastBottom: Color { current.toastBottom }
    public static var toastPinstripe: Color { current.toastPinstripe }
    public static var toastBorder: Color { current.toastBorder }
    public static var systemMark: Color { current.systemMark }
    public static var disabledVeil: Color { current.disabledVeil }
    public static var statusGlyphCutout: Color { current.statusGlyphCutout }
    public static var desktopTop: Color { current.desktopTop }
    public static var desktopMiddle: Color { current.desktopMiddle }
    public static var desktopBottom: Color { current.desktopBottom }
    public static var desktopGlow: Color { current.desktopGlow }
    public static var desktopLabelText: Color { current.desktopLabelText }
    public static var desktopLabelShadow: Color { current.desktopLabelShadow }
    public static var dockShelfTop: Color { current.dockShelfTop }
    public static var dockShelfBottom: Color { current.dockShelfBottom }
    public static var dockShelfBorder: Color { current.dockShelfBorder }
    public static var dockSeparator: Color { current.dockSeparator }
    public static var dockRunningMark: Color { current.dockRunningMark }
    public static var dockBadgeText: Color { current.dockBadgeText }
    public static var dockLabelBackground: Color { current.dockLabelBackground }
    public static var dockLabelText: Color { current.dockLabelText }
    public static var inactiveFrameWash: Color { current.inactiveFrameWash }
}
