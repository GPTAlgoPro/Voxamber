# 单视图颜色投影（隔离 CPU 原型）

输入固定为同一次已完成 NN 的 strict 网格（200370 vertices /400772 triangles）和已保存的真实512 RGBA参考图。生产SDK/App与原物只读。投色是CPU后处理，不调用或添加任何基础模型，不能称为AI多视图、真实PBR或未观测面的还原。

投影显式假设+Z看向bbox中心、Y向上、距离4.2×半最大extent、FOV42（沿用已封原生展示front视图的方向；**不是训练相机标定**）。将该透视投影的整体范围等比适配到参考图alpha主体范围；不改点位。128×128屏幕分桶仅加速逐顶点连续射线/三角形最近深度求交，再仅对有alpha参考像素采图，其余顶点用声明的中性线性灰。只保留Double数值容差，取消了最初0.5%物理厚度容差（相距0.002、extent1的两层平面曾实际出现后层误涂，已RED→GREEN测试修复）。另保留512像素深度占用统计，不用像素邻域替代可见性判断。没有镜像背面、语义材质推断、颜色增益或新视角生成。单视图透视、DINO重居中和模型误差导致对应关系只是粗近似；照片光照被烘进颜色，邻接面颜色插值会在可见边界过渡。

GLB保留原POSITION/index buffer bytes与accessor，append线性Rec709 float RGBA COLOR_0，材质baseColorFactor为白，metallic0/roughness0.7仅为固定显示材质，不声称金属PBR。USDZ以同positions/indices/绕序写vertex displayColor/opacity，按现SDK的lin_p3d65_scene约定由CoreGraphics转换线性Rec709→线性DisplayP3。仅复用一份固定USDZ归档器，不复制整个模型仓。

必须回读GLB并逐值/bit验证几何与COLOR_0；USDZ经Apple原生SceneKit/ModelIO打开并检查几何/顶点色。已由3顶点小资产证实：当前macOS的直接`SCNScene(url: USDZ)`保留几何但没有`.color`源；原生`MDLAsset(url: USDZ)`读出实际P3顶点色，再经`SCNScene(mdlAsset:)`标准桥接保留`.color`。因此回读和渲染使用这条明确的原生桥接路径，不手工重涂或改变材质；不宣称其他App/QuickLook已验证显示。若原生读回不提供真实颜色证据，不以预览代替。两张实际原生3D视图在NN结束后渲染，背景中性，没有把参考PNG贴成缩略图/画面滤镜。背面灰色与未贴区域必须可见并记录覆盖率。实际大GLB/USDZ/视图放ignored.build，小源码/验证回执留本目录；不改原NN与strict拓扑（仍非watertight）。
