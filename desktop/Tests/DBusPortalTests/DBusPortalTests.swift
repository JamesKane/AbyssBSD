// DBusPortal tests — the FileChooser rules, without a bus (PHASE8.md P8.2).
//
// The reference for every expectation here is a file on disk, not a memory:
// /usr/share/dbus-1/interfaces/org.freedesktop.portal.{FileChooser,Request}.xml,
// installed by xdg-desktop-portal. Where a test asserts a literal — the shape of
// a Request path, the name of a results key — that literal came from there.
//
// What is NOT here: "does a real GTK app get a file". That is
// `abyss/tests/live-portal-dbus.sh` (gdbus as the caller) and P8.3 (GTK itself).

import XCTest
@testable import DBusPortal
import CurrentIPC
import Aqua

final class DBusPortalTests: XCTestCase {

    // MARK: - The Request object's path

    /// The exact transformation the spec names: the leading `:` removed, every
    /// `.` replaced by `_`. It is written down because the *client* performs it
    /// too, on its own name, to decide where to subscribe before it calls. Any
    /// divergence between the two is not a wrong answer — it is a client that
    /// hangs for ever with no error at all.
    func testRequestPathIsDerivedTheWayTheSpecSays() {
        XCTAssertEqual(RequestHandle.path(sender: ":1.42", token: "gtk1"),
                       "/org/freedesktop/portal/desktop/request/1_42/gtk1")
        XCTAssertEqual(RequestHandle.path(sender: ":1.0", token: "t"),
                       "/org/freedesktop/portal/desktop/request/1_0/t")
        // Every dot, not just the first.
        XCTAssertEqual(RequestHandle.senderElement(":1.2.3"), "1_2_3")
    }

    /// `handle_token` "must be a valid object path element". A token with a `/`
    /// would silently relocate the Request in the tree — the client would
    /// subscribe to one path and we would emit on another — so it is refused
    /// rather than sanitised into something the client cannot predict.
    func testTokensThatWouldBreakTheObjectPathAreRefused() {
        XCTAssertNil(RequestHandle.path(sender: ":1.4", token: "a/b"))
        XCTAssertNil(RequestHandle.path(sender: ":1.4", token: "a-b"))
        XCTAssertNil(RequestHandle.path(sender: ":1.4", token: "a b"))
        XCTAssertNil(RequestHandle.path(sender: ":1.4", token: ""))
        XCTAssertNil(RequestHandle.path(sender: ":1.4", token: "café"))
        XCTAssertNotNil(RequestHandle.path(sender: ":1.4", token: "a_1B"))
    }

    /// A well-known name where a unique one belongs cannot make a path either —
    /// `org.gtk.App` would become `org_gtk_App`, which is a *valid* element and
    /// therefore the dangerous case: it succeeds, and points at a path the
    /// caller is not listening on. The bus only ever sets `sender` to a unique
    /// name, so this is defence in depth rather than a reachable bug.
    func testSenderWithDotsButNoColonStillProducesOneElement() {
        XCTAssertEqual(RequestHandle.senderElement("org.gtk.App"), "org_gtk_App")
        XCTAssertNil(RequestHandle.senderElement("org.gtk.App-2"))
    }

    // MARK: - file:// URIs

    /// The results key is `uris`, and the spec says "All URIs have the `file://`
    /// scheme". A path with a space in it is the ordinary case, not the exotic
    /// one, and an unescaped space makes a URI a client's parser rejects.
    func testPathsBecomeProperlyEscapedFileURIs() {
        XCTAssertEqual(FileURI.encode("/home/jkane/notes.txt"),
                       "file:///home/jkane/notes.txt")
        XCTAssertEqual(FileURI.encode("/home/jkane/My Documents/a b.txt"),
                       "file:///home/jkane/My%20Documents/a%20b.txt")
        // Slashes are structure and must survive; `?` and `#` would otherwise
        // turn the rest of the path into a query or a fragment.
        XCTAssertEqual(FileURI.encode("/a/b?c#d"), "file:///a/b%3Fc%23d")
        // And a percent sign in a filename must not be readable as an escape.
        XCTAssertEqual(FileURI.encode("/a/100%.txt"), "file:///a/100%25.txt")
    }

    /// Encoding is per UTF-8 *byte*, not per character. Encoding per character
    /// produces something no decoder recovers the original bytes from — and a
    /// desktop that cannot open `~/Bücher` is broken for most of the world.
    func testNonASCIIPathsAreEncodedByteWise() {
        XCTAssertEqual(FileURI.encode("/home/j/Bücher"), "file:///home/j/B%C3%BCcher")
        XCTAssertEqual(FileURI.decode(FileURI.encode("/home/j/Bücher")), "/home/j/Bücher")
        XCTAssertEqual(FileURI.decode(FileURI.encode("/a b/c%d?e")), "/a b/c%d?e")
    }

    // MARK: - The options vardict

    /// `current_folder` is `ay` — a byte array "expected to be terminated by a
    /// nul byte" — not a string. The NUL is part of the value on the wire and
    /// must come off; leave it and the path handed to the picker ends in a NUL
    /// byte, which nothing on disk is named.
    func testCurrentFolderIsAByteArrayAndItsTrailingNULComesOff() {
        let folder = DBusValue.array("y", Array("/tmp/docs".utf8).map { .byte($0) } + [.byte(0)])
        let opts = ChooserOptions(.options([("current_folder", folder)]))
        XCTAssertEqual(opts.currentFolder, "/tmp/docs")
    }

    /// A relative folder is dropped rather than forwarded, for the same reason
    /// `PortalRequest.sanitise` drops one: it would resolve against a working
    /// directory the requesting app has no business pointing the picker at.
    func testARelativeCurrentFolderIsNotForwarded() {
        let rel = DBusValue.array("y", Array("../../etc".utf8).map { .byte($0) } + [.byte(0)])
        XCTAssertNil(ChooserOptions(.options([("current_folder", rel)])).currentFolder)
        // A `current_folder` sent as a string rather than `ay` is a client bug;
        // it is ignored, not obeyed.
        XCTAssertNil(ChooserOptions(.options([("current_folder", .string("/tmp"))])).currentFolder)
    }

    /// Options we act on, options we ignore, and the fact that ignoring is
    /// *recorded*: "the picker ignored my filter" should be answerable from the
    /// journal rather than by reading this file.
    func testOptionsWeUnderstandAndOptionsWeMerelyTolerate() {
        let filters = DBusValue.array("(sa(us))", [
            .structure([.string("Text"), .array("(us)", [.structure([.uint32(0), .string("*.txt")])])])
        ])
        let opts = ChooserOptions(.options([
            ("handle_token", .string("gtk7")),
            ("multiple", .bool(true)),
            ("modal", .bool(true)),
            ("accept_label", .string("_Open")),
            ("filters", filters),
        ]))
        XCTAssertEqual(opts.handleToken, "gtk7")
        XCTAssertTrue(opts.multiple)
        XCTAssertFalse(opts.directory)
        XCTAssertEqual(opts.ignored.sorted(), ["accept_label", "filters", "modal"])
    }

    /// An empty vardict is what `gdbus call … "{}"` sends, and what a minimal
    /// client sends. It must parse to defaults, not throw.
    func testAnEmptyOptionsDictionaryIsFine() {
        let opts = ChooserOptions(.options([]))
        XCTAssertNil(opts.handleToken)
        XCTAssertNil(opts.currentFolder)
        XCTAssertTrue(opts.ignored.isEmpty)
    }

    // MARK: - Translating to `abyss-portal`

    /// The confused-deputy rule, checked at the bridge as well as at the portal:
    /// **no option can become "the path to open"**. `current_folder` becomes a
    /// directory hint and `current_name` a save-dialog suggestion; there is no
    /// input that produces anything else, because `Msg` gets only those keys.
    func testTheBridgeCannotBeTalkedIntoNamingAFile() {
        let folder = DBusValue.array("y", Array("/tmp/docs".utf8).map { .byte($0) } + [.byte(0)])
        let open = portalCallMessage(kind: .open,
                                     options: ChooserOptions(.options([
                                        ("current_folder", folder),
                                        ("current_name", .string("secret.txt")),
                                        ("current_file", folder)])))
        XCTAssertEqual(open.string("method"), "file.open")
        XCTAssertEqual(open.string("dir"), "/tmp/docs")
        // `current_name` is a *save* suggestion; an open request carries none,
        // and `current_file` — which does name a file — is never forwarded.
        XCTAssertNil(open.string("name"))
        XCTAssertNil(open.string("path"))
        XCTAssertFalse(open.has("file"))

        let save = portalCallMessage(kind: .save,
                                     options: ChooserOptions(.options([
                                        ("current_name", .string("Untitled.txt"))])))
        XCTAssertEqual(save.string("method"), "file.save")
        XCTAssertEqual(save.string("name"), "Untitled.txt")
    }

    // MARK: - The Response

    /// The three codes, and why telling 1 from 2 matters: a client that reads a
    /// cancel as an error shows a failure dialog every time somebody changes
    /// their mind about which file they wanted.
    func testCancelIsNotAnError() {
        var cancelled = Msg()
        cancelled.set("ok", false)
        cancelled.set("error", "cancelled")
        XCTAssertEqual(chooserResponse(reply: cancelled).0, .cancelled)

        var broke = Msg()
        broke.set("ok", false)
        broke.set("error", "the picker exited 3")
        XCTAssertEqual(chooserResponse(reply: broke).0, .other)
    }

    /// A success carries the URI of what the user picked — and a reply claiming
    /// success with no path is a *failure*, not a success with an empty list. A
    /// client handed `uris: []` opens nothing and reports nothing wrong.
    func testASuccessWithoutAPathIsNotASuccess() {
        var good = Msg()
        good.set("ok", true)
        good.set("path", "/tmp/docs/Chosen file.txt")
        let (code, results) = chooserResponse(reply: good)
        XCTAssertEqual(code, .success)
        XCTAssertEqual(results, .options([("uris", .array("s", [
            .string("file:///tmp/docs/Chosen%20file.txt")]))]))

        var empty = Msg()
        empty.set("ok", true)
        XCTAssertEqual(chooserResponse(reply: empty).0, .other)

        // A relative path from the portal is equally not an answer.
        var relative = Msg()
        relative.set("ok", true)
        relative.set("path", "docs/x.txt")
        XCTAssertEqual(chooserResponse(reply: relative).0, .other)
    }

    /// The results vardict marshals as `a{sv}` with `uris` as `as`, because that
    /// is the signature the spec publishes and the one a client's generated
    /// binding will demand.
    func testResultsHaveTheSignatureTheSpecPublishes() {
        let results = chooserResults(paths: ["/a/b.txt"])
        XCTAssertEqual(results.signature, "a{sv}")
        guard case .array(_, let entries) = results,
              case .dictEntry(.string(let key), .variant(let value))? = entries.first else {
            return XCTFail("results are not a vardict")
        }
        XCTAssertEqual(key, "uris")
        XCTAssertEqual(value.signature, "as")
    }

    // MARK: - Introspection walking

    /// A client walking down from `/` must be led to the portal rather than told
    /// the bus name is empty.
    func testIntrospectionPointsTheWayDownFromTheRoot() {
        let target = portalObjectPath
        XCTAssertEqual(DBusPortalService.nextComponent(towards: target, from: "/"), "org")
        XCTAssertEqual(DBusPortalService.nextComponent(towards: target, from: "/org"),
                       "freedesktop")
        XCTAssertEqual(DBusPortalService.nextComponent(towards: target,
                                                       from: "/org/freedesktop/portal"),
                       "desktop")
        XCTAssertNil(DBusPortalService.nextComponent(towards: target, from: target))
        XCTAssertNil(DBusPortalService.nextComponent(towards: target, from: "/net"))
    }

    // MARK: - Settings (P8.3)

    /// The glob rule, copied from the spec rather than guessed: trailing `*`
    /// only, prefix-matched on the text before it; an empty list or any empty
    /// string matches everything.
    ///
    /// The case worth pinning is the last one. `org.gnome.*` does **not** match
    /// the bare namespace `org.gnome`, because the `.` is part of the prefix. A
    /// looser rule would have us answering for namespaces the client never asked
    /// about, which is the sort of over-helpfulness that only shows up as a
    /// toolkit applying a setting nobody made.
    func testNamespaceGlobbingIsTrailingOnly() {
        XCTAssertTrue(PortalSettings.matches(namespace: "org.gnome.desktop.interface",
                                             patterns: ["org.gnome.*"]))
        XCTAssertTrue(PortalSettings.matches(namespace: "org.freedesktop.appearance",
                                             patterns: ["org.freedesktop.appearance"]))
        XCTAssertTrue(PortalSettings.matches(namespace: "anything", patterns: []))
        XCTAssertTrue(PortalSettings.matches(namespace: "anything", patterns: ["a.b", ""]))
        XCTAssertFalse(PortalSettings.matches(namespace: "org.kde.stuff",
                                              patterns: ["org.gnome.*"]))
        XCTAssertFalse(PortalSettings.matches(namespace: "org.gnome",
                                              patterns: ["org.gnome.*"]))
    }

    /// `ReadAll` must SUCCEED with an empty dictionary for namespaces we do not
    /// publish. This is the whole reason the interface exists here: GTK asks for
    /// `org.gnome.*`, we are not GNOME and have nothing to say, and the
    /// difference between "no settings" and "no such method" is the difference
    /// between an app that starts quietly and one that warns on every launch.
    func testReadAllAnswersEmptyForNamespacesWeDoNotPublish() {
        let all = PortalSettings.aqua.readAll(patterns: ["org.gnome.*"])
        XCTAssertEqual(all.signature, "a{sa{sv}}")
        guard case .array(_, let entries) = all else { return XCTFail("not a dict") }
        XCTAssertTrue(entries.isEmpty)
    }

    /// And it must carry the standardised namespace when that is what was asked
    /// for — including through the glob a real client sends.
    func testReadAllCarriesTheAppearanceNamespace() {
        for patterns in [[], [""], ["org.freedesktop.*"], [PortalSettings.appearance]] {
            let all = PortalSettings.aqua.readAll(patterns: patterns)
            guard case .array(_, let entries) = all,
                  case .dictEntry(.string(let ns), let keys)? = entries.first else {
                return XCTFail("no namespace for \(patterns)")
            }
            XCTAssertEqual(ns, PortalSettings.appearance)
            XCTAssertEqual(keys.signature, "a{sv}")
        }
    }

    /// **`Read` returns two layers of variant and `ReadOne` returns one**, and
    /// that asymmetry is not ours. The interface XML says the single layer was
    /// intended, the double layer is what shipped, and callers now parse the
    /// double — so reproducing the mistake is the correct implementation. Get it
    /// wrong and the client decodes a variant, finds a `u` where it expected
    /// another variant, and gives up without a diagnostic.
    func testReadIsDoubleWrappedAndReadOneIsNot() {
        let one = PortalSettings.aqua.readOne(namespace: PortalSettings.appearance,
                                              key: "color-scheme")
        XCTAssertEqual(one, .variant(.uint32(2)))

        let two = PortalSettings.aqua.read(namespace: PortalSettings.appearance,
                                           key: "color-scheme")
        XCTAssertEqual(two, .variant(.variant(.uint32(2))))
    }

    /// An unknown key is an error, not a default. The spec requires it, and a
    /// made-up value is indistinguishable from a real one by the time it reaches
    /// a toolkit.
    func testAnUnknownSettingIsNotInvented() {
        XCTAssertNil(PortalSettings.aqua.readOne(namespace: PortalSettings.appearance,
                                                 key: "no-such-key"))
        XCTAssertNil(PortalSettings.aqua.readOne(namespace: "org.gnome.desktop.interface",
                                                 key: "font-name"))
    }

    /// Aqua is a light theme with no dark variant, so "prefer light" (2) is the
    /// true answer rather than the polite one. Reporting 0 — no preference —
    /// gets GTK's own default, which on some distributions is dark: a dark GTK
    /// dialog on a Jaguar desktop.
    func testTheDesktopReportsThePreferenceItActuallyHas() {
        XCTAssertEqual(PortalSettings.aqua.value(namespace: PortalSettings.appearance,
                                                 key: "color-scheme"), .uint32(2))
    }

    /// The accent colour is `(ddd)` in the sRGB range [0,1] — out-of-range values
    /// are defined to mean "unset", so a component accidentally left at 0–255
    /// would silently turn the accent colour off rather than fail loudly.
    func testTheAccentColourIsThreeDoublesInRange() {
        guard case .structure(let parts)? =
                PortalSettings.aqua.value(namespace: PortalSettings.appearance,
                                          key: "accent-color") else {
            return XCTFail("no accent colour")
        }
        XCTAssertEqual(parts.count, 3)
        for part in parts {
            guard case .double(let c) = part else { return XCTFail("not a double") }
            XCTAssertTrue((0...1).contains(c), "\(c) is outside sRGB [0,1]")
        }
    }

    /// …and it is the colour the desktop actually selects things with.
    ///
    /// `DBusPortal` deliberately does not import the toolkit — linking cairo,
    /// FreeType and HarfBuzz into a D-Bus bridge to name one colour would be a
    /// bad trade — so the accent is three literals in `Settings.swift`. This is
    /// what stops them drifting: change `Theme.menuHighlight` and the desktop
    /// would otherwise keep telling foreign apps the old colour, and nothing
    /// would ever say so.
    func testAccentColourMatchesTheAquaTheme() {
        guard case .structure(let parts)? =
                PortalSettings.aqua.value(namespace: PortalSettings.appearance,
                                          key: "accent-color") else {
            return XCTFail("no accent colour")
        }
        let want = Theme.menuHighlight
        let got = parts.compactMap { part -> Double? in
            guard case .double(let c) = part else { return nil }
            return c
        }
        XCTAssertEqual(got, [want.r, want.g, want.b],
                       "the Settings accent colour has drifted from Theme.menuHighlight")
    }
}
