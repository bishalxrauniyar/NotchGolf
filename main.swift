import AppKit
import AVFoundation
import Carbon.HIToolbox
import QuartzCore

// MARK: - Math helpers

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var len: CGFloat { hypot(x, y) }
    var norm: CGPoint { let l = max(len, 0.0001); return CGPoint(x: x / l, y: y / l) }
    func dist(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}

private extension CGColor {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Procedural sound (in-memory WAV + AVAudioPlayer; no engine graph, exception-proof)

final class SFX {
    static let shared = SFX()
    private let sr = 44100
    private var cache: [String: Data] = [:]
    var enabled: Bool { UserDefaults.standard.object(forKey: "notchgolf.sound") as? Bool ?? true }

    private init() { }

    private func wav(_ key: String, dur: Double, gen: (Double) -> Double) {
        guard cache[key] == nil else { return }
        let frames = Int(dur * Double(sr))
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            let v = Int16(max(-1, min(1, gen(Double(i) / Double(sr)))) * 32000)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        cache[key] = d
    }

    private func play(_ key: String, _ gain: Float) {
        guard enabled, let data = cache[key] else { return }
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.volume = gain
        p.delegate = PlayerPool.shared
        PlayerPool.shared.retain(p)
        p.play()
    }

    private final class PlayerPool: NSObject, AVAudioPlayerDelegate {
        static let shared = PlayerPool()
        private var players: [AVAudioPlayer] = []
        func retain(_ p: AVAudioPlayer) {
            players.append(p)
            if players.count > 24 { players.removeAll { !$0.isPlaying } }
        }
        func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
            players.removeAll { $0 === p }
        }
    }

    func putt(_ power: Double) {
        wav("putt", dur: 0.07) { t in
            Double.random(in: -0.5...0.5) * exp(-t * 90) * 0.7
            + sin(2 * .pi * 1100 * t) * exp(-t * 140) * 0.25
        }
        play("putt", Float(0.25 + 0.5 * power))
    }

    func wall() {
        wav("wall", dur: 0.09) { t in
            sin(2 * .pi * 175 * t) * exp(-t * 32) * 0.7
            + Double.random(in: -0.5...0.5) * exp(-t * 110) * 0.2
        }
        play("wall", 0.7)
    }

    func sand() {
        var lp = 0.0
        wav("sand", dur: 0.16) { t in
            let x = Double.random(in: -0.5...0.5)
            lp += 0.06 * (x - lp)
            return lp * exp(-t * 20) * 3.4
        }
        play("sand", 0.6)
    }

    func sink() {
        var phase = 0.0
        wav("sink", dur: 0.28) { t in
            let f = max(720 - 1500 * t, 240)
            phase += 2 * .pi * f / 44100.0
            return sin(phase) * exp(-t * 11) * 0.8
        }
        play("sink", 0.75)
    }

    func splash() {
        var lp = 0.0
        wav("splash", dur: 0.4) { t in
            let x = Double.random(in: -0.5...0.5)
            lp += 0.14 * (x - lp)
            return lp * exp(-t * 8) * 2.6
        }
        play("splash", 0.7)
    }

    func fanfare(_ notes: [Double], step: Double) {
        let key = "fan\(notes.count)-\(Int(step * 100))"
        wav(key, dur: 1.0) { t in
            var s = 0.0
            for (i, f) in notes.enumerated() {
                let tt = t - Double(i) * step
                if tt >= 0 {
                    s += (sin(2 * .pi * f * tt) + 0.35 * sin(4 * .pi * f * tt)) * exp(-tt * 5) * 0.5
                }
            }
            return s
        }
        play(key, 0.75)
    }
}

// MARK: - Global hotkey: Ctrl+Option+G

enum HotKey {
    static var onToggle: (() -> Void)?
    private static var ref: EventHotKeyRef?
    static func register() {
        var et = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.onToggle?()
            return noErr
        }, 1, &et, nil, nil)
        var hk = EventHotKeyID(signature: OSType(0x4E474C46), id: 1) // 'NGLF'
        RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey), hk, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Game: full-screen transparent overlay, only the course elements are drawn

final class GameView: NSView {
    private enum Phase { case aim, roll, sink, holeOver }

    private static let BR: CGFloat = 16          // ball radius (2x)
    private static let CUPR: CGFloat = 26        // cup radius (2x)
    private static let REST: CGFloat = 0.72      // wall restitution
    private static let GRAB: CGFloat = 72        // grab radius around the ball
    private static let MAXDRAG: CGFloat = 300    // max drag length (px)
    private static let MAXSPEED: CGFloat = 3200  // max launch speed (px/s)
    private static let CATCH: CGFloat = 620      // max speed the cup swallows
    private static let FRICTION: CGFloat = 1.45
    private static let SANDFRICTION: CGFloat = 5.0

    private var phase: Phase = .aim
    private var holeNum = 1
    private var par = 2
    private var strokes = 0
    private var totalDiff = 0
    private var best: Int? = UserDefaults.standard.object(forKey: "notchgolf.best") as? Int

    private(set) var ball = CGPoint.zero
    private var vel = CGPoint.zero
    private var preShot = CGPoint.zero
    private var cup = CGPoint.zero
    private var tee = CGPoint.zero
    private var sands: [(CGPoint, CGFloat)] = []
    private var waters: [CGRect] = []
    private var bumpers: [(CGPoint, CGFloat)] = []

    private var drag: CGPoint?
    private var sinkT: CGFloat = 0
    private var sinkFrom = CGPoint.zero
    private var splashAt: CGPoint?
    private var splashT: CGFloat = 0
    private var lastT: CFTimeInterval = 0
    private var seqActive = false
    private var monitors: [Any] = []

    private var bannerText = ""
    private var bannerSub = ""
    private var bannerStart: CFTimeInterval = 0
    private var bannerUntil: CFTimeInterval = 0

    private var link: CADisplayLink?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildHole()
        ball = tee
        let l = makeDisplayLink(selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeDisplayLink(selector: Selector) -> CADisplayLink {
        if #available(macOS 14.0, *) {
            return displayLink(target: self, selector: selector)
        }
        fatalError("NotchGolf requires macOS 14+")
    }

    // Only the ball is interactive — every other click falls through to apps below
    override func hitTest(_ p: NSPoint) -> NSView? {
        return nil // the overlay window ignores events; a separate handle window near the ball handles input
    }

    override func acceptsFirstMouse(for n: NSEvent?) -> Bool { true }

    // MARK: Hole generation — cup hangs under the notched display, course spans all screens

    private var screensUnion: NSRect {
        var u = NSRect.null
        for s in NSScreen.screens { u = u.union(s.frame) }
        if u.isEmpty { u = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982) }
        return u
    }

    private func buildHole() {
        let u = screensUnion
        let w = u.width, h = u.height
        sands = []; waters = []; bumpers = []
        strokes = 0

        // cup moves every hole: wanders around the desktop, starts near the top on hole 1
        let cupAngle = CGFloat(holeNum) * 2.4
        let cupRadius = holeNum == 1 ? 0.32 : 0.18 + 0.22 * (0.5 + 0.5 * cos(cupAngle * 0.7))
        cup = CGPoint(x: w * (0.5 + 0.36 * sin(cupAngle) * cupRadius),
                      y: h * (0.55 + 0.38 * cupRadius * cos(cupAngle * 1.3)))

        let ang = CGFloat(holeNum) * 1.9
        tee = CGPoint(x: w * (0.28 + 0.44 * (0.5 + 0.5 * sin(ang))),
                      y: h * (0.18 + 0.42 * (0.5 + 0.5 * cos(ang * 1.3))))

        par = holeNum <= 1 ? 2 : (holeNum <= 3 ? 3 : 4)

        let count = min(holeNum / 2 + 1, 6)
        for i in 0..<count {
            let a = CGFloat(i + 1) * 1.7 + CGFloat(holeNum) * 0.9
            let cx = w * (0.15 + 0.7 * (0.5 + 0.5 * sin(a)))
            let cy = h * (0.14 + 0.6 * (0.5 + 0.5 * cos(a * 2.1)))
            if hypot(cx - cup.x, cy - cup.y) < 160 { continue }
            if hypot(cx - tee.x, cy - tee.y) < 130 { continue }
            if i.isMultiple(of: 3) {
                bumpers.append((CGPoint(x: cx, y: cy), 34))
            } else if i.isMultiple(of: 2) {
                sands.append((CGPoint(x: cx, y: cy), min(56 + CGFloat(holeNum) * 3, 88)))
            } else {
                waters.append(CGRect(x: cx - 140, y: cy - 28, width: 280, height: 56))
            }
        }
    }

    private func nextHole() {
        holeNum += 1
        buildHole()
        ball = tee
        vel = .zero
        sinkT = 0
        phase = .aim
        onMoveHandle?(ball)
        needsDisplay = true
    }

    func rebuildForScreens() {
        guard phase == .aim else { return }
        buildHole()
        ball = tee
        vel = .zero
        onMoveHandle?(ball)
        needsDisplay = true
    }

    // MARK: Loop

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        var dt = now - lastT
        lastT = now
        dt = min(dt, 0.05)

        if phase == .roll {
            let sub = 6
            let h = CGFloat(dt / Double(sub))
            for _ in 0..<sub where phase == .roll { integrate(h) }
        } else if phase == .sink {
            sinkT += CGFloat(dt / 0.38)
            if sinkT >= 1 { completeHole(strokes) }
        }

        if splashT > 0 { splashT = max(0, splashT - CGFloat(dt * 2.2)) }
        if phase == .holeOver && now >= bannerUntil { nextHole() }

        onMoveHandle?(ball)
        onInteractiveChange?(phase == .aim && splashT == 0)

        needsDisplay = true
        l.isPaused = phase == .aim && drag == nil && splashT == 0 && now >= bannerUntil
    }

    private func integrate(_ h: CGFloat) {
        let g = bounds
        var p = ball + vel * h
        var v = vel

        let inSand = sands.contains { $0.0.dist(to: p) < $0.1 }
        let damp = CGFloat(exp(-Double((inSand ? Self.SANDFRICTION : Self.FRICTION) * h)))
        v = v * damp
        if inSand && !sands.contains(where: { $0.0.dist(to: ball) < $0.1 }) { SFX.shared.sand() }

        if p.x - Self.BR < g.minX { p.x = g.minX + Self.BR; if v.x < 0 { if abs(v.x) > 60 { SFX.shared.wall() }; v.x = -v.x * Self.REST } }
        if p.x + Self.BR > g.maxX { p.x = g.maxX - Self.BR; if v.x > 0 { if abs(v.x) > 60 { SFX.shared.wall() }; v.x = -v.x * Self.REST } }
        if p.y - Self.BR < g.minY { p.y = g.minY + Self.BR; if v.y < 0 { if abs(v.y) > 60 { SFX.shared.wall() }; v.y = -v.y * Self.REST } }
        if p.y + Self.BR > g.maxY { p.y = g.maxY - Self.BR; if v.y > 0 { if abs(v.y) > 60 { SFX.shared.wall() }; v.y = -v.y * Self.REST } }

        for (c, r) in bumpers {
            let d = p.dist(to: c)
            if d < r + Self.BR {
                let n = (p - c).norm
                p = c + n * (r + Self.BR + 0.5)
                let vn = v.x * n.x + v.y * n.y
                if vn < 0 {
                    v = v - n * (vn * 1.85)
                    SFX.shared.wall()
                }
            }
        }

        for r in waters {
            if r.insetBy(dx: -Self.BR, dy: -Self.BR).contains(p) {
                SFX.shared.splash()
                splashAt = p
                splashT = 1
                ball = preShot
                vel = .zero
                phase = .aim
                return
            }
        }

        if p.dist(to: cup) < Self.CUPR && v.len < Self.CATCH {
            sinkFrom = p
            sinkT = 0
            phase = .sink
            SFX.shared.sink()
            return
        }

        if v.len < 11 {
            vel = .zero
            ball = p
            phase = .aim
            return
        }

        ball = p
        vel = v
    }

    private func completeHole(_ s: Int) {
        let diff = s - par
        totalDiff += diff
        bannerText = s == 1 ? "ACE!" : name(for: diff)
        bannerSub = "hole \(holeNum) done in \(s) stroke\(s == 1 ? "" : "s") · round \(fmt(totalDiff))"
        bannerStart = CACurrentMediaTime()
        bannerUntil = bannerStart + 1.7
        phase = .holeOver

        if best == nil || diff < best! {
            best = diff
            UserDefaults.standard.set(diff, forKey: "notchgolf.best")
        }
        if diff < 0 {
            SFX.shared.fanfare([523.25, 659.25, 783.99, 1046.5], step: 0.12)
        } else if diff == 0 {
            SFX.shared.fanfare([523.25, 659.25], step: 0.14)
        } else {
            SFX.shared.fanfare([392, 329.63], step: 0.16)
        }
    }

    private func name(for d: Int) -> String {
        switch d {
        case ...(-3): return "ALBATROSS!"
        case -2: return "EAGLE!"
        case -1: return "BIRDIE!"
        case 0: return "PAR"
        case 1: return "BOGEY"
        case 2: return "DOUBLE BOGEY"
        default: return "+\(d)"
        }
    }

    private func fmt(_ d: Int) -> String { d == 0 ? "E" : "\(d)" }

    // MARK: Input — driven by the HandleView (small window that follows the ball)

    var onMoveHandle: ((NSPoint) -> Void)?
    var onInteractiveChange: ((Bool) -> Void)?

    /// Global monitors as fallback for the swallowed-first-click problem: when the
    /// handle view misses the mouseDown (macOS window activation eats it), the monitor
    /// still sees the sequence and drives the shot. Guarded by seqActive so the two
    /// input paths never double-fire.
    func installGlobalMonitors() {
        let md = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.phase == .aim, !self.seqActive else { return }
                self.seqActive = true
                self.handleGrab()
            }
        }
        let mm = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.seqActive else { return }
                self.handleDrag(NSEvent.mouseLocation)
            }
        }
        let mu = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.seqActive else { return }
                self.seqActive = false
                self.handleRelease(NSEvent.mouseLocation)
            }
        }
        monitors = [md, mm, mu].compactMap { $0 }
    }

    func screenToLocal(_ sp: NSPoint) -> NSPoint {
        guard let w = window else { return sp }
        return w.convertFromScreen(NSRect(origin: sp, size: .zero)).origin
    }

    func handleGrab() {
        lastT = CACurrentMediaTime()
        link?.isPaused = false
        seqActive = true
        NSCursor.closedHand.push()
    }

    func handleDrag(_ screenPoint: NSPoint) {
        guard phase == .aim, seqActive else { return }
        drag = screenToLocal(screenPoint)
        needsDisplay = true
    }

    func handleRelease(_ screenPoint: NSPoint) {
        NSCursor.pop()
        guard phase == .aim, seqActive else { return }
        seqActive = false
        let d = screenToLocal(screenPoint)
        drag = nil
        let pull = ball - d
        let dist = min(pull.len, Self.MAXDRAG)
        guard dist > 10 else { needsDisplay = true; return }
        preShot = ball
        vel = pull.norm * (Self.MAXSPEED * (dist / Self.MAXDRAG))
        strokes += 1
        phase = .roll
        SFX.shared.putt(Double(dist / Self.MAXDRAG))
        needsDisplay = true
    }

    // MARK: Drawing — transparent, only course elements

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = bounds
        let t = CACurrentMediaTime()
        ctx.clear(g)

        // water patches — translucent, floating on the desktop
        for r in waters {
            ctx.setFillColor(CGColor.rgb(0.2, 0.5, 0.9, 0.35))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.3))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: r.minX + 8, y: r.midY + sin(t * 2 + 1) * 2))
            ctx.addLine(to: CGPoint(x: r.maxX - 8, y: r.midY + sin(t * 2) * 2))
            ctx.strokePath()
        }

        // sand traps
        for (c, r) in sands {
            ctx.setFillColor(CGColor.rgb(0.9, 0.8, 0.5, 0.4))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor.rgb(0.75, 0.62, 0.3, 0.5))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // bumpers
        for (c, r) in bumpers {
            ctx.setFillColor(CGColor.rgb(1, 0.3, 0.35, 0.55))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.4))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        // the cup hangs just below the notch
        ctx.setFillColor(CGColor.rgb(0, 0, 0, 0.75))
        ctx.fillEllipse(in: CGRect(x: cup.x - Self.CUPR, y: cup.y - Self.CUPR, width: Self.CUPR * 2, height: Self.CUPR * 2))
        ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.55 + 0.25 * CGFloat(sin(t * 2.6))))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: cup.x - Self.CUPR - 5, y: cup.y - Self.CUPR - 5, width: (Self.CUPR + 5) * 2, height: (Self.CUPR + 5) * 2))

        // flag (2x)
        let fy = cup.y - 64
        ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.9))
        ctx.setLineWidth(3)
        ctx.move(to: cup); ctx.addLine(to: CGPoint(x: cup.x, y: fy)); ctx.strokePath()
        let flag = CGMutablePath()
        flag.move(to: CGPoint(x: cup.x, y: fy))
        flag.addLine(to: CGPoint(x: cup.x + 36, y: fy + 12))
        flag.addLine(to: CGPoint(x: cup.x, y: fy + 24))
        flag.closeSubpath()
        ctx.setFillColor(CGColor.rgb(1, 0.32, 0.28, 0.95))
        ctx.addPath(flag); ctx.fillPath()

        // score chip under the cup
        let chip = "H\(holeNum) · Par \(par) · Str \(strokes) · Tot \(fmt(totalDiff))" + (best.map { " · Best \(fmt($0))" } ?? "")
        let chipAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .shadow: shadow(),
        ]
        let cs = (chip as NSString).size(withAttributes: chipAttrs)
        (chip as NSString).draw(at: CGPoint(x: cup.x - cs.width / 2, y: cup.y + Self.CUPR + 14), withAttributes: chipAttrs)

        // splash rings
        if splashT > 0, let sp = splashAt {
            ctx.setStrokeColor(CGColor.rgb(0.85, 0.92, 1, splashT * 0.8))
            ctx.setLineWidth(2)
            for i in 0..<3 {
                let rr = (1 - splashT) * 40 + CGFloat(i) * 11
                ctx.strokeEllipse(in: CGRect(x: sp.x - rr, y: sp.y - rr, width: rr * 2, height: rr * 2))
            }
        }

        // aim: pull-back line + power ring
        if phase == .aim, let d = drag {
            let pull = ball - d
            let dist = min(pull.len, Self.MAXDRAG)
            if dist > 4 {
                let power = dist / Self.MAXDRAG
                let col = NSColor(hue: CGFloat(0.33 - 0.33 * power), saturation: 0.85, brightness: 1, alpha: 1)
                let dir = pull.norm
                ctx.setShadow(offset: .zero, blur: 6, color: NSColor.black.withAlphaComponent(0.5).cgColor)
                ctx.setStrokeColor(col.cgColor)
                ctx.setLineWidth(4)
                ctx.setLineCap(.round)
                ctx.move(to: ball + dir * (Self.BR + 5))
                ctx.addLine(to: ball + dir * (dist * 0.9 + Self.BR + 5))
                ctx.strokePath()
                ctx.setStrokeColor(col.cgColor.copy(alpha: 0.6)!)
                ctx.setLineWidth(2)
                let rr = Self.BR + 10 + power * 8
                ctx.strokeEllipse(in: CGRect(x: ball.x - rr, y: ball.y - rr, width: rr * 2, height: rr * 2))
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
            }
        }

        // ball with soft drop shadow
        if phase != .holeOver {
            let bR = phase == .sink ? Self.BR * max(0.08, 1 - sinkT) : Self.BR
            let bp = phase == .sink ? sinkFrom + (cup - sinkFrom) * min(sinkT, 1) : ball
            ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 7, color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setFillColor(CGColor.rgb(0.98, 0.98, 0.96))
            ctx.fillEllipse(in: CGRect(x: bp.x - bR, y: bp.y - bR, width: bR * 2, height: bR * 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(CGColor.rgb(0.55, 0.55, 0.52, 0.7))
            ctx.fillEllipse(in: CGRect(x: bp.x - bR * 0.62, y: bp.y - bR * 0.62, width: bR * 0.55, height: bR * 0.55))
        }

        // first-hole hint near the ball
        if holeNum == 1 && strokes == 0 && phase == .aim && drag == nil {
            let hint = "grab the ball · pull back · release to putt" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5 + 0.2 * CGFloat(sin(t * 2))),
                .shadow: shadow(),
            ]
            let hw = hint.size(withAttributes: attrs).width
            hint.draw(at: CGPoint(x: ball.x - hw / 2, y: ball.y + 30), withAttributes: attrs)
        }

        // banner floats mid-screen
        if CACurrentMediaTime() < bannerUntil {
            let age = CACurrentMediaTime() - bannerStart
            let a = CGFloat(min(1, age * 6))
            let big: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(a),
                .shadow: shadow(),
            ]
            let sm: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(a * 0.85),
                .shadow: shadow(),
            ]
            let bs = (bannerText as NSString).size(withAttributes: big)
            (bannerText as NSString).draw(at: CGPoint(x: (g.width - bs.width) / 2, y: g.midY + 6), withAttributes: big)
            let ss = (bannerSub as NSString).size(withAttributes: sm)
            (bannerSub as NSString).draw(at: CGPoint(x: (g.width - ss.width) / 2, y: g.midY - 22), withAttributes: sm)
        }
    }

    private func shadow() -> NSShadow {
        let s = NSShadow()
        s.shadowBlurRadius = 4
        s.shadowOffset = CGSize(width: 0, height: -2)
        s.shadowColor = NSColor.black.withAlphaComponent(0.6)
        return s
    }
}

// MARK: - Panel + App

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Tiny always-on-top window that follows the ball and is the only interactive spot.
/// Its center (~110px around the ball) captures the mouse; its outer ring ignores events,
/// so surrounding clicks pass through to apps below.
final class HandleView: NSView {
    var onDown: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onUp: ((NSPoint) -> Void)?
    var interactive = true
    private var seqActive = false

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for n: NSEvent?) -> Bool { true }

    override func hitTest(_ p: NSPoint) -> NSView? {
        interactive ? self : nil
    }

    required init?(coder: NSCoder) { fatalError() }
    override init(frame: NSRect) { super.init(frame: frame) }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        guard !seqActive else { return }
        seqActive = true
        onDown?()
    }
    override func mouseDragged(with e: NSEvent) { onDrag?(NSEvent.mouseLocation) }
    override func mouseUp(with e: NSEvent) {
        guard seqActive else { return }
        seqActive = false
        onUp?(NSEvent.mouseLocation)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: Panel!
    private var game: GameView!
    private var handlePanel: Panel!
    private var handleView: HandleView!
    private var statusItem: NSStatusItem!
    private static let HANDLE: CGFloat = 170

    private var screensUnion: NSRect {
        var u = NSRect.null
        for s in NSScreen.screens { u = u.union(s.frame) }
        return u.isEmpty ? (NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)) : u
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let union = screensUnion

        panel = Panel(contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true // overlay never eats clicks

        game = GameView(frame: NSRect(x: 0, y: 0, width: union.width, height: union.height))
        game.wantsLayer = true
        game.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = game
        panel.orderFrontRegardless()
        game.installGlobalMonitors()

        // handle window: the only interactive pixels (centered on the ball)
        let h = Self.HANDLE
        handlePanel = Panel(contentRect: NSRect(x: 0, y: 0, width: h, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        handlePanel.level = .statusBar + 1
        handlePanel.isOpaque = false
        handlePanel.backgroundColor = .clear
        handlePanel.hasShadow = false
        handlePanel.hidesOnDeactivate = false
        handlePanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        handlePanel.ignoresMouseEvents = false

        handleView = HandleView(frame: NSRect(x: 0, y: 0, width: h, height: h))
        handleView.onDown = { [weak self] in self?.game.handleGrab() }
        handleView.onDrag = { [weak self] pt in self?.game.handleDrag(pt) }
        handleView.onUp = { [weak self] pt in self?.game.handleRelease(pt) }
        handlePanel.contentView = handleView
        handlePanel.orderFrontRegardless()
        moveHandle()

        game.onMoveHandle = { [weak self] _ in self?.moveHandle() }
        game.onInteractiveChange = { [weak self] on in self?.handleView.interactive = on }

        HotKey.register()
        HotKey.onToggle = { [weak self] in self?.toggle() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⛳"
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Show / Hide (⌃⌥G)", action: #selector(toggleMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let snd = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self
        snd.state = (UserDefaults.standard.object(forKey: "notchgolf.sound") as? Bool ?? true) ? .on : .off
        menu.addItem(snd)
        let reset = NSMenuItem(title: "Restart Round", action: #selector(restart), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchGolf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.position() }
    }

    private func position() {
        let u = screensUnion
        panel.setFrame(u, display: true)
        game.frame = NSRect(x: 0, y: 0, width: u.width, height: u.height)
        game.rebuildForScreens()
        moveHandle()
    }

    private func moveHandle() {
        guard let w = game.window else { return }
        let local = game.ball // view coords == window coords for the fullscreen overlay
        let screenPt = w.convertToScreen(NSRect(origin: local, size: .zero)).origin
        let h = Self.HANDLE
        handlePanel.setFrameOrigin(NSPoint(x: screenPt.x - h / 2, y: screenPt.y - h / 2))
    }

    @objc private func toggleMenu() { toggle() }
    @objc private func toggleSound() {
        let v = !(UserDefaults.standard.object(forKey: "notchgolf.sound") as? Bool ?? true)
        UserDefaults.standard.set(v, forKey: "notchgolf.sound")
        statusItem.menu?.items.first(where: { $0.title == "Sound" })?.state = v ? .on : .off
    }
    @objc private func restart() { game.newRound() }

    private func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { position(); panel.orderFrontRegardless() }
    }
}

extension GameView {
    func newRound() {
        holeNum = 1
        totalDiff = 0
        buildHole()
        ball = tee
        vel = .zero
        sinkT = 0
        splashT = 0
        drag = nil
        bannerText = ""
        bannerUntil = 0
        phase = .aim
        needsDisplay = true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
