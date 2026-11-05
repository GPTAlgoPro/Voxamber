# 生成前声明：离散贴面锚点实验协议

本实验是一个新 CAD 装配语义协议，**不是修复旧模型输出**。只复用上一轮 Stage1 模型自主生成、已冻结的七部件提纲（SHA256 `08ca123dd53be7ca8a3f75e69fa14cfcfdad7eeb104d4e9ac74d02cead3d84ad`），不重跑 Stage1，不修改旧 response。对同一固定椅子请求只进行一次新的 Stage2 正式 Direct 调用，token 上限仍为 3072。正式 App、Core、Engine、ScenePrompt.system、权重都保持不变。

新输出的 child.attach 必须包含 parent、face、anchor，不能包含旧 numeric offsets。ID、primitive、parent、face 和部件数量由冻结的模型提纲固定；模型根据既有 purpose 自行选择 anchor。根部件保留原 grounded/origin 两个合同，几何、旋转、材质和自由形状预算保持完整。原系统文字不变，只追加下述新空间协议说明。

- top/bottom：center,left,right,front,back,frontLeft,frontRight,backLeft,backRight。
- front/back：center,left,right,top,bottom,topLeft,topRight,bottomLeft,bottomRight。
- left/right：center,front,back,top,bottom,frontTop,frontBottom,backTop,backBottom。
- inside：本原型仅支持 center。

方向使用现有求解器的世界轴：left=-X、right=+X、front=+Z、back=-Z、top=+Y、bottom=-Y。不随父部件局部坐标旋转，back 面也不镜像左右。

Swift helper 仅机械读取显式 parent/face/anchor，ID 仅作查表键；不读取 purpose 或用户文字，不从 ID 文本推断角色。它移除新 anchor 建立 center-attachment legacy Plan，经过现有 Core 解码，再用每个真实旋转/自由几何 mesh 的 AABB 测量跨度。每个切向轴的幅度为 `max(0,(parentExtent-childExtent)/2)`，按锚点符号写入 legacy tangent offsets；不再次加入中心差或法向补偿。现有 Core 继续负责法向贴合、少量交叠、整体落地和全部原生校验。新 raw、center legacy、evaluated legacy、canonical scene 与实际导出视图分别保存。

若切向跨度为零，不自动缩放、挪动或更换部件；不同锚点可能重合，必须作为质量问题记录。AABB 贴合不保证凹形、空心、torus 等的真实表面接触。center pass 的全局位置门禁可能提前拒绝深层图，这个单椅深度一实验不证明通用嵌套场景求解完成。

运行权重前先执行 top/front/side/inside、旋转自由 mesh、凹 extrusion、八种 primitive、非均匀尺寸、平移不变性及非法 anchor/旧 offset 拒绝检查，并进行独立只读审阅。任一生成或原生校验失败即记录停止，不重试。四腿分开也不能替代座高约0.45m、靠背后置、额外 base_frame 等独立视觉验收。
