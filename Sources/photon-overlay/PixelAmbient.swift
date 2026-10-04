import AppKit
import SwiftUI
import PhotonCore

/// Background pixel-art ambience for the neon themes — a KISS port of
/// `design/animation-poc.html`.
///
/// Performance contract (why this can't hurt Photon's speed):
/// * The whole effect lives in one tiny 90×58 RGBA bitmap, stretched with a
///   nearest-neighbour filter — the pixel-art look IS the optimization.
/// * One frame ≈ 5k pixel writes; measured well under half a millisecond.
///   The run-loop timer fires at 15fps on the main thread, so ⌘Space and
///   typing are never blocked by it.
/// * The timer only runs while the overlay window is *occlusion-visible*;
///   when the panel is ordered out it stops and the state resets, so a fresh
///   open starts clean. Zero cost while Photon sits in the background.
/// * `accessibilityDisplayShouldReduceMotion` → renders one static frame.
final class PixelAmbientView: NSView {
    enum Effect: Equatable { case rain, snow, miami, city }

    static let gridW = 90, gridH = 58

    /// Which ambience a theme gets (nil = none / static background).
    static func effect(for kind: ThemeKind) -> Effect? {
        switch kind {
        case .matrix: return .rain
        case .ice: return .snow
        case .sunset: return .miami
        case .city: return .city
        default: return nil
        }
    }

    /// Soft dark band behind the results so text always pops (the "text shield").
    static let scrim = LinearGradient(
        stops: [
            .init(color: .black.opacity(0.22), location: 0),
            .init(color: .black.opacity(0.42), location: 0.26),
            .init(color: .black.opacity(0.42), location: 0.76),
            .init(color: .black.opacity(0.14), location: 1)
        ],
        startPoint: .top, endPoint: .bottom)

    private(set) var effect: Effect
    private var theme: Theme

    // MARK: - Simulation state (touched only on the main thread)

    private struct Column { var x: Int; var y: Double; var vy: Double; var acc: Double; var dead: Bool }
    private struct Flake { var x: Double; var y: Double; var speed: Double; var drift: Double; var driftSpeed: Double; var alpha: Double; var windFactor: Double }
    private struct Glow { var x: Int; var y: Int; var born: Int; var life: Int }

    private var bright = [Double](repeating: 0, count: gridW * gridH)   // rain trail grid
    private var columns: [Column] = []
    private var colCooldown = 0

    private var flakes: [Flake] = []
    private var heightMap = [Int](repeating: 0, count: gridW)
    // Neon City: procedural Blade Runner skyline (towers, windows, signs, beacon)
    private struct Building { var x: Int; var w: Int; var h: Int; var antenna: Bool; var antennaH: Int }
    private struct CityWindow { var x: Int; var y: Int; var r: UInt8; var g: UInt8; var b: UInt8; var base: Double; var toggler: Bool; var timer: Double; var on: Bool }
    private struct CitySign { var x: Int; var y: Int; var h: Int; var color: (UInt8, UInt8, UInt8); var dying: Bool; var state: Int; var timer: Double; var phase: Double }
    private var distBuildings: [Building] = []
    private var cityBuildings: [Building] = []
    private var cityWindows: [CityWindow] = []
    private var citySigns: [CitySign] = []
    private var beacon: (x: Int, y: Int) = (0, 0)
    private var cityTime: Double = 0

    // Miami Nights (Synthwave Sunset): stars + striped sun + perspective grid
    private struct Star { var x: Int; var y: Int; var speed: Double; var phase: Double; var warm: Bool }
    private var stars: [Star] = []
    private var vt: Double = 0                       // virtual time (2× speed)
    private let horizon = 34                         // ~59% down the panel
    private let sunR = 14           // settled snow per column
    private var glows: [Glow] = []
    private var wind = 0.0, windTarget = 0.0, windTimer = 60
    private var frameCount = 0

    private let maxPile = 10
    // Main-thread-only by design (the render timer runs on the main run loop);
    // `nonisolated(unsafe)` exists so deinit can invalidate them.
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var occlusionObserver: NSObjectProtocol?
    private var buf = [UInt8](repeating: 0, count: gridW * gridH * 4)

    // MARK: - Lifecycle

    init(effect: Effect, theme: Theme) {
        self.effect = effect
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        wantsLayer = true
        layer?.magnificationFilter = .nearest          // the pixel-art look
        layer?.contentsGravity = .resize
        resetState()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func update(theme: Theme) { self.theme = theme }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWindowObservation()
    }

    deinit {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        timer?.invalidate()
    }

    /// The panel's occlusion state is the single source of truth for run/stop:
    /// orderOut flips it, so the effect freezes and resets the moment the
    /// overlay hides — zero cost while Photon idles in the background.
    private func syncWindowObservation() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        guard let window else { stop(); return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVisibility() }
        }
        syncVisibility()
    }

    private func syncVisibility() {
        let isVisible = window?.occlusionState.contains(.visible) ?? false
        if isVisible {
            resetState()                              // fresh snow / clear trails each open
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                render()                              // single static frame, no timer
            } else {
                start()
            }
        } else {
            stop()
            resetState()
        }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.02                            // energy-friendly scheduling
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        guard window?.occlusionState.contains(.visible) == true else { return }
        frameCount += 1
        switch effect {
        case .rain: stepRain()
        case .snow: stepSnow()
        case .miami: stepMiami()
        case .city: stepCity()
        }
        render()
    }

    // MARK: - Rain (Acid Matrix / Neon Synth / Synthwave Sunset)

    private func stepRain() {
        for i in bright.indices { bright[i] *= 0.91 }              // trail decay

        colCooldown -= 1
        if colCooldown <= 0 && columns.count < 8 {
            columns.append(Column(x: Int.random(in: 0..<Self.gridW), y: -1,
                                  vy: 0.9 + Double.random(in: 0...0.7), acc: 0, dead: false))
            colCooldown = 8 + Int.random(in: 0...20)               // a column roughly every second
        }

        for i in columns.indices {
            var c = columns[i]
            c.acc += c.vy
            while c.acc >= 1 {
                c.acc -= 1
                c.y += 1
                if c.y >= Double(Self.gridH) { c.dead = true; break }   // bottom row reached
                bright[Int(c.y) * Self.gridW + c.x] = 1.0          // hot head repaints
            }
            columns[i] = c
        }
        columns.removeAll { $0.dead }

        // glyph shimmer: trail cells re-roll brightness — the pixel-scale
        // version of the film's ever-changing characters
        for _ in 0..<140 {
            let idx = Int.random(in: 0..<bright.count)
            let b = bright[idx]
            if b > 0.15 && b < 0.85 { bright[idx] = 0.2 + Double.random(in: 0...0.55) }
        }
    }

    // MARK: - Snow (Ice Circuit)

    private func stepWind() {
        windTimer -= 1
        if windTimer <= 0 {
            if Bool.random() { windTarget = (Bool.random() ? -1 : 1) * (0.5 + Double.random(in: 0...0.4)) }
            else { windTarget = Double.random(in: -0.2...0.2) }
            windTimer = 130 + Int.random(in: 0...240)
        }
        wind += (windTarget - wind) * 0.01
    }

    private func stepSnow() {
        stepWind()
        for i in flakes.indices {
            var f = flakes[i]
            f.y += f.speed
            f.drift += f.driftSpeed
            f.x += sin(f.drift) * 0.06 + wind * f.windFactor       // wind leans the falling flakes only
            if f.x < -1 { f.x = Double(Self.gridW) } else if f.x > Double(Self.gridW + 1) { f.x = 0 }
            let col = max(0, min(Self.gridW - 1, Int(f.x.rounded())))
            let groundY = Self.gridH - 1 - heightMap[col]
            if f.y >= Double(groundY) { land(&f, col) }
            flakes[i] = f
        }
        for i in glows.indices { glows[i].born += 1 }
        glows.removeAll { $0.born >= $0.life }
    }

    /// Flake reaches the snowbank → settle into the heightmap, avalanche-smooth.
    private func land(_ f: inout Flake, _ col: Int) {
        var col = col
        let avg = Double(heightMap.reduce(0, +)) / Double(max(1, heightMap.count))
        if heightMap[col] < maxPile && avg < Double(maxPile) * 0.85 {
            heightMap[col] += 1
            glows.append(Glow(x: col, y: Self.gridH - heightMap[col], born: 0, life: 14))
            var guardCount = 0
            while guardCount < 4 {
                let l = col > 0 ? heightMap[col - 1] : Int.max
                let r = col < Self.gridW - 1 ? heightMap[col + 1] : Int.max
                if heightMap[col] - min(l, r) > 1 {
                    if l <= r { heightMap[col - 1] += 1; heightMap[col] -= 1; col -= 1 }
                    else { heightMap[col + 1] += 1; heightMap[col] -= 1; col += 1 }
                } else { break }
            }
        }
        f.y = -1
        f.x = Double.random(in: 0..<Double(Self.gridW))
    }

    // MARK: - Miami Nights (Synthwave Sunset)

    /// 2× speed at 15fps; sun on the right; whole scene drawn at 30% alpha
    /// (the user-tuned "scene opacity" — text contrast stays ~11:1 worst-case).
    private func stepMiami() {
        vt += (1.0 / 15.0) * 2.0
    }

    private func lerpComponents(_ tIn: Double, _ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8) {
        let t = max(0, min(1, tIn))
        let r = Double(a.0) + (Double(b.0) - Double(a.0)) * t
        let g = Double(a.1) + (Double(b.1) - Double(a.1)) * t
        let bl = Double(a.2) + (Double(b.2) - Double(a.2)) * t
        return (UInt8(r.rounded()), UInt8(g.rounded()), UInt8(bl.rounded()))
    }

    private func drawMiami() {
        let scene = 0.3                                  // scene opacity (user-tuned)
        let pink = rgbBytes(theme.accentHex)             // #FF2E88
        let orange = rgbBytes(theme.calculatorAccentHex) // #FF8A3D
        let textTint = rgbBytes(theme.textHex)
        let sunX = Int((Double(Self.gridW) * 0.62).rounded())

        // stars — twinkle in the sky band
        for s in stars {
            let tw = 0.35 + 0.65 * pow(sin(vt * s.speed + s.phase), 2)
            let c = s.warm ? orange : textTint
            putPixel(s.x, s.y, c.0, c.1, c.2, tw * 0.85 * scene)
        }

        // striped sun — semicircle on the horizon, scanline gaps drifting upward
        let cy = horizon
        for y in (cy - sunR)..<cy {
            let dy = cy - y
            let halfW = Int((Double(sunR * sunR - dy * dy)).squareRoot())
            let depth = Double(dy) / Double(sunR)
            let gapH = 0.5 + depth * 1.8                              // wider gaps near horizon
            let band = ((vt * 1.6 + Double(y)).truncatingRemainder(dividingBy: 4.5) + 4.5)
                .truncatingRemainder(dividingBy: 4.5)
            if band < gapH { continue }                               // scanline gap
            let t = depth
            let c = lerpComponents(0.15 + 0.85 * t, pink, orange)
            putPixel(sunX - halfW, y, c.0, c.1, c.2, 0.6 * (0.7 + 0.3 * t) * scene)
            if halfW > 0 {
                // fill the full disc width (paint row from sunX-halfW to sunX+halfW-1)
                for x in (sunX - halfW + 1)..<min(sunX + halfW, Self.gridW) {
                    putPixel(x, y, c.0, c.1, c.2, 0.6 * (0.7 + 0.3 * t) * scene)
                }
            }
        }

        // horizon line + under-glow
        for x in 0..<Self.gridW {
            putPixel(x, horizon, pink.0, pink.1, pink.2, 0.75 * scene)
            putPixel(x, horizon + 1, orange.0, orange.1, orange.2, 0.35 * scene)
        }

        // grid floor — verticals fan from the vanishing point
        let steps = Self.gridH - horizon - 1
        let vpx = Double(Self.gridW) / 2
        for k in -6...6 {
            let xb = vpx + Double(k) * 22.0
            for s in 0...steps {
                let y = horizon + s
                let x = Int((vpx + (xb - vpx) * (Double(s) / Double(steps))).rounded())
                if x >= 0 && x < Self.gridW {
                    putPixel(x, y, pink.0, pink.1, pink.2, 0.30 * scene)
                }
            }
        }

        // grid floor — horizontal lines scrolling toward you (perspective spacing)
        let scroll = vt * 1.2
        for i in 1...10 {
            let z = Double(i) - (scroll.truncatingRemainder(dividingBy: 1))
            let y = horizon + Int((z * z * 0.42).rounded())
            if y > horizon && y < Self.gridH {
                let a = 0.14 + 0.3 * (z / 10)
                for x in 0..<Self.gridW {
                    putPixel(x, y, pink.0, pink.1, pink.2, a * scene)
                }
            }
        }
    }

    // MARK: - Neon City (procedural Blade Runner skyline)

    private func generateCity() {
        distBuildings = []
        cityBuildings = []
        cityWindows = []
        citySigns = []

        // distant tips: full width, 2-6 rows, 1px apart
        var x = 0
        while x < Self.gridW {
            let w = min(2 + Int.random(in: 0...3), Self.gridW - x)
            let h = 2 + Int.random(in: 0...4)
            distBuildings.append(Building(x: x, w: w, h: h, antenna: false, antennaH: 0))
            x += w + 1
        }

        // foreground skyline: full width, tips 4-16 rows, 1px apart, center band shorter
        let gapL = 26, gapR = 64
        var cx = 0
        while cx < Self.gridW {
            let w = min(3 + Int.random(in: 0...4), Self.gridW - cx)
            let mid = cx > gapL - 4 && cx < gapR - 4
            let h = (mid ? 4 : 6) + Int.random(in: 0...(mid ? 7 : 10))
            cityBuildings.append(Building(x: cx, w: w, h: h,
                                          antenna: Bool.random() && Bool.random() || !mid && Bool.random(),
                                          antennaH: 2 + Int.random(in: 0...1)))
            cx += w + 1
        }

        // windows: sparse, near the tips, warm + cool mix
        for b in cityBuildings {
            let n = 3 + Int.random(in: 0...4)
            for _ in 0..<n {
                let warm = Bool.random()
                let c: (UInt8, UInt8, UInt8) = warm ? (255, 217, 160) : (155, 216, 255)
                cityWindows.append(CityWindow(
                    x: b.x + 1 + Int.random(in: 0...max(0, b.w - 2)),
                    y: Self.gridH - b.h + 1 + Int.random(in: 0...max(0, Int(Double(b.h) * 0.6))),
                    r: c.0, g: c.1, b: c.2,
                    base: 0.25 + Double.random(in: 0...0.3),
                    toggler: Bool.random() && Bool.random(),
                    timer: Double.random(in: 0...8), on: true))
            }
        }

        // neon signs: 5, spread across the width, hanging below tips; first one dies
        let signPalette: [(UInt8, UInt8, UInt8)] = [
            (255, 46, 136), (34, 211, 238), (252, 238, 10),
            (74, 222, 128), (255, 138, 61), (244, 114, 182)
        ]
        for i in 0..<5 {
            let idx = min(cityBuildings.count - 1,
                          Int((Double(i) + Double.random(in: 0...0.6)) * Double(cityBuildings.count) / 5.0))
            let b = cityBuildings[idx]
            citySigns.append(CitySign(
                x: Bool.random() ? b.x : b.x + b.w - 1,
                y: Self.gridH - b.h + 2,
                h: 4 + Int.random(in: 0...4),
                color: signPalette[i % signPalette.count],
                dying: i == 0, state: 1,
                timer: 3 + Double.random(in: 0...8),
                phase: Double.random(in: 0...10)))
        }

        // beacon on the tallest tip
        let tallest = cityBuildings.reduce(cityBuildings[0]) { $1.h > $0.h ? $1 : $0 }
        beacon = (x: tallest.x + tallest.w / 2,
                  y: Self.gridH - tallest.h - (tallest.antenna ? tallest.antennaH : 0) - 1)
        cityTime = 0
    }

    private func stepCity() {
        let dt = 1.0 / 15.0
        cityTime += dt
        for i in cityWindows.indices {
            guard cityWindows[i].toggler else { continue }
            cityWindows[i].timer -= dt
            if cityWindows[i].timer <= 0 {
                cityWindows[i].on.toggle()
                cityWindows[i].timer = 4 + Double.random(in: 0...8)
            }
        }
        for i in citySigns.indices {
            guard citySigns[i].dying else { continue }
            citySigns[i].timer -= dt
            if citySigns[i].timer <= 0 {
                citySigns[i].state = citySigns[i].state == 1 ? 0 : 1
                citySigns[i].timer = citySigns[i].state == 1
                    ? (Double.random(in: 0...1) < 0.3 ? 0.1 + Double.random(in: 0...0.2) : 2 + Double.random(in: 0...5))
                    : 0.05 + Double.random(in: 0...0.25)
            }
        }
    }

    private func drawCity() {
        // light-pollution glow low over the distant tips
        let glowTop = Self.gridH - 16
        let pink = rgbBytes(theme.accentHex)
        let orange = rgbBytes(theme.calculatorAccentHex)
        for y in glowTop..<Self.gridH {
            let t = Double(y - glowTop) / Double(Self.gridH - glowTop)   // 0…<1
            let c = lerpComponents(t, pink, orange)
            let a = 0.13 * t
            if a > 0.004 {
                for x in 0..<Self.gridW { putPixel(x, y, c.0, c.1, c.2, a) }
            }
        }

        // distant tips (hazy silhouettes)
        let distC: (UInt8, UInt8, UInt8) = (6, 4, 16)
        for b in distBuildings {
            for y in (Self.gridH - b.h)..<Self.gridH {
                for x in b.x..<(b.x + b.w) { putPixel(x, y, distC.0, distC.1, distC.2, 0.9) }
            }
        }

        // foreground silhouettes + antennas
        let fgC: (UInt8, UInt8, UInt8) = (3, 2, 8)
        for b in cityBuildings {
            for y in (Self.gridH - b.h)..<Self.gridH {
                for x in b.x..<(b.x + b.w) { putPixel(x, y, fgC.0, fgC.1, fgC.2, 0.95) }
            }
            if b.antenna {
                let ax = b.x + b.w / 2
                for y in (Self.gridH - b.h - b.antennaH)..<(Self.gridH - b.h) {
                    putPixel(ax, y, fgC.0, fgC.1, fgC.2, 0.95)
                }
            }
        }

        // windows (toggler windows blink on/off)
        for w in cityWindows {
            guard w.toggler ? w.on : true else { continue }
            let a = min(1.0, w.base * (w.toggler && w.on ? 1.25 : 1.0))
            putPixel(w.x, w.y, w.r, w.g, w.b, a)
        }

        // neon signs (the dying one stutters) + faint halo
        for s in citySigns {
            var a = s.dying ? 0.9 : 0.8 + 0.12 * sin(cityTime * 3 + s.phase)
            if s.dying && s.state == 0 { a = 0.08 }
            for y in s.y..<(s.y + s.h) {
                putPixel(s.x, y, s.color.0, s.color.1, s.color.2, a)
                putPixel(s.x - 1, y, s.color.0, s.color.1, s.color.2, a * 0.15)
                putPixel(s.x + 1, y, s.color.0, s.color.1, s.color.2, a * 0.15)
            }
        }

        // aviation beacon: slow red pulse on the tallest tip
        let pulse = 0.25 + 0.75 * pow(0.5 + 0.5 * sin(cityTime * 1.4), 2)
        putPixel(beacon.x, beacon.y, 255, 59, 92, pulse)
        putPixel(beacon.x - 1, beacon.y, 255, 59, 92, pulse * 0.25)
        putPixel(beacon.x + 1, beacon.y, 255, 59, 92, pulse * 0.25)
        putPixel(beacon.x, beacon.y - 1, 255, 59, 92, pulse * 0.25)
        putPixel(beacon.x, beacon.y + 1, 255, 59, 92, pulse * 0.25)
    }

    // MARK: - Masks & fades

    private func centerMask(_ x: Int, _ y: Int) -> Double {
        let dx = abs(Double(x) - Double(Self.gridW) / 2) / (Double(Self.gridW) / 2)
        let dy = abs(Double(y) - Double(Self.gridH) * 0.52) / (Double(Self.gridH) * 0.52)
        let d = max(dx, dy)
        return 0.55 + 0.45 * pow(min(1, d), 1.4)
    }

    /// Bright below the query bar, dissolving to ~15% by the footer.
    private func rowFade(_ y: Int) -> Double {
        let t = Double(y) / Double(Self.gridH)
        if t < 0.14 { return 0.6 }
        if t < 0.5 { return 0.75 + 0.25 * ((t - 0.14) / 0.36) }
        return 1.0 - 0.85 * ((t - 0.5) / 0.5)
    }

    private func snowDepthFade(_ y: Int) -> Double {
        let t = max(0, min(1, Double(y) / Double(Self.gridH)))
        return 1 - 0.75 * pow(t, 1.4)
    }

    private func snowMask(_ x: Int, _ y: Int) -> Double {
        let dx = abs(Double(x) - Double(Self.gridW) / 2) / (Double(Self.gridW) / 2)
        let dy = abs(Double(y) - Double(Self.gridH) * 0.52) / (Double(Self.gridH) * 0.52)
        let d = max(dx, dy)
        return 0.6 + 0.4 * pow(min(1, d), 1.5)
    }

    // MARK: - Render (one tiny RGBA bitmap, transparent except effect cells)

    private func resetState() {
        bright = [Double](repeating: 0, count: Self.gridW * Self.gridH)
        columns = []
        colCooldown = 0
        flakes = seedFlakes()
        heightMap = [Int](repeating: 0, count: Self.gridW)
        glows = []
        wind = 0; windTarget = 0; windTimer = 60
        generateCity()
        stars = (0..<9).map { _ in
            Star(x: Int.random(in: 0..<Self.gridW),
                 y: Int.random(in: 0..<(horizon - 8)),
                 speed: 0.6 + Double.random(in: 0...1.4),
                 phase: Double.random(in: 0...(2 * .pi)),
                 warm: Bool.random() && Bool.random())      // ~25% warm/orange
        }
        vt = 0
        frameCount = 0
        buf = [UInt8](repeating: 0, count: Self.gridW * Self.gridH * 4)
    }

    /// 20 visible flakes: far layer slow/dim, near layer faster/brighter.
    private func seedFlakes() -> [Flake] {
        var result: [Flake] = []
        for _ in 0..<20 {
            let far = Bool.random()
            result.append(Flake(
                x: Double.random(in: 0..<Double(Self.gridW)),
                y: Double.random(in: 0..<Double(Self.gridH)),
                speed: far ? 0.08 + Double.random(in: 0...0.12) : 0.2 + Double.random(in: 0...0.24),
                drift: Double.random(in: 0...(2 * .pi)),
                driftSpeed: 0.008 + Double.random(in: 0...0.02),
                alpha: far ? 0.2 + Double.random(in: 0...0.15) : 0.45 + Double.random(in: 0...0.3),
                windFactor: far ? 0.2 : 0.5))
        }
        return result
    }

    private func render() {
        buf.replaceSubrange(0..<buf.count, with: [UInt8](repeating: 0, count: buf.count))  // transparent
        switch effect {
        case .rain: drawRain()
        case .snow: drawSnow()
        case .miami: drawMiami()
        case .city: drawCity()
        }
        publish()
    }

    private func putPixel(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: Double) {
        guard x >= 0, x < Self.gridW, y >= 0, y < Self.gridH, a > 0.004 else { return }
        let i = (y * Self.gridW + x) * 4
        buf[i] = r; buf[i + 1] = g; buf[i + 2] = b
        buf[i + 3] = UInt8(max(0, min(255, a * 255)))
    }

    private func rgbBytes(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var v: UInt64 = 0
        let h = hex.dropFirst()
        Scanner(string: String(h.prefix(6))).scanHexInt64(&v)
        return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
    }

    private func drawRain() {
        let trail = rgbBytes(theme.accentHex)
        let head = rgbBytes(theme.streakBrightHex)
        for y in 0..<Self.gridH {
            let rf = rowFade(y)
            guard rf > 0.04 else { continue }
            for x in 0..<Self.gridW {
                let b = bright[y * Self.gridW + x]
                if b < 0.08 { continue }
                let m = centerMask(x, y) * rf
                if b > 0.9 {
                    putPixel(x, y, head.0, head.1, head.2, 0.4 * m)
                } else {
                    putPixel(x, y, trail.0, trail.1, trail.2, b * 0.22 * m)
                }
            }
        }
    }

    private func drawSnow() {
        // snowbank: dim settled body, brighter fresh-snow line on top
        for x in 0..<Self.gridW {
            let h = heightMap[x]
            for k in 0..<h {
                let y = Self.gridH - 1 - k
                let top = (k == h - 1)
                let dither = Double((x * 7 + k * 13) % 3) * 0.04
                if top { putPixel(x, y, 224, 254, 255, 0.34 + dither) }
                else { putPixel(x, y, 190, 225, 250, 0.15 + dither) }
            }
        }
        // settle glints
        for g in glows {
            let t = Double(g.born) / Double(g.life)
            putPixel(g.x, g.y, 224, 254, 255, 0.4 * (1 - t))
        }
        // falling flakes (fade with depth + center mask)
        for f in flakes {
            let a = f.alpha * snowDepthFade(Int(f.y)) * snowMask(Int(f.x.rounded()), Int(f.y))
            putPixel(Int(f.x.rounded()), Int(f.y), 224, 254, 255, a)
        }
    }

    /// Hand the finished bitmap to Core Animation (one pointer swap).
    private func publish() {
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return }
        guard let image = CGImage(
            width: Self.gridW, height: Self.gridH, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: Self.gridW * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return }
        layer?.contents = image
    }
}

// MARK: - SwiftUI bridge

struct PixelAmbientRepresentable: NSViewRepresentable {
    let effect: PixelAmbientView.Effect
    let theme: Theme

    func makeNSView(context: Context) -> PixelAmbientView {
        PixelAmbientView(effect: effect, theme: theme)
    }

    func updateNSView(_ view: PixelAmbientView, context: Context) {
        view.update(theme: theme)
    }
}
