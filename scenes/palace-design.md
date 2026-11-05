# 琉金重檐殿 / Golden Eaves Hall

原创程序化中国宫殿式建筑，参考明清皇家大殿的视觉语言，不是太和殿的测绘复原。

模型包含两层完整的曲面庑殿顶、起翘檐口、筒瓦纵垄和横向瓦缝、金色正脊和垂脊、抽象脊兽及鸱吻、朱红柱廊、青绿蓝色斗拱、深色木墙和金棕棂门、四盏悬灯、三重浅色石台基、石栏杆及中央台阶。场景以较暗的庭院铺地衬托建筑。

以米为交付单位，宽约 1.01 米，面向 +Z，Y 向上，地面最低点为 0。复杂细节集中在屋面、檐下和台基，适合桌面查看及放大检查。

`scripts/generate_palace.py` 仅用 Python 标准库计算几何和法线，再输出 `palace.js` 的有限材质网格。原生脚本只使用上游提供的 `THREE` 和 `scene`、`BufferGeometry`、`BufferAttribute`、`MeshStandardMaterial`、`Mesh`，不创建渲染器、不加载外部模型、不使用其他导出器。几何按材质合并，避免成百上千独立构件带来的 draw call 和原生 JS 执行开销。

已阅读并遵循上游 `AGENTS.md` 要求的 `skills/three-live-authoring/SKILL.md` 与 `docs/llm-guide.md`。脚本大小、网格、顶点、索引统计写入 `palace-source.json`。本文件只说明设计意图，实际导出成功、视觉效果和设备可用性须由编译和目标渲染器验证。
