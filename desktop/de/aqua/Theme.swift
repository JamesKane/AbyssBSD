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
}

public enum Theme {
    // Window chrome. Jaguar title bars are a smooth light-grey gradient with a
    // near-white top edge and very faint horizontal pinstripes.
    public static let titleBarTop = Color(hex: 0xf4f4f4)
    public static let titleBarBottom = Color(hex: 0xcfcfcf)
    public static let titleBarHighlight = Color(hex: 0xfdfdfd)
    public static let titleBarPinstripe = Color(0, 0, 0, 0.035)
    public static let titleBarInactiveTop = Color(hex: 0xf6f6f6)
    public static let titleBarInactiveBottom = Color(hex: 0xe2e2e2)
    public static let windowBorder = Color(hex: 0x6f6f6f)
    public static let titleText = Color(hex: 0x303030)
    public static let titleBarHeight: Double = 22
    public static let windowCornerRadius: Double = 7

    // Content area: the flat light grey of a Jaguar system window. (White +
    // pinstripe is the document-window variant, kept available via pinstripe.)
    public static let contentBackground = Color(hex: 0xececec)
    public static let pinstripe = Color(hex: 0xeef2f7, a: 0.6)
    public static let separator = Color(0, 0, 0, 0.12)

    // Traffic lights (close / minimize / zoom): glassy Aqua water-drops.
    public static let close = Color(hex: 0xff5f52)
    public static let minimize = Color(hex: 0xffbd2e)
    public static let zoom = Color(hex: 0x29c440)
    public static let trafficInactive = Color(hex: 0xcacaca)
    public static let trafficRim = Color(0, 0, 0, 0.22)
    public static let trafficRadius: Double = 6.5
    public static let trafficSpacing: Double = 20
    public static let trafficInset: Double = 10

    // Default ("aqua blue") gel button.
    public static let buttonBlueTop = Color(hex: 0x9fc3f6)
    public static let buttonBlueMid = Color(hex: 0x4e8df0)
    public static let buttonBlueBottom = Color(hex: 0x2061c9)
    public static let buttonBlueBorder = Color(hex: 0x1b4f9e)
    // White gel button.
    public static let buttonWhiteTop = Color(hex: 0xffffff)
    public static let buttonWhiteBottom = Color(hex: 0xd7d7d7)
    public static let buttonWhiteBorder = Color(hex: 0x9a9a9a)
    public static let buttonGloss = Color(1, 1, 1, 0.55)
    public static let buttonTextOnBlue = Color(hex: 0xffffff)
    public static let buttonTextOnWhite = Color(hex: 0x202020)

    // Text field: white well with a soft inset top-shadow; the focused variant
    // gets the Aqua blue focus ring.
    public static let fieldBackground = Color(hex: 0xffffff)
    public static let fieldBorder = Color(hex: 0x9a9a9a)
    public static let fieldInsetShadow = Color(0, 0, 0, 0.14)
    public static let fieldText = Color(hex: 0x141414)
    public static let fieldPlaceholder = Color(hex: 0x9a9a9a)
    public static let fieldFocusRing = Color(hex: 0x74a6ee, a: 0.85)
    public static let fieldCaret = Color(hex: 0x2061c9)

    // Controls (checkbox / radio / slider / pop-up / progress). White gel bodies
    // share this palette; the "on" state reuses the blue gel button colours.
    public static let controlWhiteTop = Color(hex: 0xffffff)
    public static let controlWhiteBottom = Color(hex: 0xe3e3e3)
    public static let controlBorder = Color(hex: 0x8b8b8b)
    public static let controlInsetShadow = Color(0, 0, 0, 0.13)
    public static let controlGlyph = Color(hex: 0xffffff)      // check / dot on blue
    public static let controlLabel = Color(hex: 0x1a1a1a)
    public static let sliderTrack = Color(hex: 0xcccccc)
    public static let sliderTrackEdge = Color(0, 0, 0, 0.30)
    public static let progressTrack = Color(hex: 0xd6d6d6)
    public static let groupBoxBorder = Color(0, 0, 0, 0.16)
    // Pop-up menu: white sheet, blue selection highlight (classic Aqua menu blue).
    public static let menuBackground = Color(hex: 0xffffff)
    public static let menuBorder = Color(hex: 0x8b8b8b)
    public static let menuHighlight = Color(hex: 0x3f6fdf)
    public static let menuText = Color(hex: 0x1a1a1a)
    public static let menuTextOnHighlight = Color(hex: 0xffffff)

    public static let bodyText = Color(hex: 0x202020)
    public static let fontFamily = "Lucida Grande"
    public static let fontSize: Double = 13
}
