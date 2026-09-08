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

// MARK: - Procedural sound (no asset files)

final class SFX {
    static let shared = SFX()
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextIdx = 0
    private let sr: Double = 44100
    var enabled: Bool { UserDefaults.standard.object(forKey: "notchgolf.sound") as? Bool ?? true }

    private init() {
        do {
            try engine.start()
            let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
            for _ in 0..<6 {
                let p = AVAudioPlayerNode()
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: fmt)
                p.play()
                players.append(p)
            }
        } catch { }
    }

    private func buffer(_ dur: Double, gen: (Double) -> Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(dur * sr)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        let data = b.floatChannelData![0]
        for i in 0..<Int(frames) { data[i] = Float(gen(Double(i) / sr)) }
        b.frameLength = frames
        return b
    }

    private func play(_ b: AVAudioPCMBuffer, _ gain: Float) {
        guard enabled, engine.isRunning else { return }
        let p = players[nextIdx % players.count]
        nextIdx += 1
        p.volume = gain
        p.scheduleBuffer(b, at: nil, options: .interrupts)
    }

    func putt(_ power: Double) {
        play(buffer(0.07) { t in
            Double.random(in: -0.5...0.5) * exp(-t * 90) * 0.7
            + sin(2 * .pi * 1100 * t) * exp(-t * 140) * 0.25
        }, Float(0.3 + 0.5 * power))
    }

    func wall() {
        play(buffer(0.09) { t in
            sin(2 * .pi * 175 * t) * exp(-t * 32) * 0.7
            + Double.random(in: -0.5...0.5) * exp(-t * 110) * 0.2
        }, 0.8)
    }

    func sand() {
        var lp = 0.0
        play(buffer(0.16) { t in
            let x = Double.random(in: -0.5...0.5)
            lp += 0.06 * (x - lp)
            return lp * exp(-t * 20) * 3.4
        }, 0.7)
    }

    func sink() {
        var phase = 0.0
        play(buffer(0.28) { t in
            let f = max(720 - 1500 * t, 240)
            phase += 2 * .pi * f / self.sr
            return sin(phase) * exp(-t * 11) * 0.8
        }, 0.85)
    }

    func splash() {
        var lp = 0.0
        play(buffer(0.4) { t in
            let x = Double.random(in: -0.5...0.5)
            lp += 0.14 * (x - lp)
            return lp * exp(-t * 8) * 2.6
        }, 0.8)
    }

    func fanfare(_ notes: [Double], step: Double) {
        play(buffer(1.0) { t in
            var s = 0.0
            for (i, f) in notes.enumerated() {
                let tt = t - Double(i) * step
                if tt >= 0 {
                    s += (sin(2 * .pi * f * tt) + 0.35 * sin(4 * .pi * f * tt)) * exp(-tt * 5) * 0.5
                }
            }
            return s
        }, 0.85)
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

// MARK: - Game

final class GameView: NSView {
    private enum Phase { case aim, roll, sink, holeOver }

    private static let BR: CGFloat = 7          // ball radius
    private static let CUPR: CGFloat = 11       // cup radius
    private static let REST: CGFloat = 0.72     // wall restitution
    private static let MAXDRAG: CGFloat = 110   // max drag length (px)
    private static let MAXSPEED: CGFloat = 1050 // max launch speed (px/s)
    private static let CATCH: CGFloat = 420     // max speed the cup swallows

    private var phase: Phase = .aim
    private var holeNum = 1
    private var par = 2
    private var strokes = 0
    private var totalDiff = 0
    private var best: Int? = UserDefaults.standard.object(forKey: "notchgolf.best") as? Int

    private var ball = CGPoint.zero
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

    private var bannerText = ""
    private var bannerSub = ""
    private var bannerStart: CFTimeInterval = 0
    private var bannerUntil: CFTimeInterval = 0

    private var link: CADisplayLink?
    private var isPaused = false

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        buildHole()
        ball = tee
        let l = viewDisplayLink(selector: #selector(tick(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
    }
    required init?(coder: NSCoder) { fatalError() }

    private func viewDisplayLink(selector: Selector) -> CADisplayLink {
        if #available(macOS 14.0, *) {
            return displayLink(target: self, selector: selector)
        }
        let l = CADisplayLink()
        l.isPaused = true
        return l
    }

    // MARK: Hole generation (formulaic, deterministic per hole number)

    private func buildHole() {
        let w = bounds.width, h = bounds.height
        sands = []; waters = []; bumpers = []
        strokes = 0

        tee = CGPoint(x: w * 0.12, y: h * 0.62)
        cup = CGPoint(x: w * 0.86, y: h * 0.5)

        par = holeNum <= 1 ? 2 : (holeNum <= 3 ? 3 : 4)

        let count = min(holeNum / 2, 4)
        for i in 0..<count {
            let ang = CGFloat(i + 1) * 1.1
            let cx = w * (0.42 + 0.09 * sin(ang))
            let cy = h * (0.5 + 0.26 * cos(ang * 1.7))
            if i.isMultiple(of: 2) {
                sands.append((CGPoint(x: cx, y: cy), min(24 + CGFloat(holeNum) * 1.5, 32)))
            } else {
                bumpers.append((CGPoint(x: cx, y: cy), 14))
            }
        }
        if holeNum >= 3 {
            let wy = h * (holeNum.isMultiple(of: 2) ? 0.32 : 0.68)
            waters = [CGRect(x: w * 0.45, y: wy - 9, width: w * 0.22, height: 18)]
        }
        if holeNum >= 5 {
            bumpers.append((CGPoint(x: w * 0.62, y: h * 0.5), 13))
        }
    }

    private func nextHole() {
        holeNum += 1
        buildHole()
        ball = tee
        vel = .zero
        sinkT = 0
        phase = .aim
    }

    // MARK: Loop

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        var dt = now - lastT
        lastT = now
        dt = min(dt, 0.05)

        if phase == .roll {
            let sub = 4
            let h = CGFloat(dt / Double(sub))
            for _ in 0..<sub where phase == .roll { integrate(h) }
        } else if phase == .sink {
            sinkT += CGFloat(dt / 0.38)
            if sinkT >= 1 { completeHole(strokes) }
        }

        if splashT > 0 { splashT = max(0, splashT - CGFloat(dt * 2.2)) }
        if phase == .holeOver && now >= bannerUntil { nextHole() }

        needsDisplay = true
        l.isPaused = phase == .aim && drag == nil && splashT == 0 && now >= bannerUntil
    }

    private func integrate(_ h: CGFloat) {
        let g = bounds
        var p = ball + vel * h
        var v = vel

        let inSand = sands.contains { $0.0.dist(to: p) < $0.1 }
        let damp = CGFloat(exp(-Double((inSand ? 4.2 : 1.15) * h)))
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

        if v.len < 9 {
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

    // MARK: Input

    override func mouseDown(with e: NSEvent) {
        lastT = CACurrentMediaTime()
        link?.isPaused = false
        if phase == .holeOver { nextHole(); return }
        guard phase == .aim else { return }
        let p = convert(e.locationInWindow, from: nil)
        if p.dist(to: ball) < 34 { drag = p }
    }

    override func mouseDragged(with e: NSEvent) {
        guard phase == .aim, drag != nil else { return }
        drag = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard phase == .aim, let d = drag else { return }
        drag = nil
        let pull = ball - d
        let dist = min(pull.len, Self.MAXDRAG)
        guard dist > 8 else { needsDisplay = true; return }
        preShot = ball
        vel = pull.norm * (Self.MAXSPEED * (dist / Self.MAXDRAG))
        strokes += 1
        phase = .roll
        SFX.shared.putt(Double(dist / Self.MAXDRAG))
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = bounds
        let t = CACurrentMediaTime()

        ctx.setFillColor(CGColor.rgb(0.07, 0.09, 0.08))
        ctx.fill(g)
        ctx.setFillColor(CGColor.rgb(0.11, 0.4, 0.21))
        ctx.fill(g.insetBy(dx: 3, dy: 3))
        ctx.setFillColor(CGColor.rgb(1, 1, 1, 0.035))
        var x: CGFloat = 3
        while x < g.maxX - 3 { ctx.fill(CGRect(x: x, y: g.minY + 3, width: 11, height: g.height - 6)); x += 22 }

        for r in waters {
            ctx.setFillColor(CGColor.rgb(0.15, 0.4, 0.75, 0.92))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.25))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: r.minX + 6, y: r.midY + sin(t * 2 + 1) * 1.5))
            ctx.addLine(to: CGPoint(x: r.maxX - 6, y: r.midY + sin(t * 2) * 1.5))
            ctx.strokePath()
        }

        for (c, r) in sands {
            ctx.setFillColor(CGColor.rgb(0.87, 0.76, 0.45))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor.rgb(0.6, 0.48, 0.22, 0.6))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        for (c, r) in bumpers {
            ctx.setFillColor(CGColor.rgb(0.9, 0.25, 0.3))
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setFillColor(CGColor.rgb(1, 1, 1, 0.3))
            ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.55, height: r * 0.55))
        }

        ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.35))
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: tee.x - 11, y: tee.y - 11, width: 22, height: 22))

        ctx.setFillColor(CGColor.rgb(0.02, 0.02, 0.02))
        ctx.fillEllipse(in: CGRect(x: cup.x - Self.CUPR, y: cup.y - Self.CUPR, width: Self.CUPR * 2, height: Self.CUPR * 2))
        ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.22 + 0.12 * CGFloat(sin(t * 2.6))))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: cup.x - Self.CUPR - 4, y: cup.y - Self.CUPR - 4, width: (Self.CUPR + 4) * 2, height: (Self.CUPR + 4) * 2))

        let fy = cup.y - 26
        ctx.setStrokeColor(CGColor.rgb(1, 1, 1, 0.9))
        ctx.setLineWidth(2)
        ctx.move(to: cup); ctx.addLine(to: CGPoint(x: cup.x, y: fy)); ctx.strokePath()
        let flag = CGMutablePath()
        flag.move(to: CGPoint(x: cup.x, y: fy))
        flag.addLine(to: CGPoint(x: cup.x + 15, y: fy + 5))
        flag.addLine(to: CGPoint(x: cup.x, y: fy + 11))
        flag.closeSubpath()
        ctx.setFillColor(CGColor.rgb(1, 0.32, 0.28))
        ctx.addPath(flag); ctx.fillPath()

        if splashT > 0, let sp = splashAt {
            ctx.setStrokeColor(CGColor.rgb(1, 1, 1, splashT * 0.7))
            ctx.setLineWidth(2)
            for i in 0..<3 {
                let rr = (1 - splashT) * 34 + CGFloat(i) * 9
                ctx.strokeEllipse(in: CGRect(x: sp.x - rr, y: sp.y - rr, width: rr * 2, height: rr * 2))
            }
        }

        if phase == .aim, let d = drag {
            let pull = ball - d
            let dist = min(pull.len, Self.MAXDRAG)
            if dist > 4 {
                let power = dist / Self.MAXDRAG
                let col = NSColor(hue: CGFloat(0.33 - 0.33 * power), saturation: 0.85, brightness: 1, alpha: 1)
                let dir = pull.norm
                ctx.setStrokeColor(col.cgColor)
                ctx.setLineWidth(3)
                ctx.setLineCap(.round)
                ctx.move(to: ball + dir * (Self.BR + 4))
                ctx.addLine(to: ball + dir * (dist * 0.9 + Self.BR + 4))
                ctx.strokePath()
                ctx.setStrokeColor(col.cgColor.copy(alpha: 0.5)!)
                ctx.setLineWidth(2)
                let rr = Self.BR + 8 + power * 6
                ctx.strokeEllipse(in: CGRect(x: ball.x - rr, y: ball.y - rr, width: rr * 2, height: rr * 2))
            }
        }

        if phase != .holeOver {
            let bR = phase == .sink ? Self.BR * max(0.08, 1 - sinkT) : Self.BR
            let bp = phase == .sink ? sinkFrom + (cup - sinkFrom) * min(sinkT, 1) : ball
            ctx.setFillColor(CGColor.rgb(0.97, 0.97, 0.95))
            ctx.fillEllipse(in: CGRect(x: bp.x - bR, y: bp.y - bR, width: bR * 2, height: bR * 2))
            ctx.setFillColor(CGColor.rgb(0.55, 0.55, 0.52, 0.6))
            ctx.fillEllipse(in: CGRect(x: bp.x - bR * 0.6, y: bp.y - bR * 0.6, width: bR * 0.55, height: bR * 0.55))
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let line = "Hole \(holeNum) · Par \(par) · Str \(strokes) · Tot \(fmt(totalDiff))"
        (line as NSString).draw(at: CGPoint(x: 8, y: g.maxY - 18), withAttributes: attrs)
        if let b = best {
            let bt = "Best \(fmt(b))" as NSString
            let bw = bt.size(withAttributes: attrs).width
            bt.draw(at: CGPoint(x: g.maxX - 8 - bw, y: g.maxY - 18), withAttributes: attrs)
        }
        if holeNum == 1 && strokes == 0 && phase == .aim && drag == nil {
            let hint = "drag from the ball, release to putt" as NSString
            let hw = hint.size(withAttributes: attrs).width
            hint.draw(at: CGPoint(x: (g.width - hw) / 2, y: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45 + 0.2 * CGFloat(sin(t * 2))),
            ])
        }

        if CACurrentMediaTime() < bannerUntil {
            let age = CACurrentMediaTime() - bannerStart
            let a = CGFloat(min(1, age * 6))
            let big: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 23, weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(a),
            ]
            let sm: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(a * 0.8),
            ]
            let bs = (bannerText as NSString).size(withAttributes: big)
            (bannerText as NSString).draw(at: CGPoint(x: (g.width - bs.width) / 2, y: g.midY + 2), withAttributes: big)
            let ss = (bannerSub as NSString).size(withAttributes: sm)
            (bannerSub as NSString).draw(at: CGPoint(x: (g.width - ss.width) / 2, y: g.midY - 16), withAttributes: sm)
        }
    }
}

// MARK: - Panel + App

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: Panel!
    private var game: GameView!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let w: CGFloat = 380, h: CGFloat = 220

        panel = Panel(contentRect: NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false

        game = GameView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        game.wantsLayer = true
        game.layer?.backgroundColor = NSColor.clear.cgColor
        game.layer?.cornerRadius = 16
        game.layer?.masksToBounds = true
        panel.contentView = game
        panel.orderFrontRegardless()

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
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        panel.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - panel.frame.width / 2, y: screen.frame.maxY))
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
