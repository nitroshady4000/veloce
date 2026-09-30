import AppKit
import Metal
import QuartzCore
import SwiftUI
import simd

/// One small GPU layer owns both the V and its light; no SwiftUI layout per frame.
/// Palette, breath and envelope timing follow Famulus's Feu follet design.
struct PillLight: View {
    var phase: PillPhase
    var level: Double
    var reduceMotion: Bool
    var frozenTime: Double? = nil

    var body: some View {
        if let frozenTime, let image = PillLightRenderer.snapshot(phase: phase, level: level, time: frozenTime) {
            Image(decorative: image, scale: 2).resizable()
        } else if PillLightRenderer.shared == nil {
            HStack {
                VeloceMark(size: 40, color: VeloceTheme.gold)
                Spacer()
            }.padding(.leading, PillLayout.margin + 10)
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
                    if self.window?.isVisible == true {
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
        targetLevel = phase == .listening ? max(0, min(1, level)) : 0
        self.reduceMotion = reduceMotion
        guard window != nil else { return }
        // Meter updates only feed the envelope. The animation clock owns frames.
        if stateChanged { drawFrame() }
        if shouldAnimate { resume() } else { stop() }
    }
    private var shouldAnimate: Bool {
        !reduceMotion && (phase == .listening || phase == .thinking ||
            (phase == .success && CACurrentMediaTime() - phaseSince <= 1.2))
    }
    private func resume() {
        guard timer == nil, shouldAnimate, window?.isVisible == true,
              !isHiddenOrHasHiddenAncestor else { return }
        lastTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
    private func drawFrame() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { stop(); return }
        guard let renderer else { stop(); return }
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastTime)); lastTime = now
        let tau = targetLevel > envelope ? 0.06 : 0.35
        envelope += (targetLevel - envelope) * (1 - exp(-dt / tau))
        // Integrating the speed avoids jumps when the microphone level changes.
        flow += dt * (40 + 120 * envelope)
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.draw(texture: drawable.texture, drawable: drawable, phase: phase,
                      level: reduceMotion ? 0 : envelope, time: reduceMotion ? 0 : now - appearedAt,
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
              let command = renderer.draw(texture: texture, phase: phase, level: level, time: time, age: 0.25, flow: time * (40 + 120 * level)) else { return nil }
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
        float2 center=float2(58.24,56);
        // The dark glass below is a native view. This layer draws only its light.
        float capsule=seg(p,float2(58.24,56),float2(360,56))-28;
        float bulb=length(p-center)-33;
        float h=clamp(.5+.5*(capsule-bulb)/12,0.0,1.0);
        float d=mix(capsule,bulb,h)-12*h*(1-h);
        float heat=clamp(1-(p.x-center.x)/365,.10,1.0);
        float wave=.5+.5*sin((p.x-center.x-flow)*.034);
        float angle=atan2((p.y-56)*2.4,p.x-208);
        float comet=pow(.5+.5*cos(angle-t*5.0265),16.0);
        float bloom=done ? exp(-pow((length(p-center)-age*900)/48,2.0)) : 0;
        float energy=.34+(listening ? voice*(.4+.5*wave):0)+(thinking ? .6*comet:0)+bloom*.7;
        float3 color=fire(heat*.85+wave*.10);
        if(done) color=mix(float3(.56,.84,.68),float3(1,.95,.82),heat*.5);
        if(failed) color=float3(1,.416,.36);
        float rim=exp(-d*d/1.3)*energy;
        float halo=exp(-abs(d)/4.0)*energy*.10;
        float3 rgb=color*(rim+halo);
        float alpha=clamp(rim+halo,0.0,.93);
        // A legible V, no face or flame silhouette. Organic motion bends the
        // arms slightly; the negative space remains open throughout the cycle.
        float breath=sin(t*1.6);
        float noise=sin(t*1.13)*.55+sin(t*2.31+.7)*.27+sin(t*.71+2)*.18;
        float hop=done && age<1.2 ? sin(age*10.053)*exp(-age*2.8)*3.6 : 0;
        float2 q=p-center+float2(0,hop);
        q/=float2(1-breath*.009+voice*.02,1+breath*.016+voice*.05);
        float sway=(thinking ? 1.1:.6)*noise;
        q.x-=sway*(.4-q.y/36);
        float2 a=float2(-12.6,-8.4), b=float2(-2.6,13.0), c=float2(17.4,-15.4);
        a.x-=voice*.55; c.x+=voice*.7;
        float vd=min(seg(q,a,b),seg(q,b,c))-2.7;
        float core=1-smoothstep(-.65,.7,vd);
        float aura=exp(-max(vd,0.0)/3.3)*.20;
        float glimmer=.72+.12*sin(t*2.2-q.y*.13)+voice*.12;
        float3 vc=fire(clamp(.82-q.y*.005+noise*.04+voice*.08,0.0,1.0));
        if(done) vc=mix(float3(.56,.84,.68),float3(1,.96,.82),.55);
        if(failed) vc=float3(1,.416,.36);
        float va=clamp(core+aura,0.0,1.0);
        rgb=mix(rgb,vc*glimmer,core)+vc*aura*(1-core);
        alpha=va+alpha*(1-va);
        // RGB stays premultiplied for a transparent CAMetalLayer.
        return float4(min(rgb,float3(alpha)),alpha);
    }
    """
}
