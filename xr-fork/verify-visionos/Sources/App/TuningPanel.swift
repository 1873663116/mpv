import SwiftUI
import os

/// 运行时调参面板(ADR 0008 后续):把 libplacebo/mpv 的色彩/tone/gamut 旋钮在播放时全部暴露,
/// 让用户戴头显边播边拧、对着 AV 屏找最贴的一组,再导出固化进生产。
///
/// 设计(与用户采访结论一致):
/// - 5 个信号流二级菜单(①测源峰值 ②出口箱子 ③tone曲线 ④色域+均衡器 ⑤诊断)。
/// - 所有旋钮经 `mpv_set_property_string` 运行时热切(gpu-next render 选项组 UPDATE_VIDEO,下一帧生效)。
/// - `target-prim`/`target-trc` 只读焊死(IOSurface↔合成器契约:扩展线性 Display-P3,改它需放弃 mpv 出口)。
/// - 顶部常驻:可拖进度条 + 播放/暂停 + 跳 2s/27s;实时 fp16 仪表;复位 / A-B 双槽 / 导出 / 记住上次。
/// - libmpv C 侧零改动——纯消费端 Swift。

// MARK: - 参数清单(数据驱动:一张表既驱动 UI 控件,又驱动 mpv 属性名)

struct TuneParam: Identifiable {
    enum Kind {
        case choice([String])          // 下拉
        case slider(Double, Double)    // 滑块 min…max(浮点)
        case toggle                    // 开关(yes/no)
        case readonly                  // 只读展示
    }
    var id: String { prop }
    let prop: String       // mpv 属性名
    let label: String      // 显示名
    let group: Int         // 二级菜单 1–5
    let kind: Kind
    let def: String        // 默认值(复位用,= 策略一基线)
    let blurb: String      // 一行说明
}

enum TuneInventory {
    static let groupNames = ["① 测源峰值", "② 出口箱子", "③ tone 曲线", "④ 色域 + 均衡器", "⑤ 诊断"]

    static let all: [TuneParam] = [
        // ① 测源峰值(动态测峰组)
        .init(prop: "hdr-compute-peak", label: "动态测峰", group: 1, kind: .choice(["auto", "yes", "no"]), def: "auto",
              blurb: "逐帧 GPU 实测源峰值喂给 tone 曲线;no=只信元数据(本样片元数据退化会压崩高光)。auto 本路径≈yes"),
        .init(prop: "hdr-peak-percentile", label: "测峰分位", group: 1, kind: .slider(90, 100), def: "99.9",
              blurb: "忽略最亮的 0.x% 离群点,免一个高光点拖累全画面;越低越激进"),
        .init(prop: "hdr-peak-decay-rate", label: "测峰平滑", group: 1, kind: .slider(1, 100), def: "20",
              blurb: "峰值随时间平滑(类眼睛适应);越大越跟手、越小越稳"),
        .init(prop: "hdr-scene-threshold-low", label: "换场阈值·低", group: 1, kind: .slider(0, 20), def: "1",
              blurb: "判定切换镜头的下阈值(dB),触发峰值重测"),
        .init(prop: "hdr-scene-threshold-high", label: "换场阈值·高", group: 1, kind: .slider(0, 20), def: "3",
              blurb: "判定切换镜头的上阈值(dB)"),

        // ② 出口箱子(target-*;prim/trc 只读焊死)
        .init(prop: "target-prim", label: "出口色域", group: 2, kind: .readonly, def: "display-p3",
              blurb: "焊死:Vision Pro 屏 = Display-P3(92% DCI-P3)。改它需放弃 mpv 出口"),
        .init(prop: "target-trc", label: "出口编码", group: 2, kind: .readonly, def: "linear",
              blurb: "焊死:合成器只认「扩展线性」输入(已查实)。与 SDR/HDR 无关,HDR=值能>1.0"),
        .init(prop: "target-peak", label: "出口峰值 nits", group: 2, kind: .slider(100, 2000), def: "406",
              blurb: "箱子多高=headroom。406=2.0×203=对齐真机 headroom 2.0;取高了>2.0 会被显示器硬截过曝"),
        .init(prop: "hdr-reference-white", label: "参考白 nits", group: 2, kind: .slider(50, 1000), def: "183",
              blurb: "tone 曲线拐点锚;ITU 约定 203,真机实测降低=软肩更早收高光、保护极亮(故默认 183)"),
        .init(prop: "target-contrast", label: "出口黑位", group: 2, kind: .choice(["inf", "auto", "100000", "10000", "1000"]), def: "inf",
              blurb: "对比度上限/黑点。inf=真黑(OLED/Vision Pro);有限值会抬黑底→发灰"),

        // ③ tone 曲线
        .init(prop: "tone-mapping", label: "tone 曲线", group: 3,
              kind: .choice(["bt.2390", "bt.2446a", "spline", "auto", "clip", "reinhard", "mobius", "hable", "gamma", "linear", "st2094-40", "st2094-10"]),
              def: "bt.2390",
              blurb: "把源亮度压进箱子的曲线。bt.2390=带软肩的教科书正解;clip=硬裁(过曝);auto=spline"),
        .init(prop: "tone-mapping-param", label: "曲线微调", group: 3, kind: .slider(0, 2), def: "0",
              blurb: "给当前曲线那个内部常数微调(spline 对比度 / reinhard 参考白落点…),含义随曲线变;bt.2390 不吃此参数"),
        .init(prop: "inverse-tone-mapping", label: "反向 tone-map", group: 3, kind: .toggle, def: "no",
              blurb: "把 SDR/低动态内容反向往 HDR 抬(扩展)。一般关"),
        .init(prop: "tone-mapping-max-boost", label: "最大提亮", group: 3, kind: .slider(1, 10), def: "1",
              blurb: "允许曲线额外提亮多少倍;1=不额外提亮"),
        .init(prop: "hdr-contrast-recovery", label: "对比度找回", group: 3, kind: .slider(0, 2), def: "0.15",
              blurb: "tone-map 压完后,从源把高频对比度细节找补回来;太高会出振铃(默认调温和)"),
        .init(prop: "hdr-contrast-smoothness", label: "找回平滑度", group: 3, kind: .slider(1, 100), def: "100",
              blurb: "对比度找回的平滑半径;拉宽=只找回极低频对比,很轻"),

        // ④ 色域 + 均衡器
        .init(prop: "gamut-mapping-mode", label: "色域映射", group: 4,
              kind: .choice(["clip", "perceptual", "relative", "absolute", "saturation", "desaturate", "darken", "linear", "warn", "auto"]),
              def: "clip",
              blurb: "越出 P3 的颜色怎么收。clip=硬裁(域内满饱和,Apple 风);perceptual=连域内也去饱和(发淡);warn=标红诊断"),
        .init(prop: "saturation", label: "饱和度", group: 4, kind: .slider(-100, 100), def: "9",
              blurb: "全局饱和度补偿;补静态管线相对 AV 的欠饱和。判据:面板「饱和 p90」对齐源 ~0.30,勿过冲"),
        .init(prop: "brightness", label: "亮度", group: 4, kind: .slider(-100, 100), def: "0",
              blurb: "均衡器:整体提暗/提亮(线性偏移)"),
        .init(prop: "contrast", label: "对比度", group: 4, kind: .slider(-100, 100), def: "10",
              blurb: "均衡器:对比度补偿(注意与②的『出口黑位 target-contrast』是两回事)"),
        .init(prop: "gamma", label: "Gamma", group: 4, kind: .slider(-100, 100), def: "1",
              blurb: "均衡器:中间调亮度(幂曲线)"),
        .init(prop: "hue", label: "色相", group: 4, kind: .slider(-100, 100), def: "0",
              blurb: "均衡器:整体色相旋转"),

        // ⑤ 诊断
        .init(prop: "tone-mapping-visualize", label: "可视化曲线", group: 5, kind: .toggle, def: "no",
              blurb: "把当前 tone 曲线画在画面上,边拧边看肩部怎么变形"),
    ]

    static func group(_ g: Int) -> [TuneParam] { all.filter { $0.group == g } }
    static var defaults: [String: String] { Dictionary(uniqueKeysWithValues: all.map { ($0.prop, $0.def) }) }
    /// 导出/复位时遍历的「可写」属性(排除只读契约参数)。
    static var writable: [TuneParam] { all.filter { if case .readonly = $0.kind { return false } else { return true } } }
}

// MARK: - 调参状态(接线由 VerifyModel 提供;面板只观察它)

@MainActor
@Observable
final class TuningStore {
    /// 每个属性的当前值(字符串,UI 与 mpv 共用同一真相)。
    var values: [String: String] = TuneInventory.defaults
    /// 实时 fp16 仪表(读 IOSurface 字节,显示无关)。
    var mGt1 = 0.0
    var mP1 = 0.0
    var mSat = 0.0
    var mGt2 = 0.0
    var metricsLive = false
    /// [xr-perf] 实时仪表(fp16 色彩采样)总开关,默认**关**。开启会每 poll tick 在主线程锁 IOSurface
    /// 并遍历整帧像素(随分辨率涨,8K 每秒数百万次 + 大数组排序),是自伤性卡顿源 —— 仅 fp16 调色时手动开。
    var metricsEnabled = false
    /// 进度条。
    var pos = 0.0
    var dur = 0.0
    var scrubbing = false
    /// A/B 槽快照。
    var slotA: [String: String]?
    var slotB: [String: String]?
    var lastExport = ""
    /// 暂停态镜像(由 VerifyModel.togglePause 同步;面板按钮文案用)。
    var isPaused = false
    /// roll-off 归属:false=mpv 软肩,true=RealityKit tone map(二者互斥)。
    var rollOffRealityKit = false
    /// EDR 曝光乘子:<1 消费端衰减,>1 联动 target-peak 提亮。
    var edrExposure = 1.0
    /// [xr-perf 杠杆2] 像素格式路由模式(自动/强制)+ 分辨率上限调试开关。改它走 reload 重建面。
    var routeMode: XRRouteMode = .auto
    var resolutionCapOn = false
    /// [xr-perf 测量] 冻结换材质开关(诊断:摘掉换材质/重摄取,只留采样;读 renderFPS 定瓶颈)。
    var freezeSwap = false

    // 由 VerifyModel 接线的回调:
    var setCb: (String, String) -> Void = { _, _ in }
    var getCb: (String) -> String? = { _ in nil }
    var seekCb: (Double) -> Void = { _ in }
    var toggleCb: () -> Void = {}
    var sampleCb: () -> (gt1: Double, p1: Double, sat: Double, gt2: Double)? = { nil }
    var timeCb: () -> (pos: Double, dur: Double)? = { nil }
    /// 连续漂移校正(每轮询 tick 调一次,VerifyModel 决定是否重对齐)。
    var syncCb: () -> Void = {}
    /// 重载视频(重建 IOSurface 按原生分辨率 + 重启 mpv,免杀后台)。
    var reloadCb: () -> Void = {}
    /// 切 roll-off 归属(true=RealityKit)。
    var rollOffCb: (Bool) -> Void = { _ in }
    /// 改 EDR 曝光乘子。
    var exposureCb: (Double) -> Void = { _ in }
    /// [xr-perf 杠杆2] 切像素格式路由模式 / 分辨率上限(均走 reload 重建面)。
    var routeModeCb: (XRRouteMode) -> Void = { _ in }
    var resolutionCapCb: (Bool) -> Void = { _ in }
    /// [xr-perf 测量] 冻结/恢复消费端换材质。
    var freezeSwapCb: (Bool) -> Void = { _ in }

    private let log = Logger(subsystem: "enchron.verify.visionos", category: "tune")
    private var poll: Task<Void, Never>?
    private let persistKey = "xr.tuning.values"

    /// mpv 起好后由 VerifyModel 调:读回当前生效值 → 叠加上次持久化 → 启动轮询。
    func attach() {
        // 1) 以 mpv 当前生效值为基线
        for p in TuneInventory.all {
            if let v = getCb(p.prop), !v.isEmpty { values[p.prop] = v }
        }
        // 2) 叠加上次持久化的覆盖,并写回 mpv
        if let saved = UserDefaults.standard.dictionary(forKey: persistKey) as? [String: String] {
            for p in TuneInventory.writable where saved[p.prop] != nil {
                values[p.prop] = saved[p.prop]!
                setCb(p.prop, saved[p.prop]!)
            }
            log.info("[xr-tune] 恢复上次持久化 \(saved.count) 项")
        }
        startPolling()
    }

    func set(_ prop: String, _ value: String) {
        values[prop] = value
        setCb(prop, value)
        persist()
    }

    private func persist() {
        let w = Dictionary(uniqueKeysWithValues: TuneInventory.writable.map { ($0.prop, values[$0.prop] ?? $0.def) })
        UserDefaults.standard.set(w, forKey: persistKey)
    }

    func reset() {
        for p in TuneInventory.writable {
            values[p.prop] = p.def
            setCb(p.prop, p.def)
        }
        persist()
        log.info("[xr-tune] 复位到策略一默认")
    }

    func saveSlot(_ which: String) {
        let snap = values
        if which == "A" { slotA = snap } else { slotB = snap }
        log.info("[xr-tune] 存槽 \(which, privacy: .public)")
    }

    func loadSlot(_ which: String) {
        guard let snap = (which == "A" ? slotA : slotB) else { return }
        for p in TuneInventory.writable {
            let v = snap[p.prop] ?? p.def
            values[p.prop] = v
            setCb(p.prop, v)
        }
        persist()
        log.info("[xr-tune] 切到槽 \(which, privacy: .public)")
    }

    /// 导出当前全部可写值为一行(可拷贝 + 落日志,方便报回/固化进生产)。
    @discardableResult
    func export() -> String {
        let s = TuneInventory.writable
            .map { "\($0.prop)=\(values[$0.prop] ?? $0.def)" }
            .joined(separator: " ")
        lastExport = s
        log.info("[xr-tune] 导出当前配置: \(s, privacy: .public)")
        return s
    }

    func seek(_ t: Double) { seekCb(t) }
    func setRollOff(realityKit: Bool) { rollOffRealityKit = realityKit; rollOffCb(realityKit) }
    func setExposure(_ m: Double) { edrExposure = m; exposureCb(m) }
    func reload() { reloadCb() }
    func setRouteMode(_ m: XRRouteMode) { routeMode = m; routeModeCb(m) }
    func setResolutionCap(_ on: Bool) { resolutionCapOn = on; resolutionCapCb(on) }
    func setFreezeSwap(_ on: Bool) { freezeSwap = on; freezeSwapCb(on) }

    private func startPolling() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.syncCb()                       // 连续漂移校正(播放中把 AV 重对齐 mpv 主钟)
                if self.metricsEnabled, let m = self.sampleCb() {   // 默认关:重采样仅调色时开,避免主线程卡顿
                    self.mGt1 = m.gt1; self.mP1 = m.p1; self.mSat = m.sat; self.mGt2 = m.gt2
                    self.metricsLive = true
                }
                if let t = self.timeCb() {
                    self.dur = t.dur
                    if !self.scrubbing { self.pos = t.pos }
                }
                try? await Task.sleep(nanoseconds: 350_000_000)   // ~3Hz
            }
        }
    }

    func stop() { poll?.cancel(); poll = nil }
}

// MARK: - 面板视图(挂进控制窗的 NavigationStack)

struct TuningPanelView: View {
    @Bindable var store: TuningStore
    /// 跳到对照帧的回调(2s / 27s),由 VerifyModel 提供。
    var jump: (Double) -> Void

    var body: some View {
        List {
            Section("传输") { transport }
            Section("出口格式 · 带宽(杠杆2)") { routing }
            Section("实时仪表 · fp16 字节(显示无关)") { metrics }
            Section("消费端 · RealityKit(非 mpv)") { consumer }
            Section("配置") { config }
            Section("参数(5 个二级菜单)") {
                ForEach(1...5, id: \.self) { g in
                    NavigationLink(TuneInventory.groupNames[g - 1]) {
                        ParamGroupView(store: store, group: g)
                            .navigationTitle(TuneInventory.groupNames[g - 1])
                    }
                }
            }
        }
        .navigationTitle("调参面板")
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(store.isPaused ? "▶ 继续" : "⏸ 暂停") { store.toggleCb() }
                Button("跳 2s") { store.scrubbing = false; jump(2) }
                Button("跳 27s") { store.scrubbing = false; jump(27) }
                Spacer()
                Text(timeLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)   // List 行内多按钮必须显式 borderless,否则整行被当一个点击目标
            Slider(value: Binding(get: { store.pos }, set: { store.pos = $0 }),
                   in: 0...max(store.dur, 0.1),
                   onEditingChanged: { editing in
                       store.scrubbing = editing
                       if !editing { store.seek(store.pos) }
                   })
        }
    }

    private var timeLabel: String {
        func f(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        return "\(f(store.pos)) / \(f(store.dur))"
    }

    /// [xr-perf 杠杆2] 出口像素格式路由 + 分辨率上限调试开关(改任一会重载一次)。
    private var routing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("像素格式", selection: Binding(
                get: { store.routeMode },
                set: { store.setRouteMode($0) })) {
                Text("自动").tag(XRRouteMode.auto)
                Text("SDR 8bit").tag(XRRouteMode.forceSDR)
                Text("HDR fp16").tag(XRRouteMode.forceHDR)
            }
            .pickerStyle(.segmented)
            Text("自动 = 读源元数据:SDR→8-bit sRGB(带宽腰斩、无损);HDR→fp16 线性。切换重载一次。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("分辨率上限 1920(调试 · 硬吃)", isOn: Binding(
                get: { store.resolutionCapOn },
                set: { store.setResolutionCap($0) }))
            Text("应急杠杆,会降画质;正解是上面的格式路由。开/关都重载一次。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("实时仪表(吃 CPU·仅 fp16 调色时开)", isOn: Binding(
                get: { store.metricsEnabled },
                set: { store.metricsEnabled = $0 }))
            .font(.system(size: 12))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    metricCell(">1.0 高光", String(format: "%.2f%%", store.mGt1), good: store.mGt1 > 3)
                    metricCell(">2.0 过曝", String(format: "%.2f%%", store.mGt2), good: store.mGt2 < 1, lowerBetter: true)
                }
                GridRow {
                    metricCell("黑位 p1", String(format: "%.4f", store.mP1), good: store.mP1 < 0.001, lowerBetter: true)
                    metricCell("饱和 p90", String(format: "%.3f", store.mSat), good: store.mSat > 0.25)
                }
            }
            .font(.system(size: 13, design: .monospaced))
        }
    }

    private func metricCell(_ name: String, _ value: String, good: Bool, lowerBetter: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(name).foregroundStyle(.secondary)
            Text(value).foregroundStyle(good ? .green : .primary)
        }
    }

    /// 消费端旋钮(RealityKit/材质,非 mpv):roll-off 归属 + EDR 曝光乘子。
    private var consumer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("roll-off 归属", selection: Binding(
                get: { store.rollOffRealityKit },
                set: { store.setRollOff(realityKit: $0) })) {
                Text("mpv 软肩").tag(false)
                Text("RealityKit").tag(true)
            }
            .pickerStyle(.segmented)
            Text("谁把 >1.0 高光压回可显范围。选 RealityKit 会自动把 mpv tone-mapping 设为 clip(二者互斥,避免双重压缩)。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("EDR 曝光")
                    Spacer()
                    Text(String(format: "×%.2f", store.edrExposure))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { store.edrExposure }, set: { store.setExposure($0) }), in: 0.1...4.0)
                Text("<1 = 消费端即时衰减;>1 = 联动 target-peak 提亮(基准 406)。拉到画面不再变亮 = 摸到系统 headroom 天花板。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("❄️ 冻结换材质(测量 · 非视觉)", isOn: Binding(
                get: { store.freezeSwap },
                set: { store.setFreezeSwap($0) }))
            Text("诊断瓶颈:冻结后 mpv 继续播,只剩纯采样。看 perf HUD 的『渲染』fps —— 跳升=换材质/重摄取拷贝是墙(B+C);不变再按上面『暂停』,跳升=生产端争用、仍不变=采样/两极(A)。画面会冻/撕,只为测帧率。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var config: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("复位默认") { store.reset() }
                Button("存A") { store.saveSlot("A") }
                Button("用A") { store.loadSlot("A") }.disabled(store.slotA == nil)
                Button("存B") { store.saveSlot("B") }
                Button("用B") { store.loadSlot("B") }.disabled(store.slotB == nil)
            }
            .buttonStyle(.borderless)
            HStack(spacing: 10) {
                Button("↻ 重载视频(换分辨率/卡死时)") { store.reload() }
                Button("导出配置 → 日志") { store.export() }
            }
            .buttonStyle(.borderless)
            if !store.lastExport.isEmpty {
                Text(store.lastExport)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }
}

/// 单个二级菜单:渲染该组所有旋钮。
struct ParamGroupView: View {
    @Bindable var store: TuningStore
    let group: Int

    var body: some View {
        List {
            ForEach(TuneInventory.group(group)) { p in
                ParamRow(store: store, param: p)
            }
            if group == 5 { diagnostics }
        }
    }

    @ViewBuilder private var diagnostics: some View {
        // 快捷:标红越界(临时把 gamut 切 warn,再切回 clip)
        Button("标红越界像素(切 gamut=warn)") { store.set("gamut-mapping-mode", "warn") }
        Button("恢复 gamut=clip") { store.set("gamut-mapping-mode", "clip") }
    }
}

/// 单个旋钮:按 Kind 渲染下拉/滑块/开关/只读 + 一行说明。
struct ParamRow: View {
    @Bindable var store: TuningStore
    let param: TuneParam

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            Text(param.blurb)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var control: some View {
        switch param.kind {
        case .readonly:
            HStack {
                Text(param.label)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.system(size: 11))
            }
        case .toggle:
            Toggle(param.label, isOn: Binding(
                get: { value == "yes" },
                set: { store.set(param.prop, $0 ? "yes" : "no") }))
        case .choice(let opts):
            Picker(param.label, selection: Binding(
                get: { value },
                set: { store.set(param.prop, $0) })) {
                ForEach(opts, id: \.self) { Text($0).tag($0) }
            }
        case .slider(let lo, let hi):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(param.label)
                    Spacer()
                    Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(value) ?? lo },
                    set: { store.set(param.prop, fmt($0)) }),
                    in: lo...hi)
            }
        }
    }

    private var value: String { store.values[param.prop] ?? param.def }

    private func fmt(_ v: Double) -> String {
        // 整数类(峰值/百分位/均衡器)取整,其余保留两位
        if v.rounded() == v || abs(v) >= 100 { return String(Int(v.rounded())) }
        return String(format: "%.2f", v)
    }
}
