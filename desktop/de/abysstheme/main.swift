// abyss-theme — the loaded theme, for things that do not draw (P11.10).
//
//   abyss-theme palette       the palette the portal publishes (INI, stdout)
//   abyss-theme check [NAME]  every scheme of a theme against the legibility
//                             floor, in words (a theme author's tool)
//   abyss-theme set NAME [SCHEME]
//                             choose the desktop's theme: writes appearance.ini,
//                             which every running process follows (P14.2) — the
//                             same write System Preferences makes
//
// The theme is chosen as every process chooses it: appearance.ini, or
// $ABYSS_THEME / $ABYSS_THEME_SCHEME.

import AquaDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func err(_ s: String) { (s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "palette":
    switch ThemeLoader.loadCurrent() {
    case .loaded(let t, _):
        print(ThemePalette.ini(t.tokens, name: t.name, scheme: t.scheme), terminator: "")
    case .notFound, .refused:
        // The compiled Jaguar is what draws, so it is what is reported.
        ThemeLoader.announce(ThemeLoader.loadCurrent())
        print(ThemePalette.ini(.jaguar, name: "Aqua (compiled)", scheme: nil), terminator: "")
    }
case "check":
    let name = args.count > 1 ? args[1] : ThemeLoader.choice().name
    guard let dir = ThemeLoader.searchPath().first(where: { access("\($0)/\(name)/theme.ini", F_OK) == 0 }),
          let text = ThemeLoader.readFile("\(dir)/\(name)/theme.ini") else {
        err("abyss-theme: no theme \(name) (looked in \(ThemeLoader.searchPath().joined(separator: ", ")))"); exit(1)
    }
    var bad = false
    let schemes = ((try? ThemeLoader.parse(text))?.schemes) ?? []
    for scheme in [nil] + schemes.map(Optional.some) {
        let label = scheme ?? "(base)"
        do {
            let t = try ThemeLoader.parse(text, scheme: scheme)
            let lo = Legibility.minimumBodyRatio(t.tokens)
            print("\(name) \(label): readable — lowest body contrast \((lo * 100).rounded() / 100):1"
                  + (t.warnings.isEmpty ? "" : "\n  " + t.warnings.joined(separator: "\n  ")))
        } catch let e as ThemeError {
            bad = true
            print("\(name) \(label): REFUSED\n  " + e.problems.joined(separator: "\n  "))
        } catch { bad = true; print("\(name) \(label): \(error)") }
    }
    exit(bad ? 1 : 0)
case "set":
    guard args.count == 2 || args.count == 3 else {
        err("usage: abyss-theme set NAME [SCHEME]"); exit(2)
    }
    let name = args[1], scheme = args.count == 3 ? args[2] : nil
    // Refuse what would not load, here, in words — rather than write it and
    // have every process on the desktop fall back to Jaguar at once.
    guard let dir = ThemeLoader.searchPath().first(where: { access("\($0)/\(name)/theme.ini", F_OK) == 0 }),
          let text = ThemeLoader.readFile("\(dir)/\(name)/theme.ini") else {
        err("abyss-theme: no theme \(name) (looked in \(ThemeLoader.searchPath().joined(separator: ", ")))"); exit(1)
    }
    do { _ = try ThemeLoader.parse(text, scheme: scheme) } catch let e as ThemeError {
        err("abyss-theme: \(name)\(scheme.map { " " + $0 } ?? "") would be refused:\n  "
            + e.problems.joined(separator: "\n  ")); exit(1)
    } catch { err("abyss-theme: \(error)"); exit(1) }
    do { try ThemeLoader.store(theme: name, scheme: scheme) } catch {
        err("abyss-theme: could not write appearance.ini: \(error)"); exit(1)
    }
default:
    err("usage: abyss-theme palette | abyss-theme check [NAME] | abyss-theme set NAME [SCHEME]")
    exit(2)
}
