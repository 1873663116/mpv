# 校准片(SPEC §4.1 ground truth)

本地 ffmpeg 生成,源文件在 `/Users/xiongzhipeng/Movies/test/calib/`(gitignored,体积外置)。

| 文件 | 用途 | 关键标记 |
|---|---|---|
| `equirect_grid.png/.mp4` | 全景 equirect UV 落位 | 2:1 经纬网格(每 15°),红竖线=本初子午线(正前方)、黄横线=赤道、绿块=FRONT 中心、青块=最左(L)、品红块=最右(R) |
| `sbs_eyemark.png` | SBS 拆眼 + 自动选眼 | 左半青底、右半品红底,各带半幅网格 + 角标 |

验法:
- **🤖 模拟器**:全景贴 `equirect_grid.mp4`,正前方应看到绿块居中、红竖线正前、赤道水平 → 截图断言网格交点像素。
- **👁 真机**:贴 `sbs_eyemark`,左眼应只见青、右眼只见品红 → 验 `Camera Index Switch` 自动选眼不反不串。
