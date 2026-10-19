import simd
import SpriteKit
import UIKit

/// A page photographed mid-turn: the leaf is a sprite warped by `PageCurl`,
/// standing over the live navigator (which shows wherever the turn lands).
/// All the deformation is a `SKWarpGeometryGrid` — the pure math lives in
/// `PageCurl`; this only places vertices and draws the crease's shadow.
final class PageCurlOverlay: UIView {
    private let skView = SKView()
    private let scene = SKScene()
    private let page = SKSpriteNode()
    /// The face-down half of the sheet, drawn over the front: the same photograph, mirrored by the warp and
    /// washed with the paper's colour, so what shows through is a faint ghost of the print, not the print.
    private let backPage = SKSpriteNode()
    /// The soft shadow the lifted sheet throws on the page it uncovers.
    private let foldShadow = SKSpriteNode()

    /// Vertex resolution of the leaf — enough rows for the crease to be smooth.
    private static let columns = 22
    private static let rows = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        skView.frame = bounds
        skView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        skView.isOpaque = false
        skView.allowsTransparency = true
        addSubview(skView)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        skView.presentScene(scene)
        foldShadow.texture = Self.gradient
        foldShadow.zPosition = 1          // under the leaf, over the page below
        foldShadow.alpha = 0
        scene.addChild(foldShadow)
        page.anchorPoint = .zero
        page.position = .zero
        page.zPosition = 2
        scene.addChild(page)
        backPage.anchorPoint = .zero
        backPage.position = .zero
        backPage.zPosition = 3
        backPage.colorBlendFactor = 0.88
        backPage.isHidden = true
        scene.addChild(backPage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scene.size = bounds.size
        page.size = bounds.size
        backPage.size = bounds.size
    }

    /// Removed mid-animation: stop driving it — nothing is left to land.
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil {
            displayLink?.invalidate()
            displayLink = nil
            animState = nil
        }
    }

    /// The photographed page stands in for the leaf until it peels away.
    func begin(_ image: UIImage) {
        let texture = SKTexture(image: image)
        page.texture = texture
        page.size = bounds.size
        backPage.texture = texture
        backPage.color = Self.paper(of: image)
        backPage.size = bounds.size
        scene.size = bounds.size
        update(origin: CGPoint(x: bounds.width, y: bounds.midY), touch: CGPoint(x: bounds.width, y: bounds.midY))
    }

    /// Track the finger: warp the leaf's grid and lay the fold's shadow.
    /// `origin`/`touch` are in view coordinates.
    func update(origin: CGPoint, touch: CGPoint) {
        let w = Double(bounds.width), h = Double(bounds.height)
        guard w > 0, h > 0 else { return }
        let grab = PageCurl.Grab(
            origin: .init(x: Double(origin.x), y: Double(origin.y)),
            touch: .init(x: Double(touch.x), y: Double(touch.y)))

        let src = PageCurl.source(columns: Self.columns, rows: Self.rows, width: w, height: h)
        let layers = PageCurl.layers(
            columns: Self.columns, rows: Self.rows, width: w, height: h, grab: grab)
        page.warpGeometry = Self.warp(from: src, to: layers.front, width: w, height: h)
        if let back = layers.back {
            backPage.warpGeometry = Self.warp(from: src, to: back, width: w, height: h)
            backPage.isHidden = false
        } else {
            backPage.isHidden = true
        }

        // the shadow lives in scene points — y-up
        if let fold = PageCurl.foldLine(width: w, height: h, grab: grab) {
            let a = fold.a, b = fold.b
            foldShadow.position = CGPoint(x: CGFloat(a.x + b.x) / 2, y: CGFloat(h) - CGFloat(a.y + b.y) / 2)
            foldShadow.size = CGSize(
                width: PageCurl.rollRadius * 3,
                height: CGFloat(hypot(b.x - a.x, b.y - a.y)) + 60)
            foldShadow.zRotation = atan2(CGFloat(b.x - a.x), CGFloat(b.y - a.y))
            foldShadow.alpha = 0.32
        } else {
            foldShadow.alpha = 0
        }
    }

    /// SpriteKit wants normalized (0…1) positions, rows bottom-first and y-up; the page math is point
    /// space, rows top-first and y-down — walk the rows backwards to reorder, and flip y while normalizing.
    private static func warp(
        from src: [PageCurl.Point], to dest: [PageCurl.Point], width w: Double, height h: Double
    ) -> SKWarpGeometryGrid {
        var srcSK: [vector_float2] = []
        var dstSK: [vector_float2] = []
        srcSK.reserveCapacity(src.count)
        dstSK.reserveCapacity(dest.count)
        for row in stride(from: rows, through: 0, by: -1) {
            for col in 0 ... columns {
                let i = row * (columns + 1) + col
                srcSK.append(vector_float2(Float(src[i].x / w), Float(1 - src[i].y / h)))
                dstSK.append(vector_float2(Float(dest[i].x / w), Float(1 - dest[i].y / h)))
            }
        }
        return SKWarpGeometryGrid(
            columns: columns, rows: rows, sourcePositions: srcSK, destinationPositions: dstSK)
    }

    /// The sheet's own colour: the average of its top-left corner, where a page has margin and no print.
    /// What the back of the leaf is washed with.
    private static func paper(of image: UIImage) -> UIColor {
        guard let cg = image.cgImage else { return .white }
        let side = min(8, cg.width, cg.height)
        guard side > 0, let corner = cg.cropping(to: CGRect(x: 0, y: 0, width: side, height: side))
        else { return .white }
        var pixel: [UInt8] = [255, 255, 255, 255]
        let drawn = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return .white }
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Release the leaf: it settles onto the far stack (commit — the navigator
    /// already shows that page beneath) or springs back (cancel).
    /// `origin` is where the finger caught the leaf, `touch` where it let go,
    /// `velocity` the pan's velocity in points/sec (sign decides follow-through).
    func release(
        origin: CGPoint, touch: CGPoint, velocity: CGPoint,
        commit: Bool,
        completion: @escaping () -> Void
    ) {
        let w = Double(bounds.width), h = Double(bounds.height)
        let grabbed = PageCurl.Grab(
            origin: .init(x: Double(origin.x), y: Double(origin.y)),
            touch: .init(x: Double(touch.x), y: Double(touch.y)))
        let delta = grabbed.touch - grabbed.origin
        let dir = delta.normalized
        let from = delta.length
        // past the far edge + the roll — the leaf is wholly turned
        let travel = PageCurl.travel(width: w, height: h, grab: grabbed)
        let target = commit ? travel * 1.6 : 0.0
        let speed = max(600, abs(Double(velocity.x)) * 0.8 + abs(Double(velocity.y)) * 0.4)
        let duration = min(max(abs(target - from) / speed, 0.18), 0.5)
        animate(origin: grabbed.origin, dir: dir, from: from, to: target,
                duration: duration, completion: completion)
    }

    /// A scripted turn (a tap): the leaf is pulled from the edge on a soft arc.
    func animateScripted(towardLeft: Bool, completion: @escaping () -> Void) {
        let w = Double(bounds.width), h = Double(bounds.height)
        let origin = PageCurl.Point(x: towardLeft ? w - 2 : 2, y: h * 0.58)
        animate(origin: origin, dir: PageCurl.Point(x: towardLeft ? -1 : 1, y: 0),
                from: 0, to: w * 1.9 + .pi * PageCurl.rollRadius,
                duration: 0.55, completion: completion)
    }

    /// Hold the leaf part-turned for a simulator photograph (`-PTDebugTurn curl`).
    /// `-PTDebugCorner YES` holds the pull from the bottom corner instead, a diagonal drag toward the top
    /// (the case where the back of the leaf once showed the front through it).
    func pose(frozenAt progress: Double, towardLeft: Bool) {
        let w = Double(bounds.width), h = Double(bounds.height)
        if UserDefaults.standard.bool(forKey: "PTDebugCorner") {
            let origin = PageCurl.Point(x: towardLeft ? w - 2 : 2, y: h - 2)
            let d = progress * (w + h * 0.3)
            update(
                origin: CGPoint(x: origin.x, y: origin.y),
                touch: CGPoint(x: towardLeft ? origin.x - d * 0.9 : origin.x + d * 0.9, y: origin.y - d * 0.85))
            return
        }
        let origin = PageCurl.Point(x: towardLeft ? w - 2 : 2, y: h * 0.58)
        let grab = PageCurl.Grab(origin: origin, touch: origin)
        let travel = PageCurl.travel(width: w, height: h, grab: grab)
        let d = progress * travel * 1.1
        let tx = towardLeft ? origin.x - d * 0.96 : origin.x + d * 0.96
        update(
            origin: CGPoint(x: origin.x, y: origin.y),
            touch: CGPoint(x: tx, y: origin.y + d * 0.1))
    }

    /// Drive `touch` along a straight pull: `distance` along the drag axis.
    private var displayLink: CADisplayLink?
    private func animate(
        origin: PageCurl.Point, dir: PageCurl.Point,
        from: Double, to: Double,
        duration: Double, completion: @escaping () -> Void
    ) {
        displayLink?.invalidate()
        let start = Date()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Low Power Mode: the finish still lands, it just draws fewer frames
        if LowPower.on {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        }
        animState = Anim(origin: origin, dir: dir, from: from, to: to, start: start,
                         duration: duration, completion: completion)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private struct Anim {
        var origin, dir: PageCurl.Point
        var from, to: Double
        var start: Date
        var duration: Double
        var completion: () -> Void
    }
    private var animState: Anim?

    @objc private func tick(_ link: CADisplayLink) {
        guard let a = animState else { link.invalidate(); return }
        let t = min(1, Date().timeIntervalSince(a.start) / a.duration)
        let eased = 1 - pow(1 - t, 3)     // ease-out cubic
        let d = a.from + (a.to - a.from) * eased
        let touch = a.origin + a.dir * d
        update(origin: CGPoint(x: a.origin.x, y: a.origin.y),
               touch: CGPoint(x: touch.x, y: touch.y + d * 0.08))
        if t >= 1 {
            link.invalidate()
            displayLink = nil
            animState = nil
            a.completion()
        }
    }

    /// A horizontal soft gradient — the shadow band, rotated onto the fold.
    private static let gradient: SKTexture = {
        let w = 64, h = 8
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let img = renderer.image { ctx in
            for x in 0 ..< w {
                let t = Double(x) / Double(w - 1)
                let a = sin(t * .pi) * 0.9      // dark middle, clear edges
                UIColor.black.withAlphaComponent(a).setFill()
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
        }
        let t = SKTexture(image: img)
        t.filteringMode = .linear
        return t
    }()
}
