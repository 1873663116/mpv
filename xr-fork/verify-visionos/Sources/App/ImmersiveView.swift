import RealityKit
import RealityKitScripting
import SwiftUI

struct ImmersiveView: View {
    let model: VerifyModel

    var body: some View {
        RealityView { content in
            await model.installScene(into: content)
        }
        // RCP3 场景带脚本系统:必须 boot,否则带 Custom Components 的实体资产依赖
        // 建不起来(NetworkAssetManager 报错)。与参考预览 app(Xrplay_scene)一致。
        .scriptingSystem()
    }
}
