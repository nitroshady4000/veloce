import AppKit
import Metal
import QuartzCore
import SwiftUI
import simd

// Famulus' « Liseré » (app/poc/SkinLisere.swift, Skin.swift), copied as is:
// the same engine, the same shader, the same frame policy, the same pixel
// format. A Liquid Glass capsule circled by one thread of iridescent light. In
// silence the whole spectrum turns round the glass in about ten seconds, with
// one glint; outside, a halo whose hue drifts with distance. When the owner
// speaks, the light pours out of the left end into the thread and takes a
// little over a second to reach the far end, hot near the source, cooler
// further on; the halo swells, the light enters the glass from its edge,
// sparks ride the thread. Thinking: two comets chase each other round. Done:
// a wave of mint and gold closing the loop with a flash. Failure: Famulus'
// "unknown effects", in coral, steady, one slow breath.
//
// Removed from Famulus: the flame character and its glow on the glass, the
// card's thread, the typing / question / not-understood modes (their weights
// stay 0), the caustics (third-party code).
//
// Performance: one Metal fragment drawn outside SwiftUI by the view's own
// display link; 60 frames per second only while the voice, a comet or a wave
// runs, 30 otherwise, none once hidden or settled. Extended sRGB: the
// brightest points rise a little above SDR white on an XDR screen.

struct PillLight: View {
    var phase: PillPhase
    /// The recorder's raw level (Véloce scale, see PillVoiceResponse.meter).
    var level: Double
    var reduceMotion: Bool
    /// The capsule's width (it grows with the words); live, the light reads the
    /// animated width from the stage at its own frames.
    var width: CGFloat = PillLayout.width
    var stage: PillStage? = nil
    var frozenTime: Double? = nil
    /// Offline only: the raw meter level at a given time, so a snapshot can
    /// show the voice travelling along the thread.
    var levelAt: ((Double) -> Double)? = nil
    /// Offline only: seconds since the pill appeared (the thread traced in), and
    /// how far it has flowed back into its source while leaving (0 ... 1).
    var frozenSinceAppear: Double = 10
    var frozenDisappear: Double = 0

    var body: some View {
        if let frozenTime, let image = PillLightRenderer.snapshot(phase: phase, level: level, time: frozenTime,
                                                                  levelAt: levelAt, reduceMotion: reduceMotion, width: width,
                                                                  sinceAppear: frozenSinceAppear, disappear: frozenDisappear) {
            Image(decorative: image, scale: 2).resizable()
        } else if PillLightRenderer.shared == nil || PillLightRenderer.shared?.failed == true {
            PillOutline().stroke(phase == .failure ? VeloceTheme.coral : VeloceTheme.gold,
                                 lineWidth: phase == .listening ? 1.8 : 0.8)
                .opacity(phase == .listening ? 0.45 + PillVoiceResponse.meter(level) * 0.5 : 0.45)
                .frame(width: width, height: PillLayout.height)
        } else {
            LivePillLight(phase: phase, level: level, reduceMotion: reduceMotion, stage: stage)
        }
    }
}

private struct LivePillLight: NSViewRepresentable {
    var phase: PillPhase
    var level: Double
    var reduceMotion: Bool
    var stage: PillStage?
    func makeNSView(context: Context) -> PillLightView {
        let view = PillLightView(frame: .zero)
        view.configure(phase: phase, level: level, reduceMotion: reduceMotion, stage: stage)
        return view
    }
    func updateNSView(_ view: PillLightView, context: Context) {
        view.configure(phase: phase, level: level, reduceMotion: reduceMotion, stage: stage)
    }
    static func dismantleNSView(_ view: PillLightView, coordinator: ()) { view.stop() }
}

// MARK: - Voice

/// Famulus' VoiceEnvelope (Magic.swift): the microphone level as a VU meter
/// reads it, fast attack (60 ms), slow release (350 ms), advanced by the
/// frames that draw it. The raw level arrives about 20 times a second.
@MainActor
final class VoiceEnvelope {
    private var target = 0.0
    private var value = 0.0
    private var clock = 0.0
    let attack = 0.06
    let release = 0.35

    func push(_ raw: Double) { target = min(1, max(0, raw)) }

    func reset() {
        target = 0
        value = 0
    }

    /// The envelope at time `t` (seconds); several reads in one frame agree.
    func level(at t: Double) -> Double {
        let dt = clock == 0 ? 0 : min(0.25, max(0, t - clock))
        clock = t
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-dt / tau))
        if value < 0.002 { value = 0 }
        return value
    }
}

// MARK: - Engine

/// What the engine reads to compute one frame (Famulus' SkinFrameInput, pill only).
struct LisereFrameInput {
    /// Seconds, and since the last frame.
    var t: Double
    var dt: Double
    var phase: PillPhase
    /// The voice envelope while listening, 0 otherwise (Famulus scale).
    var level: Double
    /// Which appearance this is: a new one starts a new light, nothing carried over.
    var appearance: Double
    /// Seconds since the pill appeared.
    var sinceAppear: Double
    /// Leaving: 0 ... 1 as the pill fades (Famulus: 1 - presence), else 0.
    var disappear: Double = 0
    /// Brightest points above SDR white (extended sRGB target).
    var hdr: Bool
}

/// Everything the Liseré light does at one frame: the voice's history along
/// the thread, the rotation, the mood weights, the entrance.
@MainActor
final class LisereEngine {
    private var times: [Double] = []
    private var values: [Double] = []
    private var energy = 0.0
    private var rotation: Double
    /// thinking, done, unknown effects (failure), not understood, typing, question
    /// (the last three are not used by Véloce and stay 0).
    private var weights = [Double](repeating: 0, count: 6)
    private var starts: [PillPhase: Double] = [:]
    private var phase: PillPhase?
    private var appearance = -99.0
    var reduceMotion = false
    /// Something moves fast: 60 frames per second, else 30.
    private(set) var lively = true

    init(rotation: Double = Double.random(in: 0..<1)) {
        self.rotation = rotation
    }

    func uniforms(_ f: LisereFrameInput) -> [SIMD4<Float>] {
        let t = f.t
        let dt = f.dt
        var fresh = false
        if f.appearance != appearance {
            appearance = f.appearance
            times.removeAll()
            values.removeAll()
            energy = 0
            phase = nil
            fresh = true
        }
        let current = f.phase
        if current != phase {
            starts[current] = t
            phase = current
        }
        func age(_ p: PillPhase) -> Double { t - (starts[p] ?? -99) }

        // The light's source: the voice while listening.
        let source = current == .listening ? f.level : 0
        times.append(t)
        values.append(source)
        if let first = times.firstIndex(where: { $0 >= t - 1.4 }), first > 0 {
            times.removeFirst(first)
            values.removeFirst(first)
        }
        var taps = [Float](repeating: 0, count: 16)
        for k in 0..<16 { taps[k] = Float(sample(at: t - Double(k) * 0.08)) }

        energy += (source - energy) * (1 - exp(-dt / (source > energy ? 0.06 : 0.3)))
        let calm = reduceMotion ? 0.3 : 1.0
        // The colours turn round the glass in about ten seconds; the voice spins them up.
        rotation += dt * (0.1 + 0.3 * energy) * calm
        rotation -= floor(rotation)

        // Weights follow the phase smoothly (the light never snaps).
        let targets: [Double] = [
            current == .thinking ? 1 : 0, current == .success ? 1 : 0, current == .failure ? 1 : 0,
            0, 0, 0,
        ]
        let taus: [Double] = [0.12, 0.1, 0.12, 0.2, 0.2, 0.25]
        var moving = false
        for i in 0..<weights.count {
            if fresh { weights[i] = targets[i] } else {
                weights[i] += (targets[i] - weights[i]) * (1 - exp(-dt / taus[i]))
            }
            if weights[i] > 0.01 && weights[i] < 0.99 { moving = true }
        }

        // Leaving: the thread flows back into the source as the pill fades.
        let disappear = min(1, max(0, f.disappear))

        var u = [SIMD4<Float>](repeating: .zero, count: 9)
        u[0] = SIMD4(taps[0], taps[1], taps[2], taps[3])
        u[1] = SIMD4(taps[4], taps[5], taps[6], taps[7])
        u[2] = SIMD4(taps[8], taps[9], taps[10], taps[11])
        u[3] = SIMD4(taps[12], taps[13], taps[14], taps[15])
        u[4] = SIMD4(Float(rotation), Float(f.sinceAppear), Float(age(.thinking) * calm), Float(weights[4]))
        u[5] = SIMD4(Float(weights[0]), Float(weights[1]), Float(weights[2]), Float(weights[3]))
        u[6] = SIMD4(30, 0, 1, 9)
        u[7] = SIMD4(Float(energy), Float(age(.success)), 99, Float(disappear))
        u[8] = SIMD4(0, f.hdr ? 1 : 0, -1, Float(weights[5]))

        lively = f.sinceAppear < 0.6 || disappear > 0 || moving || current == .thinking
            || (taps.max() ?? 0) > 0.01 || energy > 0.01
            || (current == .success && age(.success) < 1.5)
        return u
    }

    /// The source level at time `t`, interpolated in the recent samples.
    private func sample(at t: Double) -> Double {
        guard let lastTime = times.last else { return 0 }
        if t >= lastTime { return values[values.count - 1] }
        // Before the first sample, nothing was said.
        guard t > times[0] else { return 0 }
        var i = times.count - 1
        while i > 1 && times[i - 1] > t { i -= 1 }
        let t0 = times[i - 1], t1 = times[i]
        let k = t1 > t0 ? (t - t0) / (t1 - t0) : 1
        return values[i - 1] + (values[i] - values[i - 1]) * k
    }
}

/// Mirrors the Metal struct SkinCommon.
struct SkinCommonUniforms {
    /// Layer width, height (points), time (s), pixels per point.
    var view = SIMD4<Float>(repeating: 0)
    /// The capsule: x, y, width, height (layer points, top left).
    var pill = SIMD4<Float>(repeating: 0)
}

// MARK: - The light: one Metal layer, its own display link

/// The Metal layer behind the words and above the glass (Famulus' SkinLightView).
@MainActor
final class PillLightView: NSView {
    /// Liseré shines a little past SDR white (EDR).
    static let pixelFormat = MTLPixelFormat.rgba16Float

    private let metal = CAMetalLayer()
    private var link: CADisplayLink?
    private let lisere = LisereEngine()
    private let voice = VoiceEnvelope()
    private var phase: PillPhase?
    private var reduceMotion = false
    private var fps = 0
    private var lastTick = 0.0
    private var clock = 0.0
    private var lastDraw = 0.0
    private var appearedAt = 0.0
    private var visible = false
    /// A calm phase held for 8 s: the light stops (no frame at all).
    private var settled = false
    private var settleTimer: Timer?
    private var occlusion: NSObjectProtocol?
    /// Where the capsule is and how present it is, as animated (the pill's stage).
    private weak var stage: PillStage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        metal.device = PillLightRenderer.shared?.device
        metal.framebufferOnly = true
        metal.isOpaque = false
        metal.backgroundColor = CGColor.clear
        metal.maximumDrawableCount = 3
        metal.anchorPoint = .zero
        metal.pixelFormat = Self.pixelFormat
        metal.wantsExtendedDynamicRangeContent = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
        root.addSublayer(metal)
        PillLightRenderer.shared?.prepare { [weak self] in self?.follow() }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(phase: PillPhase, level: Double, reduceMotion: Bool, stage: PillStage? = nil) {
        if stage !== self.stage {
            self.stage = stage
            stage?.light = self
        }
        voice.push(PillVoiceResponse.meter(level))
        lisere.reduceMotion = reduceMotion
        self.reduceMotion = reduceMotion
        guard phase != self.phase else { return }
        if phase == .listening && self.phase != .listening { voice.reset(); voice.push(PillVoiceResponse.meter(level)) }
        self.phase = phase
        scheduleSettle()
        updateLink()
        // A new state is drawn at once (a settled light still shows it).
        follow()
    }

    /// Famulus: listening, thinking and done are lively moods; the others settle after 8 s.
    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = nil
        settled = false
        guard let phase, phase == .idle || phase == .failure else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.visible, self.phase == .idle || self.phase == .failure else { return }
                self.settled = true
                self.updateLink()
            }
        }
    }

    private var live: Bool { visible && !settled }

    private func updateLink() {
        link?.isPaused = !live
        if !live { lastTick = 0 }
    }

    /// The layout or the state moved: draw now if the link rests.
    func follow() {
        guard visible, window != nil else { return }
        if link?.isPaused ?? true { draw(at: CACurrentMediaTime()) }
    }

    func stop() {
        link?.invalidate()
        link = nil
        settleTimer?.invalidate()
        settleTimer = nil
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
    }

    isolated deinit {
        link?.invalidate()
        settleTimer?.invalidate()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        visible = false
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        fps = 0
        setRate(30)
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        resize()
        visibilityChanged()
    }

    /// The panel is reused: each time it shows, the thread is traced in again.
    private func visibilityChanged() {
        let now = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if now && !visible {
            appearedAt = CACurrentMediaTime()
            voice.reset()
            scheduleSettle()
        }
        visible = now
        updateLink()
        follow()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
    }

    private func resize() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        metal.contentsScale = scale
        CATransaction.commit()
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metal.drawableSize != size { metal.drawableSize = size }
        follow()
    }

    private func setRate(_ rate: Int) {
        guard rate != fps, let link else { return }
        fps = rate
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(rate) / 2, maximum: Float(rate), preferred: Float(rate))
    }

    @objc private func tick(_ link: CADisplayLink) {
        draw(at: link.targetTimestamp)
    }

    /// One frame: the engine's uniforms, one draw, one present.
    private func draw(at target: CFTimeInterval) {
        guard visible, let phase, bounds.width > 1, bounds.height > 1, let renderer = PillLightRenderer.shared,
              let pipeline = renderer.pipeline(Self.pixelFormat) else { return }
        // Two draws for one vsync (a layout change and the link): keep one.
        guard target - lastDraw > 0.003 else { return }
        lastDraw = target
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, max(0, target - lastTick))
        lastTick = target
        clock += dt
        let scale = window?.backingScaleFactor ?? 2
        let pill = PillLightRenderer.pill(in: bounds.size, width: stage?.drawnWidth ?? PillLayout.width)
        let level = phase == .listening ? voice.level(at: target) : 0
        let disappear = stage.map { $0.leaving ? 1 - $0.drawnPresence : 0 } ?? 0
        let input = LisereFrameInput(t: clock, dt: dt, phase: phase, level: level, appearance: appearedAt,
                                     sinceAppear: target - appearedAt, disappear: disappear, hdr: true)
        var common = SkinCommonUniforms()
        common.view = SIMD4(Float(bounds.width), Float(bounds.height), Float(clock), Float(scale))
        common.pill = SIMD4(Float(pill.minX), Float(pill.minY), Float(pill.width), Float(pill.height))
        let skinBytes = lisere.uniforms(input)

        guard let drawable = metal.nextDrawable() else { return }
        renderer.draw(pipeline: pipeline, texture: drawable.texture, drawable: drawable, common: common, lisere: skinBytes)
        setRate(lisere.lively ? 60 : 30)
    }
}

// MARK: - GPU (runtime-compiled shader)

@MainActor
final class PillLightRenderer {
    static let shared = PillLightRenderer()
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var library: MTLLibrary?
    private var pipelines: [UInt: MTLRenderPipelineState] = [:]
    private var compiling = false
    private var waiting: [() -> Void] = []
    private(set) var failed = false

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
    }

    /// Compiles the shader off the main thread (about 0.3 s the first time),
    /// then calls `ready` on the main thread.
    func prepare(ready: (() -> Void)? = nil) {
        if library != nil || failed { ready?(); return }
        if let ready { waiting.append(ready) }
        guard !compiling else { return }
        compiling = true
        device.makeLibrary(source: Self.source, options: MTLCompileOptions()) { library, error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let renderer = PillLightRenderer.shared else { return }
                    renderer.compiling = false
                    if renderer.library == nil { renderer.library = library }
                    if renderer.library == nil {
                        renderer.failed = true
                        FileHandle.standardError.write(Data("Véloce : ERREUR shader Liseré\n\(message ?? "")\n".utf8))
                    }
                    let callbacks = renderer.waiting
                    renderer.waiting.removeAll()
                    callbacks.forEach { $0() }
                }
            }
        }
    }

    /// The pipeline for a target format, once the shader is compiled.
    func pipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let pipeline = pipelines[format.rawValue] { return pipeline }
        guard let library, let vertex = library.makeFunction(name: "skinVertex"),
              let shade = library.makeFunction(name: "lisereFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = shade
        descriptor.colorAttachments[0].pixelFormat = format
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[format.rawValue] = pipeline
        return pipeline
    }

    /// Offline: compile now, on this thread.
    private func compileNow() {
        guard library == nil, !failed else { return }
        do { library = try device.makeLibrary(source: Self.source, options: MTLCompileOptions()) } catch { failed = true }
    }

    /// The capsule centred in the light's canvas (VelocePill's ZStack).
    static func pill(in size: CGSize, width: CGFloat = PillLayout.width) -> CGRect {
        CGRect(x: (size.width - width) / 2, y: (size.height - PillLayout.height) / 2,
               width: width, height: PillLayout.height)
    }

    @discardableResult
    func draw(pipeline: MTLRenderPipelineState, texture: MTLTexture, drawable: CAMetalDrawable? = nil,
              common: SkinCommonUniforms, lisere: [SIMD4<Float>]) -> MTLCommandBuffer? {
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var common = common
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&common, length: MemoryLayout<SkinCommonUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&common, length: MemoryLayout<SkinCommonUniforms>.stride, index: 0)
        lisere.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let drawable { buffer.present(drawable) }
        buffer.commit()
        return buffer
    }

    /// A still frame without any clock: the engine is run offline up to `time`
    /// (also the phase's age), fed by `levelAt` (raw level at past times) so the
    /// voice's pour shows. SDR, 8 bits, sRGB.
    static func snapshot(phase: PillPhase, level: Double, time: Double,
                         levelAt: ((Double) -> Double)? = nil, reduceMotion: Bool = false,
                         width pillWidth: CGFloat = PillLayout.width, sinceAppear: Double = 10,
                         disappear: Double = 0) -> CGImage? {
        guard let renderer = shared else { return nil }
        renderer.compileNow()
        let format = MTLPixelFormat.bgra8Unorm
        guard let pipeline = renderer.pipeline(format) else { return nil }
        let size = PillLayout.canvas
        let width = Int(size.width * 2), height = Int(size.height * 2)

        // Listening needs the last 1.4 s of voice; the other phases start at 0.
        let start = phase == .listening ? time - 1.6 : 0
        let step = 1.0 / 60
        // As if the colours had been turning since 0.
        let engine = LisereEngine(rotation: 0.3 + 0.1 * start)
        engine.reduceMotion = reduceMotion
        let voice = VoiceEnvelope()
        var t = start
        var u: [SIMD4<Float>] = []
        repeat {
            voice.push(PillVoiceResponse.meter(levelAt?(t) ?? level))
            // The envelope's clock starts at 0: keep its times positive.
            let lv = phase == .listening ? voice.level(at: t + 1000) : 0
            u = engine.uniforms(LisereFrameInput(t: t, dt: step, phase: phase, level: lv, appearance: -1,
                                                 sinceAppear: sinceAppear - (time - t), disappear: disappear, hdr: false))
            t += step
        } while t <= time + step * 0.5

        let pill = Self.pill(in: size, width: pillWidth)
        var common = SkinCommonUniforms()
        common.view = SIMD4(Float(size.width), Float(size.height), Float(time), 2)
        common.pill = SIMD4(Float(pill.minX), Float(pill.minY), Float(pill.width), Float(pill.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
              let buffer = renderer.draw(pipeline: pipeline, texture: texture, common: common, lisere: u) else { return nil }
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Shader

    /// Famulus' SkinShader.common (the parts the pill reads) + LisereShader.source,
    /// without the character, the card and the caustics.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SkinCommon {
        float4 view;     // layer width, height (points), time (s), pixels per point
        float4 pill;     // the capsule: x, y, width, height (layer points, top left)
    };

    struct SkinOut {
        float4 position [[position]];
        float2 pos;
    };

    vertex SkinOut skinVertex(uint vid [[vertex_id]], constant SkinCommon& c [[buffer(0)]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        SkinOut o;
        o.position = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
        o.pos = p * c.view.xy;
        return o;
    }

    inline float skHash(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    /// Signed distance to a rounded box centred on 0 (negative inside).
    inline float skRoundBox(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    inline float skPill(float2 p, float2 halfSize) {
        return skRoundBox(p, halfSize, min(halfSize.x, halfSize.y));
    }

    struct LisereU {
        float4 hist[4];  // voice envelope, 16 taps, ages 0, 0.08 ... 1.2 s (newest first)
        float4 a;        // rotation (turns), visible age, thinking age, typing weight
        float4 w;        // thinking, done, unknown effects, not understood
        float4 b;        // pill margin, 0, countdown fraction, card age
        float4 c;        // energy, done age, not-understood age, disappear
        float4 mode;     // 0, hdr, pick age (-1: none), question weight
    };

    constant float LS_PI = 3.14159265;
    constant float LS_TAU = 6.2831853;

    // The flame palette, linear sRGB.
    constant float3 LS_AMBER   = float3(1.000, 0.462, 0.063);
    constant float3 LS_GOLD    = float3(1.000, 0.672, 0.147);
    constant float3 LS_CORAL   = float3(1.000, 0.159, 0.056);
    constant float3 LS_MAGENTA = float3(0.888, 0.063, 0.328);
    constant float3 LS_VIOLET  = float3(0.270, 0.107, 1.000);
    constant float3 LS_CYAN    = float3(0.050, 0.658, 1.000);
    constant float3 LS_MINT    = float3(0.275, 0.672, 0.423);
    // Véloce: failure in coral #FF6F5E (Famulus: LS_RED 1.000, 0.090, 0.070).
    constant float3 LS_RED     = float3(1.000, 0.159, 0.112);
    constant float3 LS_WHITE   = float3(1.000, 0.900, 0.780);

    /// The voice envelope `age` seconds ago.
    inline float lsHist(constant LisereU& L, float age) {
        float x = clamp(age / 0.08, 0.0, 15.0);
        int i = min(int(x), 14);
        float f = x - float(i);
        int j = i + 1;
        return mix(L.hist[i >> 2][i & 3], L.hist[j >> 2][j & 3], f);
    }

    /// Around a loop: amber, coral, magenta, violet, a hint of cyan, amber.
    inline float3 lsLoop(float x) {
        x = fract(x);
        float3 c = LS_AMBER;
        c = mix(c, LS_CORAL, smoothstep(0.00, 0.22, x));
        c = mix(c, LS_MAGENTA, smoothstep(0.22, 0.44, x));
        c = mix(c, LS_VIOLET, smoothstep(0.44, 0.66, x));
        c = mix(c, mix(LS_VIOLET, LS_CYAN, 0.65), smoothstep(0.66, 0.80, x));
        c = mix(c, LS_AMBER, smoothstep(0.84, 1.00, x));
        return c;
    }

    /// From the source (0) to the far end (1): hot to cool.
    inline float3 lsRamp(float x) {
        x = saturate(x);
        float3 c = LS_GOLD;
        c = mix(c, LS_AMBER, smoothstep(0.00, 0.15, x));
        c = mix(c, LS_CORAL, smoothstep(0.12, 0.36, x));
        c = mix(c, LS_MAGENTA, smoothstep(0.32, 0.60, x));
        c = mix(c, LS_VIOLET, smoothstep(0.56, 0.84, x));
        c = mix(c, mix(LS_VIOLET, LS_CYAN, 0.6), smoothstep(0.84, 1.00, x));
        return c;
    }

    /// Arc length along a capsule's edge from its leftmost point, the same on
    /// the top and the bottom edge (0 ... half the perimeter).
    inline float lsCapsuleS(float2 p, float2 hs, thread float& halfP) {
        float r = hs.y;
        float cx = max(hs.x - r, 0.0);
        halfP = LS_PI * r + 2.0 * cx;
        float ay = abs(p.y);
        if (p.x < -cx) return r * atan2(ay, -(p.x + cx));
        if (p.x > cx) return halfP - r * atan2(ay, p.x - cx);
        return r * LS_PI * 0.5 + p.x + cx;
    }

    /// The light's colour as it will be seen: gamma encoded like the rest of
    /// the interface; with `hdr`, the brightest points pass SDR white.
    inline float3 lsSeen(float3 light, float hdr) {
        float3 c = pow(max(light, float3(0.0)), float3(1.0 / 2.2));
        return min(c, float3(hdr > 0.5 ? 1.22 : 1.0));
    }

    /// The thread's section: a crisp core on the glass edge, light entering the
    /// glass, a halo whose hue drifts with distance. Premultiplied.
    inline float4 lsProfile(float d, float I, float3 hue, float gI, float3 glow, float3 film, float width,
                            float inDepth, float inI, float haloR, float haloI,
                            float margin, float px, float hdr) {
        float dd = d + 0.9;
        float core = 1.0 - smoothstep(width * 0.5 - px * 0.5, width * 0.5 + px * 0.8, abs(dd));
        float inner = dd < 0.0 ? exp(dd / inDepth) : 0.0;
        float outer = d > 0.0 ? (0.55 * exp(-d / 1.25) + 0.45 * exp(-d / haloR)) : 0.0;
        outer *= 1.0 - smoothstep(margin * 0.45, margin * 0.95, d);
        float Ic = min(gI, 1.1);
        float3 c = lsSeen(hue * I, hdr);
        float3 ci = lsSeen(glow * Ic, hdr);
        float3 h = lsSeen(film * Ic, hdr);
        float3 rgb = c * core + ci * inner * inI + h * outer * haloI;
        float alpha = core * saturate(0.5 + 0.6 * I) + inner * saturate(inI * Ic) * 0.14
            + outer * saturate(haloI * Ic) * 0.34;
        return float4(rgb, saturate(alpha));
    }

    inline float4 lsPill(float2 pos, constant SkinCommon& sc, constant LisereU& L) {
        float M = L.b.x;
        float2 hs = max(sc.pill.zw * 0.5, float2(2.0));
        float2 p = pos - (sc.pill.xy + sc.pill.zw * 0.5);
        float d = skPill(p, hs);
        if (d > M) return float4(0.0);

        float halfP;
        float s = lsCapsuleS(p, hs, halfP);
        float P = 2.0 * halfP;
        float sLoop = p.y <= 0.0 ? s : P - s;
        float xLoop = sLoop / P;
        float t = sc.view.z;
        float px = 1.0 / max(sc.view.w, 1.0);
        float energy = L.c.x;
        float side = p.y <= 0.0 ? 0.0 : 1.0;
        float rot = L.a.x;
        float spread = max(d, 0.0);
        float wTy = L.a.w, wQ = L.mode.w, wT = L.w.x, wD = L.w.y, wA = L.w.z, wP = L.w.w;
        float calmW = (1.0 - wT) * (1.0 - wD) * (1.0 - wA) * (1.0 - wP);

        // Calm: the whole spectrum turns round the glass, a broad sheen breathes
        // on it and one sharp glint runs a little faster than the colours.
        float sheen = pow(0.5 + 0.5 * cos(LS_TAU * (xLoop - rot * 1.35)), 4.0);
        float glint = pow(0.5 + 0.5 * cos(LS_TAU * (xLoop - t * 0.17 + 0.37)), 36.0) * calmW * (1.0 - wQ);
        float3 hue = lsLoop(xLoop - rot);
        float3 film = lsLoop(xLoop - rot - 0.028 * spread);
        float I = 0.7 + 0.3 * sheen;

        // Voice: the light pours from the left end and takes a little over a
        // second to reach the far end, hot near the source, cooler further on.
        float v = halfP / 1.15;
        float voice = lsHist(L, s / v);
        float fall = 1.0 - 0.3 * s / halfP;
        float pw = saturate(voice * fall * 1.5);
        hue = mix(hue, lsRamp(s / halfP), pw);
        film = mix(film, lsRamp(s / halfP + 0.018 * spread), pw);
        I += voice * fall * 0.75;
        // Sparks ride the flow, head first, leaving the source.
        float cellU = (s - v * t) / 96.0 + side * 0.5;
        float cell = floor(cellU);
        float x = fract(cellU) * 96.0;
        float headX = 30.0 + 50.0 * skHash(float2(cell, side + 3.0));
        float chance = skHash(float2(cell * 1.7, side + 9.0));
        float spark = x < headX ? exp(-(headX - x) / 22.0) : exp(-(x - headX) / 2.6);
        spark *= smoothstep(0.38, 0.7, chance) * smoothstep(0.0, 16.0, x)
            * smoothstep(0.0, 24.0, s) * smoothstep(0.0, 24.0, halfP - s);
        spark = mix(spark, 0.0, saturate(spread / 3.0));
        float sparkI = voice * spark * fall * 1.6;
        float sparkW = 0.45 * saturate(voice * spark * 1.5);
        float lv = saturate(voice * 1.25);
        float inDepth = 2.4 + 3.2 * lv;
        float inI = 0.36 + 0.5 * lv;
        float haloR = 5.0 + 5.5 * max(lv, 0.5 * energy);
        float haloI = 0.55 + 0.45 * lv;

        hue = mix(hue, LS_WHITE, 0.6 * glint);
        film = mix(film, LS_WHITE, 0.35 * glint);
        I += 0.85 * glint;

        // Typing: a steady focus ring, whiter (weight 0 in Véloce).
        hue = mix(hue, mix(hue, LS_WHITE, 0.5), wTy * (1.0 - pw));
        I = mix(I, max(I, 0.62), wTy);

        // A card has the attention (weight 0 in Véloce).
        hue = mix(hue, lsLoop(0.5 + 0.3 * xLoop - rot), wQ * 0.6);
        I *= 1.0 - 0.4 * wQ;
        haloI *= 1.0 - 0.5 * wQ;

        // Thinking: two comets leave the source and chase each other round.
        if (wT > 0.001) {
            float head = fract(L.a.z * 0.8) * P;
            float3 cl = float3(0.0);
            float cI = 0.0;
            for (int k = 0; k < 2; k++) {
                float h = fmod(head + float(k) * halfP, P);
                float behind = fract((h - sLoop) / P) * P;
                float tail = exp(-behind / 90.0);
                float tip = exp(-behind / (7.0 + 1.5 * spread)) * 7.0 / (7.0 + 1.5 * spread);
                tip += exp(-(P - behind) / (2.5 + spread)) * 2.5 / (2.5 + spread);
                float3 col = mix(LS_VIOLET, LS_MAGENTA, exp(-behind / 60.0));
                col = mix(col, LS_GOLD, tip);
                cl += col * (tail * 1.0 + tip * 1.6);
                cI += tail * 1.0 + tip * 1.6;
            }
            float base = 0.28;
            float3 th = mix(lsLoop(xLoop - rot), LS_VIOLET, 0.5) * base + cl;
            float tI = base + cI;
            hue = mix(hue, th / max(tI, 1e-3), wT);
            I = mix(I, tI, wT);
            inDepth = mix(inDepth, 3.5, wT);
            haloR = mix(haloR, 6.0, wT);
        }

        // Done: a wave of mint and gold runs from the source to the far end,
        // closes the loop with a flash, the halo swells once, then settles.
        float settle = 0.0;
        if (wD > 0.001) {
            float age = L.c.y;
            float front = smoothstep(0.0, 0.42, age) * (halfP + 40.0);
            float behindF = front - s;
            float lit = smoothstep(-4.0, 26.0, behindF);
            float crest = exp(-abs(behindF - 8.0) / (11.0 + 1.5 * spread)) * 11.0 / (11.0 + 1.5 * spread)
                * (1.0 - smoothstep(0.32, 0.6, age));
            settle = exp(-max(age - 0.42, 0.0) * 1.3);
            float3 dHue = mix(LS_GOLD, LS_MINT, smoothstep(0.0, 0.4, s / halfP));
            dHue = mix(dHue, mix(LS_MINT, LS_CYAN, 0.35), 0.35 * sheen);
            float meet = exp(-pow((age - 0.4) / 0.1, 2.0)) * exp(-(halfP - s) / (26.0 + spread));
            float dI = lit * (0.6 + 0.5 * settle + 0.14 * sheen) + crest * 1.5 + meet * 1.8;
            float3 dLight = dHue * lit * (0.6 + 0.5 * settle + 0.14 * sheen) + mix(LS_GOLD, LS_WHITE, 0.6) * crest * 1.5
                + mix(LS_MINT, LS_WHITE, 0.6) * meet * 1.8;
            float3 total = dLight + hue * I * (1.0 - lit);
            float totalI = dI + I * (1.0 - lit);
            hue = mix(hue, total / max(totalI, 1e-3), wD);
            I = mix(I, totalI, wD);
            float swell = wD * lit * settle;
            haloR = mix(haloR, 5.0 + 5.0 * swell, wD);
            haloI = mix(haloI, 0.55 + 0.35 * swell, wD);
            inDepth = mix(inDepth, 2.6 + 2.5 * swell, wD);
        }

        // Not understood: a soft "no", the light swings twice then rests, lavender (weight 0 in Véloce).
        if (wP > 0.001) {
            float age = L.c.z;
            float swing = sin(age * LS_TAU * 1.4) * exp(-age * 1.9);
            float bx = swing * hs.x * 0.45;
            float bead = exp(-pow((p.x - bx) / max(hs.x * 0.17, 1.0), 2.0));
            float3 pHue = mix(mix(LS_VIOLET, LS_WHITE, 0.4), LS_WHITE, 0.4 * bead);
            float pI = 0.36 + bead * (0.5 + 0.7 * exp(-age * 1.1));
            hue = mix(hue, pHue, wP);
            I = mix(I, pI, wP);
        }

        // Unknown effects (Véloce: failure): coral, steady, one slow breath.
        if (wA > 0.001) {
            float breath = 0.86 + 0.08 * sin(t * LS_TAU * 0.35);
            hue = mix(hue, LS_RED, wA);
            I = mix(I, 0.92 * breath, wA);
            haloR = mix(haloR, 5.5, wA);
        }
        film = mix(hue, film, calmW);

        // Appear: the thread is drawn from the source both ways and closes at the far end.
        float trace = smoothstep(0.0, 0.3, L.a.y);
        float tf = trace * (halfP + 30.0);
        float drawn = smoothstep(tf, tf - 24.0, s);
        float head = exp(-abs(s - tf + 12.0) / (9.0 + 1.5 * spread)) * 9.0 / (9.0 + 1.5 * spread)
            * (1.0 - smoothstep(0.75, 1.0, trace));
        // Disappear: the thread flows back into the source.
        float gone = L.c.w;
        float kept = (1.0 - gone) * (halfP + 30.0);
        drawn *= smoothstep(kept, kept - 24.0, s);
        I = I * drawn + head * 1.4 * (1.0 - gone);
        hue = mix(hue, LS_WHITE, saturate(head * 0.8));
        film = mix(film, LS_GOLD, saturate(head * 0.6));

        float3 core = mix(hue, LS_WHITE, sparkW);
        float coreI = I + sparkI * drawn;
        float width = 1.5 + 0.7 * saturate(coreI - 0.8) + 0.5 * energy;
        float4 lit = lsProfile(d, coreI, core, I, hue, film, width, inDepth, inI, haloR, haloI, M, px, L.mode.y);

        // Under the light: the glass is smoked in its middle (contrast for the
        // words) and stays clear along its edge, where Liquid Glass refracts.
        float inside = d < 0.0 ? 1.0 : 0.0;
        float smokeA = inside * 0.52 * smoothstep(0.5, 10.0, -d);
        float3 smoke = mix(float3(0.034, 0.026, 0.023), float3(0.2, 0.032, 0.022), wA) * smokeA;
        float3 rgb = lit.rgb + smoke * (1.0 - lit.a);
        float alpha = lit.a + smokeA * (1.0 - lit.a);

        // Thinking: a band of light crosses the glass behind the dimmed line.
        if (wT > 0.001) {
            float span = 2.0 * hs.x + 240.0;
            float x = -hs.x - 120.0 + fract(t / 1.05) * span;
            float dx = (p.x - x) / 40.0;
            float sweep = exp(-dx * dx) * inside * smoothstep(0.5, 12.0, -d) * wT;
            float3 sweepC = mix(mix(LS_GOLD, LS_WHITE, 0.5), LS_MAGENTA, smoothstep(-0.4, 1.0, dx));
            rgb += lsSeen(sweepC, L.mode.y) * sweep * 0.3;
            alpha += sweep * 0.06;
        }
        return float4(rgb, saturate(alpha));
    }

    fragment float4 lisereFragment(SkinOut in [[stage_in]], constant SkinCommon& c [[buffer(0)]],
                                   constant LisereU& L [[buffer(1)]]) {
        float2 p = in.pos;
        return c.pill.z > 1.0 ? lsPill(p, c, L) : float4(0.0);
    }
    """
}
