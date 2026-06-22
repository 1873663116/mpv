# SPEC — 沉浸格式验证(测试 app 几何/立体能力 + 逐格验证)

状态:Draft ｜ 日期:2026-06-20
关联:[ADR 0004–0009](adr/)、[INTEGRATION.md](INTEGRATION.md)、[HDR-PIPELINE.md](HDR-PIPELINE.md)

---

## 1. 目标

给 `verify-visionos` 测试 app **一次性补齐几何/立体能力**,用**纯手动指定**逐格验证 3D / 全景 / 鱼眼 / HDR 各类格式能正确呈现,沉淀「该贴什么几何、该怎么设参数」的经验,为将来接 Enchron 正式管线打底。

**成功定义**:6 类素材每一格都通过**双通道验收**(🤖 模拟器自动 + 👁 真机签收),且每格的「投影 + 立体 + 关键参数 + 坑」被记录成可复核的经验条目(§8 模板)。

### 范围内
- 扩 `verify-visionos`:自建几何(球 / 半球 / 鱼眼)、立体拆眼材质、手动格式面板。
- 逐格验证 6 素材 + 本地合成校准片。
- 沉淀参数与经验。

### 范围外(明确不做)
- **不动 mpv**:几何全在 RealityKit 侧(ADR 0009)。
- **不做元数据自动识别**:vexu / St3D / spherical 解析留给 Enchron 管线。
- 不接 Enchron 正式管线。
- 不做 MV-HEVC 双视图解码(mpv 只出单视图,见 §7 缺口)。

---

## 2. 既定前提(引用,不重论证)

- **四层正交**:编码 / 像素布局 / 投影 / 立体。「识别一个格式」= 声明「投影 + 立体」两层(像素自身不携带这两层信息)。
- **mpv 边界**:只解码 + 色彩 + 输出一张平面纹理(IOSurface → `TextureResource.__texture(from:)`),不碰几何。
- **色彩契约**:`UnlitMaterial(applyPostProcessToneMap: false)` + 关 tone map(ADR 0004–0008,device-tuned 默认已固化)。
- **三级优先级**:元数据 > 手动覆盖 > 安全默认(mono + 平面)。**本轮只实现「手动覆盖」**。

---

## 3. 要建的能力(工作分解)

### 3.1 几何
- **自建朝内 equirect 球 mesh(核心)**:360 用全经纬、180 用半经纬,**同一份代码**。
  - 理由:`MeshResource.generateSphere` 无法 ①法线朝内 ②只取半球 ③控制细分 —— 三个需求都指向自建。
  - **法线朝内**:自建 **CW winding**(不用 `scale.x *= -1` 负缩放,避 winding/determinant 歧义,见 §7)。
  - 参数:半径 **~10 m**、分段 **128×64**(极点/接缝有棱角再上 256×128;球是单 draw call,GPU 无压力)。
  - UV:360 `u = θ/2π, v = φ/π`(纹理 v 轴常需 `1 - v`);180 前方半经纬铺满纹理宽,后半球不生成三角形。
- **平面 quad**:已有(「mpv 屏」)。平面 3D / 私人影院(大 quad + 环境)复用。
- **鱼眼映射**:鱼眼 → 球面,需镜头 **FOV + 投影函数**(默认 equidistant)。两条路:后期 `v360` 预转 equirect,或 shader 直采。

### 3.2 立体拆眼
- **首选 — ShaderGraphMaterial + `Camera Index Switch (vector2f)`**(官方节点,visionOS 1.0+)。
  - 单纹理 UV offset:`Left=(0,0) / Right=(0.5,0)`(SBS)或 `(0,0.5)`(TB),U/V 整体 ×0.5 压半幅。
  - 纹理输入:`material.setParameter(name:value: .textureResource(...))` 绑 mpv 的 `TextureResource`(与 MV-HEVC / AVPlayer 无关)。
  - **half/full**:full 不拉伸;half 取半后每眼再 ×2 还原。
  - **swap L/R**:交换 Left/Right 偏移,一键应对装反。
- **备选 — 双纹理变体**:Swift 侧把拼接图切成左右两张 `TextureResource`,喂 `Left`/`Right` 参数 = 官方示例 1:1 复刻,最稳,代价多一次切分。
- 节点文档:`Camera Index Switch (RealityKit)`;官方示例:Displaying a stereoscopic image in visionOS。

### 3.3 手动面板(扩 `TuningPanel`)
- 投影:平面 / 180 半球 / 360 全球 / 鱼眼(FOV 可调 + 预设 190/200/220)
- 立体:mono / SBS / TB(+ ☐ swap L/R)
- half/full:自动从比例推断 + 手动兜底

---

## 4. 验收手段(双通道,量化)

### 4.1 校准片(双重 ground truth,全本地 ffmpeg 生成)
| 校准片 | 验什么 |
|---|---|
| 经纬网格 | 投影落位、极点收敛、接缝 |
| 左右眼 `LEFT`/`RIGHT` 大字标记 | 眼别(不反、不串) |
| 视差楔形 | 立体深度递进(真机) |

作用:对 **agent** = 截图像素断言的真值;对 **人** = 肉眼判定锚点。

### 4.2 双通道验收矩阵

| 验收维度 | 通道 | 手段 | 量化断言 |
|---|---|---|---|
| 纹理接入不崩 | 🤖 模拟器 | Swift Testing + e2e | front buffer ID 轮转、零崩溃 |
| 几何类型对(球/半球/quad) | 🤖 模拟器 | 单测查 `ModelComponent.mesh` | bounds / 类型断言 |
| equirect UV 落位 | 🤖 模拟器 | 单眼截图 + 经纬网格片 | 网格交点像素 ±容差 |
| 鱼眼映射 | 🤖 模拟器 | 截图 + 鱼眼校准片 | 网格落位断言 |
| **拆眼 UV 拆半数学** | 🤖 模拟器 | **焊死 Left/Right 常量双材质** + LEFT/RIGHT 片 | 左材质取纹理左半、右材质取右半 |
| 比例 / 无错误拉伸 | 🤖 模拟器 | 截图比例检查 | 宽高比 / 特征断言 |
| **拆眼自动选眼** | 👁 真机 | 戴头显 | `Camera Index Switch` 真分眼 |
| 立体深度 / 视差舒适 | 👁 真机 | 视差楔形 | 主观分 + 楔形递进 |
| 沉浸撕裂 / 接缝 / 极点 | 👁 真机 | 戴头显环顾 | 目检 |
| HDR 超亮 / 色彩主观 | 👁 真机 | 戴头显(ADR 已定真机签收) | 沿用已签结论 |
| 帧率 / 性能 | 🤖+👁 | 模拟器粗测 + 真机签 | fps 阈值 |

**关键设计**:把「立体拆眼」分解成两步 —— ①UV 拆半数学(确定性,🤖 用焊死常量双材质验死)+ ②自动选眼(👁 唯一不可自动化的真机残值)。这样 agent 自动扛下拆眼正确性的绝大部分,人只需真机确认「自动选眼 + 立体观感」。

---

## 5. 测试矩阵(6 素材四层归档 + 手动设置)

| 素材 | 编码 / 分辨率 | 像素布局 | 投影(手动设) | 立体(手动设) | 验收重点 | 待确认 |
|---|---|---|---|---|---|---|
| `180_3D.mp4` | HEVC 8192×4096 | full-SBS(每眼 4096²) | 180 半球 | SBS · full | 全景立体主力 | — |
| `180_3D_TB.mp4` | HEVC 8192×4096 | TB | 180 半球 | TB | packing=TB | SAR 1:4 是否影响 |
| `insta360.mp4` | AV1 7680×3840 | 2:1 equirect | 360 全球 | mono(待确认) | 360 mono | St3D/Sv3D 值=mono? |
| `360.mp4` | AV1 3840×2160 | 16:9(非 2:1) | ?(待确认) | mono | 投影存疑 | 是否标准 equirect |
| `HDR10.MP4` | HEVC 10bit PQ | 16:9 2D | 平面 | mono | 色彩档(沿用 ADR) | — |
| `apple.MOV` | MV-HEVC 2200² | rectilinear 平面立体 | 平面 | 本轮 mono* | 平面 + MV-HEVC 缺口 | *mpv 只出单视图 |

**还需本地合成**:校准片(经纬网格 / LEFT-RIGHT / 视差楔形)+ 补缺的「全景 3D-360」(从 `insta360` 合成 over-under)、「鱼眼」(`v360` 从 equirect 反投)。

---

## 6. 关键节点(里程碑)

| 里程碑 | 内容 | 出什么 |
|---|---|---|
| **M1 命门 spike** | RCP 连 `Camera Index Switch` 单纹理 UV-offset + 自建朝内球 mesh(360/180) | 把两个「需实测」变事实;失败则退双纹理变体 |
| **M2 几何建齐** | 球 / 半球 / 鱼眼 + 拆眼材质 + 手动面板(扩 TuningPanel) | 测试 app 能贴全部格式 |
| **M3 验收夹具** | 校准片 + 焊死常量双材质 + 模拟器 e2e 截图断言(TDD) | 🤖 自动门禁可跑 |
| **M4 逐格验证 + 沉淀** | 6 素材 × 双通道,真机签收,填经验条目 | 验收记录 + 经验文档 |

---

## 7. 注意事项 / 风险

- **单纹理 UV-offset 连法**:官方只示范双纹理,单纹理需 M1 RCP spike 实测(节点零件全官方,风险低)。退路 = 双纹理变体。
- **模拟器渲哪只眼未定论**:社区证据冲突(有报告只显示右眼),无官方切眼 API;「自动选眼」模拟器测不了 → 真机签。
- **负缩放 winding 坑**:`scale.x *= -1` 在 RCP/QuickLook 与运行时 winding 处理不一致 → 用 CW 自建 mesh 规避(Apple 论坛 thread/794821)。
- **自建球无官方几何数值**:Apple 样例全走 `VideoPlayerComponent`+APMP 系统建球,不暴露半径/分段。半径 / 分段 / 接缝(u=0/1)/ 极点(φ=0/π 三角退化)质量全是**真机实测签收项**。
- **half/full 压扁**:UV 取半后 half 每眼需额外 ×2 拉伸;full 不拉伸。
- **`__texture(from:)` 非公开 API**:已在用,立体路径不改变其性质(风险点在此 API 本身,非 ShaderGraphMaterial)。
- **MV-HEVC 缺口**:`apple.MOV` mpv 只出单视图(ffmpeg `View ID = 0`),本轮当**平面 mono** 测;「取双视图」三条路(降级单眼 / 改 mpv / Enchron 走 AVFoundation)留**独立决策**,不在本轮。
- **swap L/R**:3D 装反高频,面板必备一键开关。
- **素材待确认**:`360.mp4`(16:9 投影存疑)、`insta360.mp4`(St3D/Sv3D 立体标记)需 ffprobe 深确认后再定手动设置。

---

## 8. 经验沉淀模板(M4 每格填一条)

```
### 素材:<文件名>
- 四层归档:编码=… / 布局=… / 投影=… / 立体=…
- 手动设置:投影=<平面/180/360/鱼眼FOV> · 立体=<mono/SBS/TB> · swap=<是/否> · half|full=…
- 几何参数:半径=… · 分段=… · UV 备注=…
- 🤖 模拟器验收:<通过项 / 断言结果>
- 👁 真机验收:<立体观感 / 撕裂 / 色彩 / 舒适度>
- 坑 & 调参:<遇到的问题 + 最终参数>
```
