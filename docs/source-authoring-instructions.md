# 把这份说明交给任意LLM，创作Three-Live场景源码

在下面说明之后写下你想创建或修改的物体、风格、尺寸和要求。LLM只负责创作源码；维珀负责在iPhone本机通过Google官方原生Three-Live SDK编译、预览、保存和导出。不要求使用维珀内置LLM，也不要让LLM返回一张图片代替三维模型。

---

请为我的描述创作一个完整、静态、可重新编译的Google Three-Live场景。题材由我决定，没有建筑、家具或其他类别白名单。请自行设计结构、轮廓、比例和材质，不使用预制答案来替代我的要求。

**输出格式**

- 最佳形式是UTF-8纯JavaScript源码，可保存为`scene.js`。也可以只给一个完整的`javascript`代码块。
- 如果采用HTML形式，只给一个内嵌`<script type="text/three">…</script>`；不要加加载库的`<script src=…>`、module脚本、其他代码块或完整网页模板。App不会执行网页或猜测哪段普通script是模型。
- 不输出JSON场景参数、图片、Python、TypeScript类型声明或未完成的代码片段。不要把代码拆成多个块。若要解释，请放在唯一代码块外。
- 程序必须完整结束，不要以“其余略”“自行补全”或伪代码省略几何。不要在源码中调用导出器。

**实际运行环境**

目标为Google Three-Live v1.2.3，源码版本`c0ff24b628795286a175f1a71611673df5dbc05d`的原生author engine。全局`THREE`和`scene`已经注入；把完整的Mesh/Group添加到`scene`，不另建Scene、浏览器renderer、DOM、相机或页面。不要联网、加载外部模型/纹理/字体、读取文件、导入模块或启动动画/永久循环。需要结构重复或数学曲面时，可以使用普通JavaScript变量、函数、有限循环和TypedArray，在这个场景内直接构造。

**可用建模能力**

- 数学与变换：Vector2/3/4、Euler、Quaternion、Matrix3/4、Color、MathUtils，Object3D/Group/Mesh/InstancedMesh的层级、position/rotation/scale。旋转单位是弧度，Y向上。
- 基础几何：BoxGeometry、PlaneGeometry、SphereGeometry、CylinderGeometry、ConeGeometry、TorusGeometry、TorusKnotGeometry。
- 通用曲面：BufferGeometry、BufferAttribute、Float32BufferAttribute、Uint16/Uint32BufferAttribute、setAttribute/setIndex和computeVertexNormals。可用自定义顶点与三角面表达超出基础几何的形状；保持有限数值、有效索引、正确绕序与法线。
- 原生入口会自动安装CAD扩展：Path、Shape及holes、ShapeGeometry、ExtrudeGeometry及depth/steps/bevel选项、TextGeometry，以及CSG.union/subtract/intersect。它也安装IKSolver.solveTwoBone/solveFABRIK。不要因为只看基础导出表就误认为这些能力不可用。
- 材质使用MeshStandardMaterial的color、metalness、roughness等实际支持属性。可以用AmbientLight、DirectionalLight和PointLight；灯光不能替代几何。
- 这不是完整浏览器Three.js。未知符号可能静默降级或变成no-op；不能把这种结果当作正确模型。LatheGeometry、TubeGeometry未在这个固定原生入口注册，需要时可用BufferGeometry和数学构造相应表面。可检查THREE.getAuthorWarnings()，不要隐藏不支持特性的警告。

**预算与质量**

源码上限1 MiB；每场景最多100000顶点、300000索引和1000 Mesh。CSG等扩展还有自身配额；运行时间也受原生沙箱限制。不要扩大限制、填入无用海量坐标，优先用清楚的函数、参数和重复构造表达设计。手机上的实际运行时间与内存仍需要实测。

遵守我给出的尺寸、部件数、颜色、开口/厚度和落地要求。让修改所需的参数与结构在源码中易于定位。导入器只提取包装，不会补括号、重写几何、换成模板或自动修复失败源码；编译、几何和真实外观都需要验证。

---

这份说明不包含任何预制模型答案。其API依据固定版本的[原生bundle构建入口](../upstream/compiler/build.rs)、[author入口及CAD/IK安装](../upstream/three-live/src/three-author.ts)和[CAD注册表](../upstream/three-live/src/plugins/cad.ts)。官方SDK本身的有限支持范围与安全预算，不应被描述成完整Three.js或无限细节保证。
