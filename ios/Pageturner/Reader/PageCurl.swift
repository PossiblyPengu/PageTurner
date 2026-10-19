import Foundation

/// The geometry of a turning leaf, as a pure function of where the finger is.
/// A page is modelled as a sheet that splits at a fold line: ahead of the fold
/// it is still flat; through the roll it wraps a cylinder; past the roll it has
/// flipped and lies face-down on the far side. Pure value math — checked on
/// Linux — so the overlay only has to place vertices where this says.
enum PageCurl {
    /// A point in page space — (0,0) is top-left, y runs down, in points.
    struct Point: Equatable {
        var x: Double
        var y: Double

        static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: Point, k: Double) -> Point { Point(x: a.x * k, y: a.y * k) }
        func dot(_ o: Point) -> Double { x * o.x + y * o.y }
        var length: Double { (x * x + y * y).squareRoot() }
        var normalized: Point { length > 0 ? self * (1 / length) : Point(x: 0, y: 0) }
    }

    /// Where a curl gesture is: the corner the finger caught, and where it is now.
    /// The drag's own direction drives the peel — a pull from either edge is
    /// just a different `touch`.
    struct Grab {
        var origin: Point
        var touch: Point
    }

    /// The radius of the roll the sheet makes as it turns back, in points.
    /// Roughly the thickness Apple Books' crease occupies.
    static let rollRadius = 40.0

    /// How far the crease is from the grab point, measured along the drag.
    /// The fold trails the finger by half the distance plus half the roll, so
    /// the free edge of the peeled part lands under the finger itself: the
    /// sheet point at distance `d` past the roll sits `2f − πr` along, which
    /// equals `d` when `f = d/2 + πr/2`.
    static func foldDepth(touchDistance d: Double) -> Double {
        max(0, d / 2 + .pi * rollRadius / 2)
    }

    /// How far the crease must travel before the leaf is fully turned: the far
    /// edge of the sheet projected onto the drag axis, plus the roll. `touch`
    /// decides the axis, so tilted drags get their own span.
    static func travel(width: Double, height: Double, grab: Grab) -> Double {
        guard let axis = axis(of: grab) else { return width + .pi * rollRadius }
        let corners = [Point(x: 0, y: 0), Point(x: width, y: 0),
                       Point(x: 0, y: height), Point(x: width, y: height)]
        let span = corners.map { ($0 - grab.origin).dot(axis.dir) }
        let near = span.min() ?? 0, far = span.max() ?? width
        return max(1, far - near + .pi * rollRadius + rollRadius)
    }

    /// How much of the leaf has turned (0…1), for the commit-or-cancel choice.
    /// The crease sits `πr/2` ahead even at rest, so only lift past that counts.
    static func progress(width: Double, height: Double, grab: Grab) -> Double {
        let d = (grab.touch - grab.origin).length
        let lift = foldDepth(touchDistance: d) - .pi * rollRadius / 2
        return min(max(lift / travel(width: width, height: height, grab: grab), 0), 1)
    }

    /// Destination position for each vertex of a `columns`×`rows` grid covering
    /// the page — the same order a uniform row-major grid comes in, top-left
    /// first. `touch == origin` (nothing dragged) is the identity grid.
    static func positions(
        columns: Int, rows: Int,
        width: Double, height: Double,
        grab: Grab
    ) -> [Point] {
        let src = source(columns: columns, rows: rows, width: width, height: height)
        guard let axis = axis(of: grab) else { return src }
        let f = foldDepth(touchDistance: (grab.touch - grab.origin).length)

        return src.map { p in
            let rel = p - grab.origin
            let u = rel.dot(axis.dir)    // depth toward the spine along the drag
            let v = rel.dot(axis.perp)   // across the page
            return grab.origin + axis.dir * unrolled(u, fold: f) + axis.perp * v
        }
    }

    /// Where a sheet point at depth `u` along the drag lands along it, for a crease at `f`.
    private static func unrolled(_ u: Double, fold f: Double) -> Double {
        let r = rollRadius
        if u >= f { return u }                          // flat: not reached by the fold yet
        if u >= f - .pi * r {
            let a = (u - (f - .pi * r)) / r             // 0…π around the cylinder
            return f - r * sin(a)                       // top-down: an arc projects to a chord
        }
        return 2 * f - .pi * r - u                      // face-down past the roll
    }

    /// The leaf as two layers, drawn one over the other. One warped sheet folds back over itself, and a
    /// GPU draws overlapping cells in grid order — so the face-down half and the flat half it lies on were
    /// interleaved row by row, the back showing through the front. Split at the roll's crest, each layer
    /// runs one way only (no overlap inside it), and the back is simply drawn above the front.
    /// `front`: the flat sheet and the near half of the roll — vertices past the crest rest on it.
    /// `back`: the far half of the roll and the face-down sheet — vertices before the crest rest on it.
    /// Both come in `source`'s order. `back` is nil while nothing has turned over yet.
    struct Layers {
        var front: [Point]
        var back: [Point]?
    }

    static func layers(
        columns: Int, rows: Int,
        width: Double, height: Double,
        grab: Grab
    ) -> Layers {
        let src = source(columns: columns, rows: rows, width: width, height: height)
        guard let axis = axis(of: grab) else { return Layers(front: src, back: nil) }
        let f = foldDepth(touchDistance: (grab.touch - grab.origin).length)
        let crest = f - .pi * rollRadius / 2       // where the roll is edge-on, half way round
        var front: [Point] = [], back: [Point] = []
        front.reserveCapacity(src.count)
        back.reserveCapacity(src.count)
        var turned = false
        for p in src {
            let rel = p - grab.origin
            let u = rel.dot(axis.dir), v = rel.dot(axis.perp)
            if u < crest { turned = true }
            front.append(grab.origin + axis.dir * unrolled(max(u, crest), fold: f) + axis.perp * v)
            back.append(grab.origin + axis.dir * unrolled(min(u, crest), fold: f) + axis.perp * v)
        }
        return Layers(front: front, back: turned ? back : nil)
    }

    /// The crease where the sheet leaves the flat page — the two points where
    /// the fold line meets the page's edges, for the shadow the overlay draws.
    /// Nil while nothing has lifted (touch at the origin).
    static func foldLine(width: Double, height: Double, grab: Grab) -> (a: Point, b: Point)? {
        guard let axis = axis(of: grab) else { return nil }
        let c = grab.origin + axis.dir * foldDepth(touchDistance: (grab.touch - grab.origin).length)
        // c + perp·t meets each rect edge — keep the two crossings inside it
        var hits: [Point] = []
        let edges: [(Point, Point)] = [
            (Point(x: 0, y: 0), Point(x: width, y: 0)),
            (Point(x: width, y: 0), Point(x: 0, y: height)),
            (Point(x: width, y: height), Point(x: -width, y: 0)),
            (Point(x: 0, y: height), Point(x: 0, y: -height)),
        ]
        for (p, d) in edges {
            // solve c + perp·t = p + d·s
            let det = axis.perp.x * d.y - axis.perp.y * d.x
            guard abs(det) > 1e-9 else { continue }
            let diff = p - c
            let t = (diff.x * d.y - diff.y * d.x) / det
            let s = (diff.x * axis.perp.y - diff.y * axis.perp.x) / det
            let q = c + axis.perp * t
            if s >= 0, s <= 1 { hits.append(q) }
        }
        guard hits.count >= 2 else { return nil }
        return (hits[0], hits[1])
    }

    /// The flat grid the leaf starts as.
    static func source(columns: Int, rows: Int, width: Double, height: Double) -> [Point] {
        (0 ... rows).flatMap { row in
            (0 ... columns).map { col in
                Point(x: width * Double(col) / Double(columns),
                      y: height * Double(row) / Double(rows))
            }
        }
    }

    /// The curl frame for a grab, or nil when the finger hasn't moved yet:
    /// `dir` the way the leaf is dragged, `perp` the fold line's direction.
    /// Takes an already-unmirrored grab.
    private static func axis(of grab: Grab) -> (dir: Point, perp: Point)? {
        let delta = grab.touch - grab.origin
        guard delta.length > 1 else { return nil }
        let dir = delta.normalized
        return (dir, Point(x: -dir.y, y: dir.x))
    }
}
