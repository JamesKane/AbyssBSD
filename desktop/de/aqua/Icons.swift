// Aqua preference-pane icons — since P11.8, an icon set in the theme
// (themes/aqua/icons/prefs.dl: `icon.<name>`), drawn by `Draw.icon`. Original,
// stylized glyphs in the Jaguar idiom (glossy tiles, water circles, simple white
// emblems) — NOT Apple's icon artwork.

import CCairo

public enum PrefIcon: Sendable {
    case showAll, displays, sound, network, startupDisk
    case desktop, dock, general, international, loginItems, myAccount, screenEffects
    case cdsDvds, colorSync, energySaver, keyboard, mouse
    case internetIcon, quicktime, sharing
    case accounts, classic, dateTime, softwareUpdate, speech, universalAccess
}

public enum Icons {
    /// Draw `icon` filling the square `box` (logical points): the theme's
    /// `icon.<name>`.
    public static func draw(_ cr: OpaquePointer, _ icon: PrefIcon, in box: Rect) {
        Draw.icon("icon." + icon.name, cr, box)
    }
}

extension PrefIcon {
    /// The icon set's name for it: `icon.<name>`.
    public var name: String {
        switch self {
        case .showAll: return "showAll"
        case .displays: return "displays"
        case .sound: return "sound"
        case .network: return "network"
        case .startupDisk: return "startupDisk"
        case .desktop: return "desktop"
        case .dock: return "dock"
        case .general: return "general"
        case .international: return "international"
        case .loginItems: return "loginItems"
        case .myAccount: return "myAccount"
        case .screenEffects: return "screenEffects"
        case .cdsDvds: return "cdsDvds"
        case .colorSync: return "colorSync"
        case .energySaver: return "energySaver"
        case .keyboard: return "keyboard"
        case .mouse: return "mouse"
        case .internetIcon: return "internetIcon"
        case .quicktime: return "quicktime"
        case .sharing: return "sharing"
        case .accounts: return "accounts"
        case .classic: return "classic"
        case .dateTime: return "dateTime"
        case .softwareUpdate: return "softwareUpdate"
        case .speech: return "speech"
        case .universalAccess: return "universalAccess"
        }
    }
}
