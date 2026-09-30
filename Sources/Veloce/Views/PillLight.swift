import AppKit
import Metal
import QuartzCore
import SwiftUI
import simd

/// One small GPU layer carries the light; no SwiftUI layout per frame.
/// The warm palette follows Famulus, while the shape stays a plain capsule.
struct PillLight: View {
    var phase: PillPhase
    var level: Double
    var reduceMotion: Bool
    var frozenTime: Double? = nil

    var body: some View {
        if let frozenTime, let image = PillLightRenderer.snapshot(phase: phase, level: level, time: frozenTime) {
            Image(decorative: image, scale: 2).resizable()
        } else if PillLightRenderer.shared == nil {
            PillOutline().stroke(phase == .failure ? VeloceTheme.coral : VeloceTheme.gold,
                                 lineWidth: phase == .listening ? 1.8 : 0.8)
                .opacity(phase == .listening ? 0.45 + PillVoiceResponse.amplitude(level) * 0.5 : 0.45)
                .frame(width: PillLayout.width, height: PillLayout.height)
        } else {
            LivePillLight(phase: phase, level: level, reduceMotion: reduceMotion)
        }
    }
}

private struct LivePillLight: NSViewRepresentable {
    var phase: PillPhase
    var level: Double
    var reduceMotion: Bool
    func makeNSView(context: Context) -> PillLightView { PillLightView() }
    func updateNSView(_ view: PillLightView, context: Context) {
        view.configure(phase: phase, level: level, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: PillLightView, coordinator: ()) { view.stop() }
}

@MainActor
private final class PillLightView: NSView {
    private let renderer = PillLightRenderer.shared
    private let metalLayer = CAMetalLayer()
    private var timer: Timer?
    private var phase: PillPhase = .idle
    private var targetLevel = 0.0
    private var envelope = 0.0
    private var reduceMotion = false
    private var lastTime = CACurrentMediaTime()
    private var appearedAt = CACurrentMediaTime()
    private var phaseSince = CACurrentMediaTime()
    private var flow: Double = 0
    private var visibilityObserver: NSObjectProtocol?

    init() {
        super.init(frame: CGRect(origin: .zero, size: PillLayout.canvas))
        wantsLayer = true
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        layer = metalLayer
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        visibilityObserver = nil
        if let window {
            appearedAt = CACurrentMediaTime()
            visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.isVisibleForRendering {
                        self.resume()
                        self.drawFrame()
                    } else { self.stop() }
                }
            }
            resume()
            drawFrame()
        } else { stop() }
    }
    override func layout() {
        super.layout()
        resizeDrawable()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeDrawable()
    }
    private func resizeDrawable() {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()),
                          height: max(1, (bounds.height * scale).rounded()))
        guard metalLayer.contentsScale != scale || metalLayer.drawableSize != size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        CATransaction.commit()
        drawFrame()
    }
    func configure(phase: PillPhase, level: Double, reduceMotion: Bool) {
        let stateChanged = self.phase != phase || self.reduceMotion != reduceMotion
        if self.phase != phase { phaseSince = CACurrentMediaTime() }
        self.phase = phase
        targetLevel = phase == .listening ? PillVoiceResponse.amplitude(level) : 0
        self.reduceMotion = reduceMotion
        guard window != nil else { return }
        // Meter updates only feed the envelope. The animation clock owns frames.
        // With reduced motion the color still reflects speech, without a clock.
        if stateChanged || reduceMotion { drawFrame() }
        if shouldAnimate { resume() } else { stop() }
    }
    private var shouldAnimate: Bool {
        !reduceMotion && (phase == .listening || phase == .thinking ||
            (phase == .success && CACurrentMediaTime() - phaseSince <= 1.2))
    }
    private func resume() {
        guard timer == nil, shouldAnimate, isVisibleForRendering else { return }
        lastTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drawFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    isolated deinit {
        timer?.invalidate()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }
    private var isVisibleForRendering: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }
    private func drawFrame() {
        guard isVisibleForRendering else { stop(); return }
        guard let renderer else { stop(); return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastTime)); lastTime = now
        let tau = targetLevel > envelope ? 0.035 : 0.17
        if reduceMotion { envelope = targetLevel }
        else { envelope += (targetLevel - envelope) * (1 - exp(-dt / tau)) }
        // Integrating the speed avoids jumps when the microphone level changes.
        flow += dt * (58 + 230 * envelope)
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.draw(texture: drawable.texture, drawable: drawable, phase: phase,
                      level: envelope, time: reduceMotion ? 0 : now - appearedAt,
                      // A reduced-motion success uses its settled pose, never a hop.
                      age: reduceMotion ? 1.3 : now - phaseSince, flow: reduceMotion ? 0 : flow)
        if reduceMotion || phase == .idle || (phase == .success && now - phaseSince > 1.2) || phase == .failure { stop() }
    }
}

@MainActor
final class PillLightRenderer {
    static let shared = PillLightRenderer()
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "pillVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "pillFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            self.device = device; self.queue = queue
        } catch { return nil }
    }

    @discardableResult
    func draw(texture: MTLTexture, drawable: CAMetalDrawable? = nil, phase: PillPhase,
              level: Double, time: Double, age: Double, flow: Double) -> MTLCommandBuffer? {
        guard let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let uniforms: [SIMD4<Float>] = [
            SIMD4(Float(PillLayout.canvas.width), Float(PillLayout.canvas.height), Float(time), Float(level)),
            SIMD4(Float(phase.rawValue), Float(age), Float(flow), 0)
        ]
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { data in
            encoder.setFragmentBytes(data.baseAddress!, length: data.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let drawable { command.present(drawable) }
        command.commit()
        return command
    }

    static func snapshot(phase: PillPhase, level: Double, time: Double) -> CGImage? {
        guard let renderer = shared else { return nil }
        let width = Int(PillLayout.canvas.width * 2), height = Int(PillLayout.canvas.height * 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
              let command = renderer.draw(texture: texture, phase: phase, level: PillVoiceResponse.amplitude(level),
                                          time: time, age: 0.25,
                                          flow: time * (58 + 230 * PillVoiceResponse.amplitude(level))) else { return nil }
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Raster { float4 position [[position]]; float2 uv; };
    vertex Raster pillVertex(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        return { float4(p * float2(2,-2) + float2(-1,1), 0, 1), p };
    }
    float seg(float2 p, float2 a, float2 b) {
        float2 v = b-a; return length(p-a-v*clamp(dot(p-a,v)/dot(v,v),0.0,1.0));
    }
    float3 fire(float h) {
        float x = clamp(h, 0.0, 1.0) * 5;
        float3 c = mix(float3(.24,.44,1),float3(.53,.33,1),clamp(x,0.0,1.0));
        c = mix(c,float3(.94,.30,.66),clamp(x-1,0.0,1.0));
        c = mix(c,float3(1,.45,.30),clamp(x-2,0.0,1.0));
        c = mix(c,float3(1,.69,.30),clamp(x-3,0.0,1.0));
        return mix(c,float3(1,.88,.64),clamp(x-4,0.0,1.0));
    }
    fragment float4 pillFragment(Raster in [[stage_in]], constant float4 *u [[buffer(0)]]) {
        float2 p = in.uv * u[0].xy;
        float t=u[0].z, voice=u[0].w, state=u[1].x, age=u[1].y, flow=u[1].z;
        bool listening=state==1, thinking=state==2, done=state==3, failed=state==4;
        // This geometry is exactly the native capsule below: no character layer.
        float d=seg(p,float2(56,56),float2(360,56))-28;
        float x=(p.x-28)/360;
        float wave=.5+.5*sin((p.x-flow)*.039 + sin(t*1.3)*.65);
        float breath=.5+.5*sin(t*2.5);
        float angle=atan2((p.y-56)*3.4,p.x-208);
        float comet=pow(.5+.5*cos(angle-t*4.8),9.0);
        float bloom=done ? exp(-age*3.2) : 0;
        float energy=.38;
        if(listening) energy=.56 + .18*breath + voice*(.85+.70*wave);
        if(thinking) energy=.55 + .95*comet;
        if(done) energy=.62 + bloom*.65;
        if(failed) energy=.62;
        // Speech shifts the palette through pink, coral and gold, and widens the
        // light along the edge. Silent listening still has a gentle breathing glow.
        float heat=.24 + .47*(1-x) + .16*wave + (listening ? voice*.22 : 0);
        float3 color=fire(heat);
        if(done) color=mix(float3(.56,.84,.68),float3(1,.95,.82),wave*.2);
        if(failed) color=float3(1,.416,.36);
        float thickness=1.0 + (listening ? voice*1.0 : 0);
        float rim=exp(-d*d/(thickness*thickness))*energy*.85;
        float halo=exp(-abs(d)/(4.2+(listening ? voice*4.5 : 0)))*energy*.14;
        // Keep the centre quiet enough for readable type; most depth stays near
        // the lower edge and around the ends of the capsule.
        float inside=1-smoothstep(-.5,1.5,d);
        float under=exp(-pow((p.y-76)/13,2.0));
        float pool=inside*under*(listening ? .065+voice*.15 : (thinking ? .075+.07*comet : .035));
        float glow=rim+halo+pool;
        float3 rgb=color*glow;
        float alpha=clamp(glow,0.0,.96);
        // RGB stays premultiplied for a transparent CAMetalLayer.
        return float4(min(rgb,float3(alpha)),alpha);
    }
    """
}
