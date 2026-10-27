import UIKit

/// Wraps the navigator view controller so custom text-selection editing
/// actions have a home in the responder chain. `EditingAction` dispatches
/// `UIApplication.sendAction(_:to:nil)` which walks first-responder → view →
/// view controllers up — this container is the navigator's parent, so its
/// selectors are reachable.
final class ReaderContainerViewController: UIViewController {
    var onHighlightSelection: (() -> Void)?
    var onQuoteSelection: (() -> Void)?
    var onSaveWordSelection: (() -> Void)?

    private let contentController: UIViewController

    init(contentController: UIViewController) {
        self.contentController = contentController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(contentController)
        contentController.view.frame = view.bounds
        contentController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentController.view)
        contentController.didMove(toParent: self)
        curlPan.delegate = self
        view.addGestureRecognizer(curlPan)
    }

    // MARK: Turning the page

    private var turning: UIView?
    private static let turnDuration: CFTimeInterval = 0.55

    /// Lay the page as it is over the navigator and turn it away, while the navigator moves on to the next
    /// beneath it. `towardLeft`: the page leaves to the left (a tap on the right edge turns forward).
    /// `frozenAt` holds the turn part way (0...1), for the simulator's photographs.
    func beginTurn(towardLeft: Bool, style: PageTurnStyle, frozenAt: Double? = nil) {
        guard style != .slide else { return }
        turning?.removeFromSuperview()
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }

        let holder = UIView(frame: bounds)
        holder.isUserInteractionEnabled = false
        let shade = UIView(frame: bounds)       // the page beneath, in the turning page's shadow
        shade.backgroundColor = .black
        shade.alpha = 0
        let page = UIImageView(image: image)
        page.frame = bounds
        page.clipsToBounds = true
        let veil = UIView(frame: bounds)        // the turning page darkens as it goes edge-on
        veil.backgroundColor = .black
        veil.alpha = 0
        page.addSubview(veil)
        holder.addSubview(shade)
        holder.addSubview(page)
        view.addSubview(holder)
        turning = holder

        // a photograph of the turn part way: the page drawn at that angle, no animation to pause
        if let frozenAt, style == .flip {
            let progress = CGFloat(min(max(frozenAt, 0), 1))
            let hinge: CGFloat = towardLeft ? 0 : 1
            page.layer.anchorPoint = CGPoint(x: hinge, y: 0.5)
            page.layer.position = CGPoint(x: bounds.width * hinge, y: bounds.midY)
            var start = CATransform3DIdentity
            start.m34 = -1 / 1400
            page.layer.transform = CATransform3DRotate(start, (towardLeft ? -1 : 1) * .pi / 2 * progress, 0, 1, 0)
            veil.alpha = 0.55 * progress
            shade.alpha = 0.38
            return
        }

        let d = style == .flip ? Self.turnDuration : 0.3
        let ease = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.2, 1)
        func animation(_ key: String, from: Any, to: Any) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = d
            a.timingFunction = ease
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            return a
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak holder, weak self] in
            holder?.removeFromSuperview()
            if self?.turning === holder { self?.turning = nil }
        }
        switch style {
        case .flip:
            let hinge: CGFloat = towardLeft ? 0 : 1
            page.layer.anchorPoint = CGPoint(x: hinge, y: 0.5)
            page.layer.position = CGPoint(x: bounds.width * hinge, y: bounds.midY)
            var start = CATransform3DIdentity
            start.m34 = -1 / 1400
            let end = CATransform3DRotate(start, (towardLeft ? -1 : 1) * .pi / 2, 0, 1, 0)
            page.layer.add(animation("transform", from: start, to: end), forKey: "turn")
            veil.layer.add(animation("opacity", from: 0, to: 0.55), forKey: "veil")
            let shadow = CAKeyframeAnimation(keyPath: "opacity")
            shadow.values = [0, 0.38, 0.0]
            shadow.keyTimes = [0, 0.45, 1]
            shadow.duration = d
            shadow.fillMode = .both
            shadow.isRemovedOnCompletion = false
            shade.layer.add(shadow, forKey: "shadow")
        case .fade, .slide, .curl:   // a curl that reaches here falls back to a fade
            page.layer.add(animation("opacity", from: 1, to: 0), forKey: "fade")
        }
        CATransaction.commit()
    }

    /// "Highlight" item in the text-selection menu — the current selection is
    /// read off the navigator when this fires.
    @objc func highlightSelection() {
        onHighlightSelection?()
    }

    /// "Quote" item — sends the selection to BookMaster as a quote.
    @objc func quoteSelection() {
        onQuoteSelection?()
    }

    /// "Save Word" item — keeps the selected word, with its line, in the book's word list.
    @objc func saveWordSelection() {
        onSaveWordSelection?()
    }

    // MARK: Page curl — the leaf that follows the finger

    /// Wired by ReaderModel: whether a drag from the page's edge may peel the
    /// leaf (curl style, paged — never while the book scrolls), how the
    /// navigator silently moves beneath the overlay, and how a gesture ends.
    var canCurl: (() -> Bool)?
    /// `true` = next page, `false` = previous: silently moves the navigator
    /// (position saves and sync are held until the turn settles). False result
    /// = no page that way.
    var onCurlStep: ((Bool) async -> Bool)?
    var onCurlCommit: (() -> Void)?
    var onCurlCancel: (() async -> Void)?
    /// RTL books peel the other way — set once the navigator exists.
    var rightToLeft = false

    private lazy var curlPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(curlDragged(_:)))
        pan.maximumNumberOfTouches = 1
        return pan
    }()
    private var curlOverlay: PageCurlOverlay?
    /// Where the finger caught the leaf, and which way the turn goes.
    private var curlGrab: (origin: CGPoint, forward: Bool)?
    /// While the silent move is being prepared the finger keeps moving — the
    /// newest position is what the overlay shows once it exists.
    private var curlPendingTouch: CGPoint?
    private var arming = false
    /// The navigator is being moved beneath the cover: the leaf stays flat until it has, and a finger let go
    /// meanwhile waits for it.
    private var armTask: Task<Void, Never>?
    /// The finger has let go: the release animation owns the leaf from here.
    private var releasing = false
    /// What the cover shows, as a small photograph: the page the turn leaves, and the one to put back on a cancel.
    private var coverPrint: [UInt8] = []
    /// Bumped each time a curl ends or starts — an `armCurl` task that wakes to
    /// a different session knows the gesture already ended and drops its work.
    private var curlSession = 0
    /// There was no page that way (the first page pulled back, the last pulled on): the rest of this drag is left
    /// alone rather than trying again with every move of the finger.
    private var curlRefused = false

    private func snapshotPage(scale: CGFloat? = nil) -> UIImage {
        // the navigator's own view — never the overlay covering it
        let format = UIGraphicsImageRendererFormat.default()
        if let scale { format.scale = scale }
        return UIGraphicsImageRenderer(bounds: contentController.view.bounds, format: format).image { _ in
            contentController.view.drawHierarchy(
                in: contentController.view.bounds, afterScreenUpdates: false)
        }
    }

    // MARK: Telling that a page has been painted

    /// A web view says it has moved a little before it shows it: `goForward` returns, and for a few frames (a
    /// chapter's first page: a few hundred milliseconds) the view still paints the page it was on. A leaf lifted
    /// in that gap peels off a copy of itself — so the leaf waits until the page beneath has changed, which is
    /// told from a small photograph of the navigator (a page of text differs from the next everywhere).
    private static let printColumns = 48

    private static func fingerprint(of image: UIImage) -> [UInt8] {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return [] }
        let w = printColumns, h = max(1, w * cg.height / cg.width)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : []
    }

    /// Two photographs show the same page: hardly a value in them is more than a shade apart.
    private static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var apart = 0
        for i in 0 ..< a.count where abs(Int(a[i]) - Int(b[i])) > 12 { apart += 1 }
        return apart < 12
    }

    private func currentPrint() -> [UInt8] { Self.fingerprint(of: snapshotPage(scale: 1)) }

    /// Wait for the navigator to paint something other than `before` (the page it has just left). False when it
    /// still looks the same after `limit` seconds — two pages can look alike, and the turn goes on regardless.
    private func waitForNewPage(differentFrom before: [UInt8], limit: TimeInterval = 0.45) async -> Bool {
        await waitForPrint(limit: limit) { !Self.alike($0, before) }
    }

    /// Wait for the navigator to show `page` again (a turn that was let go, and put back).
    private func waitForPage(like page: [UInt8], limit: TimeInterval = 0.45) async -> Bool {
        await waitForPrint(limit: limit) { Self.alike($0, page) }
    }

    private func waitForPrint(limit: TimeInterval, until done: ([UInt8]) -> Bool) async -> Bool {
        let start = Date()
        while true {
            if done(currentPrint()) {
                #if DEBUG
                NSLog("PTCurlReveal painted after %.0f ms", Date().timeIntervalSince(start) * 1000)
                #endif
                return true
            }
            if Date().timeIntervalSince(start) >= limit || Task.isCancelled {
                #if DEBUG
                NSLog("PTCurlReveal not painted after %.0f ms", Date().timeIntervalSince(start) * 1000)
                #endif
                return false
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// A photographed page as a flat sheet — covers the navigator while the
    /// silent moves underneath happen, so the user never sees them flicker.
    private func startCurlCover(_ overlay: PageCurlOverlay, grab: PageCurl.Grab? = nil) {
        let photograph = snapshotPage()
        coverPrint = Self.fingerprint(of: photograph)
        overlay.begin(photograph)
        overlay.frame = view.bounds
        overlay.isUserInteractionEnabled = true   // touches for the leaf, not the book
        view.addSubview(overlay)
        curlOverlay = overlay
        if let grab {
            overlay.update(origin: CGPoint(x: grab.origin.x, y: grab.origin.y),
                           touch: CGPoint(x: grab.touch.x, y: grab.touch.y))
        }
    }

    private func removeCurl() {
        curlOverlay?.removeFromSuperview()
        curlOverlay = nil
        curlGrab = nil
        curlPendingTouch = nil
        arming = false
        releasing = false
        armTask?.cancel()
        armTask = nil
        curlSession += 1
    }

    @objc private func curlDragged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            curlGrab = nil
            curlPendingTouch = nil
            curlRefused = false
        case .changed:
            let here = pan.location(in: view)
            guard curlGrab != nil else {
                guard !arming, !curlRefused else { return }
                // decide the turn the first time the finger travels decisively
                let t = pan.translation(in: view)
                let start = CGPoint(x: here.x - t.x, y: here.y - t.y)
                // a pull anywhere on the page: leftward lifts the right edge (forward in an LTR book,
                // backward in an RTL one), rightward lifts the left. A diagonal pull from a corner
                // counts too — only a mostly vertical drag is left alone.
                guard abs(t.x) > 10, abs(t.x) > abs(t.y) * 0.6 else { return }
                let towardLeft = t.x < 0
                let forward = towardLeft != rightToLeft
                // the leaf's free edge is the page's own edge, at the height the finger caught it; the
                // finger's travel moves that edge, wherever on the page the finger began
                let edge = CGPoint(x: towardLeft ? view.bounds.width : 0, y: start.y)
                curlGrab = (origin: edge, forward: forward)
                curlPendingTouch = CGPoint(x: edge.x + t.x, y: edge.y + t.y)
                arming = true
                releasing = false
                curlSession += 1
                let session = curlSession
                armTask = Task { await armCurl(forward: forward, origin: edge, session: session) }
                return
            }
            guard let grab = curlGrab else { return }
            let t = pan.translation(in: view)
            let moved = CGPoint(x: grab.origin.x + t.x, y: grab.origin.y + t.y)
            curlPendingTouch = moved
            // until the page beneath is in place the leaf lies flat: lifted now, it would peel off a copy of itself
            if !arming { curlOverlay?.update(origin: grab.origin, touch: moved) }
        case .ended, .cancelled, .failed:
            curlRefused = false
            guard let overlay = curlOverlay, let grab = curlGrab else { removeCurl(); return }
            let v = pan.velocity(in: view)
            let touch = curlPendingTouch ?? grab.origin
            let g = PageCurl.Grab(
                origin: .init(x: Double(grab.origin.x), y: Double(grab.origin.y)),
                touch: .init(x: Double(touch.x), y: Double(touch.y)))
            let p = PageCurl.progress(
                width: Double(view.bounds.width), height: Double(view.bounds.height), grab: g)
            // a flick carries the turn through — the way the peel was already
            // going, which is rightward for a backward LTR peel or a forward
            // RTL one; a slow finger has to be past half
            let peelLeft = grab.forward != rightToLeft
            let fling = peelLeft ? v.x < -450 : v.x > 450
            let commit = p > 0.45 || fling
            // the overlay keeps taking touches until the leaf has landed: a tap that reached the book now would
            // start a turn of its own over this one
            releasing = true
            let arm = armTask
            Task { [weak self] in
                // a flick can end before the navigator has been moved beneath the cover: the leaf lifts only once
                // the page it uncovers is there
                await arm?.value
                guard let self, self.curlOverlay === overlay, self.releasing else { return }
                overlay.release(origin: grab.origin, touch: touch,
                                velocity: v, commit: commit) { [weak self] in
                    Task { [weak self] in
                        guard let self else { return }
                        // the turn is settled whatever happened meanwhile — the reader's held saves depend on it —
                        // but a cover that is no longer this gesture's is not taken down
                        let ours = self.curlOverlay === overlay
                        if commit {
                            self.onCurlCommit?()
                        } else {
                            // the navigator goes back to the page the leaf lay on; the cover stays until it shows it
                            await self.onCurlCancel?()
                            if ours { _ = await self.waitForPage(like: self.coverPrint) }
                        }
                        if ours, self.curlOverlay === overlay { self.removeCurl() }
                    }
                }
            }
        default: break
        }
    }

    /// Photograph the page, park the navigator on the page the turn lands on (the next one, or the one before —
    /// either way the leaf is the page that is being left, peeled away from the edge the finger caught), wait for
    /// the navigator to paint it, and only then let the leaf track the finger.
    private func armCurl(forward: Bool, origin: CGPoint, session: Int) async {
        guard session == curlSession else { return }     // the finger already let go
        let overlay = PageCurlOverlay(frame: view.bounds)
        startCurlCover(overlay)                           // the flat page over the flicker
        guard await onCurlStep?(forward) == true else { failedCurl(session); return }
        _ = await waitForNewPage(differentFrom: coverPrint)
        guard session == curlSession else { return }
        arming = false
        if !releasing { overlay.update(origin: origin, touch: curlPendingTouch ?? origin) }
    }

    private func failedCurl(_ session: Int) {
        guard session == curlSession else { return }
        removeCurl()
        curlRefused = true
        Task { await onCurlCancel?() }
    }

    /// A tap's scripted curl: the page peels itself off on a soft arc while the
    /// navigator's own (unanimated) turn happens beneath.
    func beginCurl(towardLeft: Bool, frozenAt: Double? = nil) {
        removeCurl()   // a queued curl that never landed goes quietly
        let overlay = PageCurlOverlay(frame: view.bounds)
        startCurlCover(overlay)
        // the navigator moves just after this returns: the leaf starts once it has painted the page it moved to,
        // or it would peel off a copy of itself
        let session = curlSession
        let before = coverPrint
        armTask = Task { [weak self] in
            let turned = await self?.waitForNewPage(differentFrom: before) ?? false
            guard let self, self.curlOverlay === overlay, self.curlSession == session else { return }
            // the page never changed beneath (the last page tapped on, the first tapped back): no turn to show
            guard turned || frozenAt != nil else {
                self.removeCurl()
                return
            }
            if let frozenAt {
                overlay.pose(frozenAt: frozenAt, towardLeft: towardLeft)
                return
            }
            overlay.animateScripted(towardLeft: towardLeft) { [weak self] in
                self?.removeCurl()
            }
        }
    }

}

extension ReaderContainerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === curlPan, canCurl?() == true, curlOverlay == nil else { return false }
        // mostly sideways: a vertical drag is not a page turn (and a drag that starts a selection
        // handle never reaches here — canCurl is false while text is selected)
        let v = curlPan.velocity(in: view)
        return abs(v.x) > abs(v.y) * 0.6
    }

    /// The book's own scroll views would otherwise win every swipe — they are deeper in the view
    /// hierarchy, and UIKit lets the deeper recognizer go first. They wait for the curl to decide.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard g === curlPan, other is UIPanGestureRecognizer, other !== curlPan else { return false }
        return other.view is UIScrollView
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
