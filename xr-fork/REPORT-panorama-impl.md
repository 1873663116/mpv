# 全景实施报告 — 实施 vs SPEC-format-verify.md 差异

日期:2026-06-20 ｜ 关联:[SPEC](SPEC-format-verify.md)

## 已交付(模拟器全绿)

| 部分 | 文件 | 验收 |
|---|---|---|
| 自建朝内 equirect 球 mesh(360 全经纬 / 180 半经纬同码) | `verify-visionos/Sources/App/PanoramaMesh.swift` | 7 单测绿 |
| 立体 UV 拆半数学(SBS/TB × half/full × swap × mono) | `verify-visionos/Sources/App/StereoLayout.swift` | 6 单测绿 |
| 投影热切集成(平面↔360↔180 无重载,复用 IOSurface 材质轮转 + 色彩契约) | `VerifyModel.setProjection` + `VerifyVisionOSApp` Picker | app BUILD SUCCEEDED |
| 🤖 e2e 测试目标(Swift Testing,模拟器无 UI 可跑) | `verify-visionos/Tests/` + `project.yml` | 13/13 通过 |
| equirect 经纬网格 + SBS 拆眼校准片 | `verify-visionos/calib/` + `~/Movies/test/calib/` | 已生成 |

几何契约自验:CW 朝内、法线指向球心、UV 覆盖 [0,1]²、半径 10m、128×64、θ=0→-Z 正前方、180 仅前半球、极点退化三角形跳过。

## 修复(workflow 审查发现的真 bug)

- **全景球材质与调参脱钩(blocker)**:原 `rebuildMaterials()` 只刷新平面屏实体,全景模式下调 tone-map/EDR 球面不变。已改为同时刷新 `mpvScreenEntity` 与 `panoramaEntity`。已编译通过。
- 审查推断的两个 `currentID` bug 经核源码为**误报**:`VideoFrameSystem.update` 第 31 行 `entity.components.set(component)` 已写回,currentID 正常推进。

## 未兑现的 spec 承诺(分级)

### blocker — 阻断完整立体/鱼眼出口,需后续
- **Camera Index Switch 自动选眼(§3.2 首选)**:本轮只做了「UV 拆半数学」(可模拟器验死的一半);ShaderGraphMaterial + Camera Index Switch 节点需在 RCP 手工编 `.usda` 材质图,无法纯程序生成,且「自动选哪只眼」模拟器测不了 → 这是 spec §7 已声明的真机残值 + M1 命门 spike,不是缩水,但确实未闭环。
- **鱼眼映射(§3.1)**:独立投影维度,本轮按"重点全景"未启动。可平行追加。
- **焊死双材质 + 纹理接入 e2e 渲染夹具(§4.2)**:立体数学有单测,但渲染级(进沉浸空间截图)验收未建。

### gap — 部分兑现
- TuningPanel 尚未暴露立体/half-full 入口(投影已在控制窗 Picker)。
- equirect/拆眼像素级截图断言:校准片已备,缺金标比对脚本。
- 球心定位用户视点目前靠默认 transform(0,0,0)成立,无显式断言。
- 6 素材逐格真机签收(M4)、TB/鱼眼/视差楔形校准片未做。

### intentional-defer — 合理延后
- 平面 quad 复用既有 mpv 屏实体,不纳入 PanoramaMesh(符合解耦)。
- 真机撕裂/接缝/极点、立体深度舒适 = spec 明文的👁通道唯一不可自动化项。
- 分段数上界校验(当前默认安全)、flipV/UV 参数化符号(物理等价,待样片实测)。

## 下一步建议(优先级)

1. **M1 命门**:RCP 编 Camera Index Switch 材质图 + 全景球绑定 → 决定整个立体出口架构是否成立(优先于鱼眼)。
2. 用 `calib/equirect_grid.mp4` 在模拟器实机贴 360 球,目检 UV 落位(正前方绿块居中、赤道水平),定 flipV。
3. 鱼眼维度(FisheyeMesh + FOV)可平行追加。
