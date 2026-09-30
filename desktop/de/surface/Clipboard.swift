// The clipboard, client side (PHASE9.md P9.1).
//
// **`Surface` had no data device at all**, so no application in this tree could
// copy or paste — and the compositor was discarding every offer anyway, so
// neither could anybody else's. The Finder's ⌘C/⌘X/⌘V have worked since P2.6c
// against `FinderApp.clipboard`, a field: copy in one Finder window, paste in
// another, and nothing crosses a process boundary. This is the wire under it.
//
// `wl_data_device` is core wayland — no protocol XML, no scanner line — but its
// requests are static inlines, so they arrive through `aw_*` (§2.1), and **every
// listener slot is filled** (§2.3): a nil in one of these is a crash the first
// time a compositor exercises it, and the drag events fire on any desktop where
// somebody drags a file over your window whether you asked for drag or not.
//
// The transfer itself is a pipe. That is the part worth reading twice: a
// selection is not data the compositor holds, it is a *promise by the source
// client* to write bytes into a descriptor when somebody asks. So a paste is
// "make a pipe, hand one end to the owner, read the other" — and if the owner
// has exited, the read simply ends.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What a selection is offered as. Two, because they are the two every other
/// desktop agrees on and a file manager needs both: a URI list is what another
/// file manager understands, plain text is what everything else does.
public enum ClipboardMIME {
    public static let text = "text/plain;charset=utf-8"
    public static let uriList = "text/uri-list"
    /// What we advertise, in preference order.
    public static let offered = [uriList, text]
}

/// The client half of the clipboard.
public final class Clipboard {
    private let manager: OpaquePointer
    private let device: OpaquePointer
    private unowned let display: Display

    /// The offer the compositor last told us is the selection, if any.
    private var currentOffer: OpaquePointer?
    /// MIME types that offer advertised.
    private var offeredTypes: [String] = []
    /// Types from the most recent offer, before we know whether it is a
    /// selection or a drag.
    private var pendingOfferTypes: [String] = []
    /// What we ourselves put on the clipboard, kept alive to answer `send`.
    private var ownedBytes: [UInt8] = []
    private var ownedSource: OpaquePointer?
    /// The source and bytes of a drag we started. Separate from the clipboard's,
    /// because dragging must not silently replace what somebody copied.
    private var dragSource: OpaquePointer?
    private var dragBytes: [UInt8] = []

    // ---- a drag passing over us
    /// The offer the pointer is currently carrying over one of our surfaces.
    private var dragOffer: OpaquePointer?
    /// Types that offer advertises.
    private var dragTypes: [String] = []
    /// Where the pointer is, in surface coordinates — the drop target needs it.
    public private(set) var dragX = 0.0
    public private(set) var dragY = 0.0
    /// **Which of our surfaces the drag is over.** A client with more than one
    /// window cannot answer that from pointer focus: a drag is a *grab*, so the
    /// pointer events stop for its duration and the last one we saw is from
    /// before the drag began — usually the window the drag started in. The
    /// `enter` event carries the surface, and it is the only thing that does.
    public private(set) var dragSurface: OpaquePointer?
    /// What this application is willing to receive. Empty means "nothing", and
    /// the person is told so by the cursor rather than by a drop that does
    /// nothing.
    public var acceptedDragTypes: [String] = []
    /// Called when something is dropped on us: the bytes and where.
    public var onDrop: ((_ mime: String, _ bytes: [UInt8], _ x: Double, _ y: Double) -> Void)?
    /// Called as a drag moves across us, and when it leaves. A target that
    /// cannot show where the drop would land is one the person drops on by
    /// guess, so this exists for the highlight and not for the data.
    public var onDragMotion: ((_ x: Double, _ y: Double) -> Void)?
    public var onDragLeave: (() -> Void)?

    /// Boxes handed to C as listener `data`. Kept so they outlive the callbacks.
    private var boxes: [UnsafeMutableRawPointer] = []

    /// Whether the current selection is one we ourselves offered.
    ///
    /// **This is what stops a program deadlocking on its own clipboard.** A
    /// selection is a promise by the source to write into a descriptor when
    /// asked — so reading a selection *we* own means asking ourselves, from a
    /// thread that is about to block on the read, for a `send` event that only
    /// the event loop we just stopped servicing could deliver. The process hangs
    /// with nothing in any log.
    ///
    /// Found by `fileops`: copy and paste in one Finder window, which is the
    /// first thing anybody does with a clipboard and the one case the
    /// two-process test could not reach.
    public private(set) var ownsSelection = false

    init?(display: Display, manager: OpaquePointer, seat: OpaquePointer) {
        guard let d = opt(aw_data_device_manager_get_data_device(raw(manager), raw(seat)))
        else { return nil }
        self.display = display
        self.manager = manager
        self.device = d

        let me = Unmanaged.passUnretained(self).toOpaque()
        var dl = wl_data_device_listener()
        // A new offer object: the compositor is about to tell us what it holds.
        dl.data_offer = { data, _, offer in
            guard let data, let offer else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            c.beginOffer(offer)
        }
        // The selection changed — `nil` means the clipboard is now empty, which
        // is a real state and not an error.
        dl.selection = { data, _, offer in
            guard let data else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            c.adoptSelection(offer)
        }
        // **Drag and drop (P9.3).** These four were filled with empty bodies in
        // P9.1 because they fire whenever anything is dragged over one of our
        // surfaces whether or not we implement drag, and a nil function pointer
        // there is a crash in libwayland's dispatch (§2.3). Now they do the job.
        dl.enter = { data, _, serial, surface, x, y, offer in
            guard let data else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            c.dragOffer = offer
            c.dragTypes = c.pendingOfferTypes
            c.dragSurface = surface
            c.dragX = wl_fixed_to_double(x)
            c.dragY = wl_fixed_to_double(y)
            c.onDragMotion?(c.dragX, c.dragY)
            guard let offer else { return }
            // **Accepting is what makes the source's cursor say "yes".** A
            // destination that stays silent is one the person is told they may
            // not drop on, so this has to happen on enter and not on drop.
            let mime = c.dragTypes.first { c.acceptedDragTypes.contains($0) }
            if let mime { aw_data_offer_accept(raw(offer), serial, mime) }
            else { aw_data_offer_accept(raw(offer), serial, nil) }
            // Copy, always: a file manager dragging within one desktop means
            // copy unless it says otherwise, and `move` is a decision P9.4 and
            // the Finder's own cut semantics own rather than the protocol.
            aw_data_offer_set_actions(raw(offer), 1, 1)   // COPY, COPY
        }
        dl.leave = { data, _ in
            guard let data else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            c.releaseDrag()
        }
        dl.motion = { data, _, _, x, y in
            guard let data else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            c.dragX = wl_fixed_to_double(x)
            c.dragY = wl_fixed_to_double(y)
            c.onDragMotion?(c.dragX, c.dragY)
        }
        dl.drop = { data, _ in
            guard let data else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            c.completeDrop()
        }
        display.addListener(to: d, listener: dl, data: me)
    }

    deinit {
        if let s = ownedSource { aw_data_source_destroy(raw(s)) }
        if let o = currentOffer { aw_data_offer_destroy(raw(o)) }
        for b in boxes { b.deallocate() }
    }

    // MARK: - Reading what somebody else copied

    private func beginOffer(_ offer: OpaquePointer) {
        // The types arrive as a burst of `offer` events on the offer object
        // itself, before the `selection` event that hands it over.
        offeredTypes = []
        pendingOfferTypes = []
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ol = wl_data_offer_listener()
        ol.offer = { data, offer, mime in
            guard let data, let mime else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            let s = String(cString: mime)
            // One listener, two uses: the same object carries a clipboard
            // selection and a drag, and which it is depends on whether `enter`
            // or `selection` claims it afterwards. Recording both is simpler and
            // cheaper than guessing early.
            c.offeredTypes.append(s)
            c.pendingOfferTypes.append(s)
            _ = offer
        }
        ol.source_actions = { _, _, _ in }
        ol.action = { _, _, _ in }
        display.addListener(to: offer, listener: ol, data: me)
    }

    private func adoptSelection(_ offer: OpaquePointer?) {
        if let old = currentOffer, old != offer { aw_data_offer_destroy(raw(old)) }
        currentOffer = offer
        if offer == nil { offeredTypes = [] }
        // A selection arriving while we still hold a live source is ours: the
        // compositor echoes it back to the owner like any other focused client.
        // When somebody else copies, our source is cancelled first, so this is
        // already false by the time their selection lands.
        ownsSelection = ownedSource != nil
    }

    /// Whether the clipboard holds something in one of `types` — without
    /// reading it. For a menu deciding whether Paste is enabled (PHASE10 P10.1),
    /// which must not cost a pipe and a round trip to the source every time.
    /// True for our own selection too; the caller knows what it put there.
    public func offers(_ types: [String] = ClipboardMIME.offered) -> Bool {
        if ownsSelection { return true }
        guard currentOffer != nil else { return false }
        return types.contains { offeredTypes.contains($0) }
    }

    /// What the clipboard currently holds, or nil if it holds nothing we can read.
    ///
    /// **Blocking, deliberately.** The source writes when it gets round to it,
    /// and a caller asking for the clipboard wants the bytes rather than a
    /// promise — this is a menu command, not the frame path. The read ends when
    /// the source closes its end, including when the source has already exited.
    public func read(preferring types: [String] = ClipboardMIME.offered) -> (mime: String, bytes: [UInt8])? {
        // **Never read our own selection.** See `ownsSelection`: the answer
        // would have to come from this process, which is the one blocking. A
        // caller that put the bytes there already has them, so nil here is not
        // a loss — it is the caller being sent back to what it already knows.
        guard !ownsSelection else { return nil }
        guard let offer = currentOffer else { return nil }
        guard let mime = types.first(where: { offeredTypes.contains($0) })
                ?? offeredTypes.first
        else { return nil }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        aw_data_offer_receive(raw(offer), mime, fds[1])
        // **Flush before reading, and close our copy of the write end.** The
        // request is buffered in libwayland: without the flush the source never
        // hears the ask, and without the close the read never sees EOF because
        // *we* are still holding a writer. Either mistake is an indefinite hang
        // with nothing in any log.
        display.flush()
        close(fds[1])

        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Glibc.read(fds[0], $0.baseAddress, 4096) }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        close(fds[0])
        return (mime, out)
    }

    private func releaseDrag() {
        if let o = dragOffer { aw_data_offer_destroy(raw(o)) }
        dragOffer = nil
        dragTypes = []
        dragSurface = nil
        onDragLeave?()
    }

    private func completeDrop() {
        guard let offer = dragOffer, let cb = onDrop else { releaseDrag(); return }
        guard let mime = dragTypes.first(where: { acceptedDragTypes.contains($0) })
        else { releaseDrag(); return }

        // **A drag that ends where it started is one process asking itself.**
        // The bytes are already here, and going through the pipe would ask this
        // process for a `wl_data_source.send` that only the event loop we are
        // about to block in could deliver — the identical deadlock to reading a
        // selection we own (`ownsSelection`), reached the identical way: by
        // dragging a file from one window to another window of the same
        // application, which is the first thing anybody does with drag and drop.
        //
        // The offer is still finished properly, so the source sees a completed
        // drag rather than a cancelled one.
        if dragSource != nil {
            aw_data_offer_finish(raw(offer))
            display.flush()
            cb(mime, dragBytes, dragX, dragY)
            releaseDrag()
            return
        }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { releaseDrag(); return }
        aw_data_offer_receive(raw(offer), mime, fds[1])
        display.flush()
        close(fds[1])
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Glibc.read(fds[0], $0.baseAddress, 4096) }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        close(fds[0])
        // **`finish` before destroy, and only after reading.** It tells the
        // source the transfer is done so it can release its side; sending it
        // early ends the drag while we are still reading from it.
        aw_data_offer_finish(raw(offer))
        display.flush()
        cb(mime, out, dragX, dragY)
        releaseDrag()
    }

    // MARK: - Starting a drag

    /// Begin dragging `bytes` from `origin`.
    ///
    /// The serial must be from the **pointer press** that started the drag —
    /// wlroots checks it with `validate_pointer_grab_serial`, which is what
    /// stops a program starting a drag nobody initiated and harvesting whatever
    /// the cursor passes over.
    @discardableResult
    public func startDrag(_ bytes: [UInt8], from origin: OpaquePointer,
                          serial: UInt32,
                          types: [String] = ClipboardMIME.offered) -> Bool {
        guard let source = opt(aw_data_device_manager_create_data_source(raw(manager)))
        else { return false }
        dragBytes = bytes
        if let old = dragSource { aw_data_source_destroy(raw(old)) }
        dragSource = source

        let me = Unmanaged.passUnretained(self).toOpaque()
        var sl = wl_data_source_listener()
        sl.send = { data, _, mime, fd in
            guard let data else { close(fd); return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            _ = mime
            c.dragBytes.withUnsafeBufferPointer { b in
                var off = 0
                while off < b.count {
                    let n = Glibc.write(fd, b.baseAddress! + off, b.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            close(fd)
        }
        sl.cancelled = { data, source in
            guard let data, let source else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            guard let mine = c.dragSource,
                  UnsafeRawPointer(mine) == UnsafeRawPointer(source) else { return }
            aw_data_source_destroy(UnsafeMutableRawPointer(mine))
            c.dragSource = nil
        }
        sl.target = { _, _, _ in }
        sl.dnd_drop_performed = { _, _ in }
        sl.dnd_finished = { data, source in
            guard let data, let source else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            guard let mine = c.dragSource,
                  UnsafeRawPointer(mine) == UnsafeRawPointer(source) else { return }
            aw_data_source_destroy(UnsafeMutableRawPointer(mine))
            c.dragSource = nil
        }
        sl.action = { _, _, _ in }
        display.addListener(to: source, listener: sl, data: me)

        for t in types { aw_data_source_offer(raw(source), t) }
        aw_data_source_set_actions(raw(source), 1)     // COPY
        // No icon surface: the compositor draws nothing extra and the cursor is
        // the feedback. A real icon is a surface per drag, which is Phase 11's
        // business once the toolkit can render one out of band.
        aw_data_device_start_drag(raw(device), raw(source), raw(origin), nil, serial)
        display.flush()
        return true
    }

    // MARK: - Putting something on it

    /// Offer `bytes` to the rest of the desktop under `types`.
    ///
    /// The serial has to be one the compositor gave us — wlroots checks it, and
    /// that check is what stops a client setting the clipboard from an input it
    /// never received.
    @discardableResult
    public func write(_ bytes: [UInt8], types: [String] = ClipboardMIME.offered) -> Bool {
        guard let source = opt(aw_data_device_manager_create_data_source(raw(manager)))
        else { return false }
        if let old = ownedSource { aw_data_source_destroy(raw(old)) }
        ownedSource = source
        ownedBytes = bytes
        ownsSelection = true

        let me = Unmanaged.passUnretained(self).toOpaque()
        var sl = wl_data_source_listener()
        sl.send = { data, _, mime, fd in
            guard let data else { close(fd); return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            _ = mime      // we offer the same bytes under every type we advertise
            c.ownedBytes.withUnsafeBufferPointer { b in
                var off = 0
                while off < b.count {
                    let n = Glibc.write(fd, b.baseAddress! + off, b.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
            // **Closing is the end of the message.** A reader waits for EOF, so
            // a source that writes and does not close is a paste that hangs.
            close(fd)
        }
        // The clipboard moved to somebody else. Our bytes are no longer wanted.
        sl.cancelled = { data, source in
            guard let data, let source else { return }
            let c = Unmanaged<Clipboard>.fromOpaque(data).takeUnretainedValue()
            // Compare as raw pointers: `cancelled` can arrive for a source we
            // have already replaced, and destroying the *current* one because an
            // old one was cancelled would clear a clipboard somebody just set.
            guard let mine = c.ownedSource,
                  UnsafeRawPointer(mine) == UnsafeRawPointer(source) else { return }
            aw_data_source_destroy(UnsafeMutableRawPointer(mine))
            c.ownedSource = nil
            c.ownedBytes = []
            c.ownsSelection = false
        }
        // Drag-and-drop's half of this interface (P9.3), filled for §2.3's reason.
        sl.target = { _, _, _ in }
        sl.dnd_drop_performed = { _, _ in }
        sl.dnd_finished = { _, _ in }
        sl.action = { _, _, _ in }
        display.addListener(to: source, listener: sl, data: me)

        for t in types { aw_data_source_offer(raw(source), t) }
        aw_data_device_set_selection(raw(device), raw(source), display.lastInputSerial)
        display.flush()
        return true
    }

    /// Convenience for the common case.
    @discardableResult
    public func writeText(_ s: String) -> Bool { write(Array(s.utf8)) }
    public func readText() -> String? {
        guard let r = read() else { return nil }
        return String(decoding: r.bytes, as: UTF8.self)
    }
}
