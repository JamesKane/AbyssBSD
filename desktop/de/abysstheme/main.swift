// abyss-theme — the loaded theme, for things that do not draw (P11.10).
//
//   abyss-theme palette       the palette the portal publishes (INI, stdout)
//   abyss-theme check [NAME]  every scheme of a theme against the legibility
//                             floor, in words (a theme author's tool)
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
default:
    err("usage: abyss-theme palette | abyss-theme check [NAME]")
    exit(2)
}
