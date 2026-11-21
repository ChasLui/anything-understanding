---
name: 3d-understanding
description: Use when a task involves 3D content — engineering CAD (STEP parts or assemblies, part search, BOM, cost, standard-part merging, supply-impact tracing) or game assets (glTF/GLB/FBX/OBJ, Godot scenes, mesh budgets, materials, skeletons, animations, import failures). Covers what a 3D backend must produce, how to verify geometry was actually parsed or imported, and grounded answer contracts.
metadata:
  version: "2.0.0"
  date: "2026-11-21"
---

# 3D 理解（工程 CAD + 游戏资产）

3D 理解 = 把模型变成 Agent 可检索、可验证的结构化上下文。两条主赛道：

- **工程 CAD**：语义在 PMI（尺寸/公差/工艺）和装配树里，靠 3D 理解后端解析。
- **游戏资产**：语义在网格结构、材质、骨骼动画和引擎导入结果里，靠解析器
  与引擎 headless 验证。

**共同原则：证据先于回答。** 没解析、没导入、没量过，就别说"能行""没差异"。

## 三条证据通道

1. **3D 理解后端**（OpenViking 托管）：CAD 全语义，STEP → 视图 + PMI +
   装配树。唯一能回答"公差多少""这层装配什么关系"的通道。
2. **本地几何解析**：FreeCADCmd 出视图与体积；纯 Python 读 GLB 出网格统计。
   没有后端时用它取证，覆盖面窄但可复现。
3. **引擎导入**：Godot headless 真导入一次，才知道资产能不能用。
   解析器说"文件合法"不等于引擎能用。

---

## Track A：工程 CAD（STEP）

### 后端选择

- 托管 OpenViking Service（火山引擎，前 50 文档免费）：
  `https://api.vikingdb.cn-beijing.volces.com/openviking`，换服务器用
  `ov config`，切完重跑 gate。
- 自建实例实测（2026-11-21，v0.5.3）：最小 `.step` 入库只得到 ISO-10303
  文本摘要，无视图、PMI、装配树；服务端 OpenAPI 也无格式/3D 接口。
  该结论来自一次探针，真实整车 STEP 复测才算定论。
- 格式：`.STEP` 官方确认；`.DWG` 未验证；`dxf/iges/sldprt/sldasm` 为 roadmap。
- 无后端时走 `references/step-views.sh`（见下）。

#### 数据边界（上传前必须确认）

- `ov add-resource`、`ov find --image` 会把 STEP/截图**上传**到 `ov config` 里
  配置的后端。CAD、BOM、报价、供应商记录默认按机密处理：先说明去向并取得
  用户明确同意，再上传；未同意就走本地 `step-views.sh` / GLB 解析。
- 只上传回答所需的最小文件；不要把整个 `quotes/`、`suppliers/` 目录批量入库。
- 报告里写清数据落在哪个 endpoint；换服务器（`ov config`）等同于换数据去向。

#### Gate（CAD）

```bash
ov health -o json
ov abstract viking://resources/<...>/<model>.step | grep -E '轴侧|PMI|装配'
ov tree viking://resources/<...>/<model>.step -L 2
```

命中「轴侧八视图 / PMI / 装配」→ 可以答。只有 ISO-10303 文本描述 →
报告"当前实例只有文本级解析"，不要用文件名猜内容。

文本摘要可能包含平面 / 圆柱面 / B-Rep 等描述（`CARTESIAN_POINT`、
`CYLINDRICAL_SURFACE` 这类实体名本来就在 STEP 文本里，属于文件内容提取，
不是模型瞎猜）：可用于定性预筛（判断是不是板类件、有没有圆柱面），
不可作为尺寸或公差证据。

### 产物契约

- **装配树**：层级目录（整车概览 / 车身 / 底盘 / 动力总成 / 内饰 /
  外饰 / 座椅 / 电子电器 / 空调 / 流体）。用于跨目录定位、算影响面。
- **正交六视图**：前后左右上下，做外形比对。
- **轴侧八视图**：八个轴测角，暴露被遮挡的内部结构。**关键差异点** ——
  六视图对两个内壁盲孔不同（圆 vs 六角）的零件完全一致，只有轴侧图能看到
  孔口与孔底。六视图分不出时先要轴侧图，没有就回答"无法判别"。
- **PMI 摘要**：Summary.md，拆成 几何 / 尺寸 / 公差 / 装配 / 工艺 五段。
- **模型明细**：零件定义、安装实例、材料、重量。

量级 sanity check：整车 174 个零件定义 / 445 个安装实例；后悬架
29 零件 / 49 实例；变速箱 42 种零件 / 99 件。数量级差太多说明解析不完整。

### 入库与布局

```bash
ov add-resource /abs/path/model.step \
  --parent-auto-create viking://resources/cad/<project>/models --wait -o json
ov task status <task_id> -o json
```

```text
viking://resources/cad/<project>/
├── models/      # .step 零件与装配
├── bom/         # 历史 BOM
├── quotes/      # 采购报价、费率表
├── standards/   # 紧固件目录、归并原则、计价口径
└── suppliers/   # 厂商、断供记录
```

公司规则入库，Agent 读规则，不猜规则。检索用 `-u` 限定子树，别全库扫。

### CAD playbooks

输出都要带来源（URI / 零件号 / 行号）。无法回溯的数值不写。

1. **按结构特征找零件**：装配树定位 + 轴侧八视图比对开口/孔位 + 装配场景。
   有截图用 `ov find --image /abs/shot.png -u .../models`。差异在被遮挡的
   内部且无轴侧图 → "无法判别"。
2. **按精确规格找零件**：读 PMI 尺寸/公差段逐项对照，输出参数表
   （板厚 20.0 mm ±0.05、4×Ø6.6 ±0.1 贯通）+ PMI 来源。PMI 缺失 → 拒答。
3. **设计参考**：参考装配子树 → 按装配位置过滤 → 明细重量 + 库内单价。
   参考模型不在库内 → 不凭常识造数据。
4. **BOM + 成本**：子树汇总（种类/件数/净重）→ 计价口径 → 管理费率
   （必须来自规则或用户明示）。缺报价或费率 → 只出 BOM 与重量。
5. **标准件归并**：紧固件子树 → 名称 + 几何推断规格 → 归并原则逐条判
   （例 47 → 43 → 38），每项给风险。原则未入库 → 只出规格矩阵。
6. **断供影响面**：零件定位 → 装配树 + BOM + 采购记录反查 → 产品 × 用量，
   并声明覆盖缺口。缺记录 → 说明缺口，不推估。

### 离线降级：STEP → 视图 + 体积

```bash
references/step-views.sh \
  model.step /tmp/views --density 7.85
```

产出 `views.svg`（6 正交 + 8 轴测同图）、`views.png`（qlmanage 栅格化）、
`metrics.json`（每体体积/面积/包围盒，给了密度才有 mass_g）。无 PMI、
无装配语义、只数实体不数安装实例 —— 用它取证时把这三点一起写进结论。

实测（FreeCAD 1.1.4 cask，2026-11-21）：`FreeCAD.app` **不含 FreeCADCmd**，
脚本自动退到 `Contents/Resources/bin/python` + `PYTHONPATH=Resources/lib`；
带孔板 STEP 往返体积一致（22429.2 mm³），密度 7.85 时 mass 176.07 g；
多实体 STEP 合并为一个 body、`solids=2`；某方向投影失败记进
`metrics.json` 的 `unprojected_views`，不中断整张图。

---

## Track B：游戏资产（glTF / GLB / Godot）

### Gate（游戏资产）

一条命令，按扩展名自动分流：

```bash
cd <本技能目录>                        # 例：~/.claude/skills/3d-understanding
references/model-inspect.sh x.glb          # 原生解析 GLB/glTF
references/model-inspect.sh x.fbx --json   # assimp 转 GLB 后同样的报告
```

支持：`.glb/.gltf` 原生（含外部 `.bin`，外部引用列成 issue）；
`.fbx/.obj/.dae/.stl/.ply` 经 assimp 转 GLB（`brew install assimp`）。
转换报告带 `converted_by: assimp`，`file` 仍是原始路径。
**转换后的计数与 bounds 只代表转换结果**：assimp 会重排节点（FBX 出现
`$AssimpFbx$` 中间节点）、可能改 UV/材质引用；最终能不能用仍以引擎导入为准。

实测（2026-11-21，assimp 6.0.6）：单三角形 FBX → 1 tri / 3 vert；Mixamo
`Idle.fbx`（纯骨骼动画、0 mesh）→ 1 animation / 1.967 s / 219 nodes，动画保留；
OBJ 树 → 1442 tri / 724 vert。EXR/KTX2 纹理仍需引擎侧确认。

转换产物可用性已闭环（Godot 4.7.2）：Mixamo `Idle.fbx` 经
`assimp export Idle.fbx anim.glb -fglb2`（不加后处理）得到 160 KB 的
`anim.glb`，`--import` exit 0 生成 `anim.glb-<hash>.scn`；实例化后
`AnimationPlayer` 里有 `mixamo_com 1.97 s`，骨架与动画都在。
OBJ 用 `-fglb2 -gn` 转出的 GLB 同样导入通过。assimp 读不回自己的
蒙皮 GLB，但 Godot/ufbx 能读 —— 二者互补，不互为验证。

assimp 已知限制（6.0.6 实测 + 上游源码核对）：

- 格式 flag 必须紧贴：`-fglb2` 有效，`-f glb2` 会被静默丢弃、按扩展名猜；
  `-fglb`/`-fgltf` 是 **glTF 1.0** 旧导出器，产物没有 JSON chunk，不可用。
  wrapper 固定用 `-fglb2`。
- **默认不做后处理**：源文件缺 NORMAL 就照原样缺（这算真实信号）。
  需要修正常见问题用 `--gn`（生成法线）/ `--tri`（三角化），wrapper 会透传。
- **不要把带蒙皮的 GLB 再喂回 assimp**：6.0.6 会拒绝自己导出的
  inverseBindMatrices（`fourth row must be [0,0,0,1]`）。转换只做
  源文件→GLB 单向，验证用本脚本或引擎导入。
- 不导出 blend-shape 动画通道；灯光/相机退化成空节点。
- FBX 会插入 `$AssimpFbx$` 轴心包装节点，节点层级与原文件不同。

`assimp info` 与 `assimp export` 的默认后处理不同：`info` 默认走
`TargetRealtime_MaxQuality`（含三角化、合并顶点），`export` 默认零后处理。
所以两边的三角形/顶点数与包围盒可能对不上 —— 我们的报告以 export 结果为准，
并在口径里注明。

输出必须能回答：三角形/顶点数、材质与纹理字节、动画数与时长、骨骼、
morph、required extensions、世界包围盒、issue 列表。拿不到这些就别评估
"这个资产行不行"。

### 引擎验证（Godot）

```bash
GODOT=/Applications/Godot_mono.app/Contents/MacOS/Godot   # 4.7.2 mono 实测
"$GODOT" --headless --path <project> --import   # 退出码 0 + .godot/imported/*.scn
"$GODOT" --headless --path <project> --quit     # 加载期报错会打在 stderr
```

解析器通过 ≠ 引擎可用：Draco/meshopt、非标准法线、缺 UV、外部贴图都可能
在导入阶段才炸。要断言"能导入"，必须跑一次 `--import` 并检查产物。

`--quit` 的退出码不可单信：实测空项目返回 0 同时 stderr 打
`Error: Can't run project: no main scene defined`。判定通过必须同时满足
退出码 0、stderr 无 `Error`、`.godot/imported/*.scn` 存在。

FBX 可直接导入：Godot 4.3+ 内置 ufbx 解析，**不需要 FBX2glTF**。把 `.fbx`
放进项目跑同一条 `--import`，生成 `.godot/imported/<name>.fbx-<hash>.scn`
即通过（4.7.2 实测，Mixamo 骨骼动画 FBX）。实证 `.glb`、`.fbx`、`.obj`
都能直接进项目（`.obj` 产出 `.mesh`）。assimp 解析失败时，这是交叉验证路径。

### 资产 playbooks

1. **资产体检**：`model-inspect.sh` 出基线（三角形/纹理/动画/bounds），
   对照项目预算给出超没超，超在哪一项；`.fbx/.obj` 会先把
   `converted_by: assimp` 标在报告里。
2. **版本比对**：两版各跑一次 `--json`，diff counts 与 bounds；
   只报变化项，不重述整份报告。
3. **导入失败定位**：先看 `issues`（required extension、缺 NORMAL、
   贴图无 TEXCOORD、外部 URI），再跑 Godot `--import` 拿真实报错；
   两者都无结论时，把文件与命令一起交回，不猜。
4. **场景/资源验证**：`--import` 后确认 `.godot/imported/` 有对应 `.scn`；
   `--quit` 退出码与 stderr 干净才算通过。
5. **尺度核对**：GLB 以米为单位；bounds 只有 0.019 这类数值，说明模型按
   cm 建的或根节点带 0.01 缩放 —— 报"尺度可疑"，不要直接换算成"看起来对"。

## 两条 track 共用的 Grounding 规则

- 三角形/顶点数取自 accessor，不等于 GPU 实际绘制数；注明口径。
- 包围盒是经节点矩阵变换的保守 AABB，不是紧包围体。
- 共享节点（glTF 的 instancing）按每次引用分别计数与变换，同一节点最多展开 8 次；
  只看一次会把重复实例的三角形和 bounds 漏掉。
- accessor 的 `min`/`max` 长度不是 3 或含 NaN/Infinity 时，bounds 报 `null` 并在
  `issues` 说明，不输出非法 JSON 数值。
- GLB 的 BIN chunk 小于 buffers 声明字节数时报 `embedded buffer ... truncated`；
  header 总长与真实文件长度不一致同样进 `issues`（下载被截断的典型形态）。
- assimp 转换返回 0 但产物没有 mesh/animation/skin 时按失败处理（exit 1），
  不把空壳 GLB 当"能解析"。
- 体积不能推质量：质量要么来自 PMI/明细，要么来自显式密度。
- 检索/解析为空说"未找到/未解析"，并列出已检查范围。
- 覆盖率不确定时先报覆盖率，再给结论。

## 不适用：场景级开放词表分割

OpenScene 这类 open-vocabulary 3D 分割（CVPR'23）分两半，成本差一个数量级：

- **生成 per-point 特征**：需要 RGB-D 序列 + 相机位姿 + 多视角 2D 特征融合
  （OpenSeg/LSeg），训练/评估依赖 CUDA + MinkowskiEngine（torch 1.7.1+cu110），
  单套 ScanNet 融合特征 175–235 GB。官方 eval 脚本即使 `feature_type=fusion`
  也在模块级 `from MinkowskiEngine import SparseTensor` 并 `model.cuda()`，
  macOS 上跑不了；单文件 GLB/STEP 更无从得到。
- **查询已有特征**：纯 CPU 就能做，且可脚本化。特征格式经实测确认：
  `float16 [N, 768]`（CLIP ViT-L/14@336px 维度），配同点数的 `.ply` 点云；
  文本塔 `clip.load("ViT-L/14@336px", device="cpu")` 出 768 维并归一化，
  osview 的判据就是**逐点与查询向量的点积**（两边都归一化过即余弦），
  等价于 `scores = feats.float() @ text`，取 top-k。官方 demo 数据 2.04 GB
  （一个 Matterport 场景、8 个 region，region3 实测 76,115 点）；另有
  `class_features.npy`（47 类 × 768）名义上可做 argmax，但**实测 47 行里只有
  1 行非零**——用前必须按 class list 现场重编码（`generate_one_clip_feat.py`
  几行即可），否则整片点会被判成空类。
  官方 GUI 查看器 `osview` 是 GLUT/OpenGL 窗口程序，**没有 headless 模式**，
  只能人工交互；`run_demo` 还写死 `x86_64` 路径（arm64 未验证）。agent 要
  脚本化，只能绕开它：文本塔自己跑，打分用 numpy 复刻上面的点积。
  名字坑：这里的 `osview` 是 GAPS 的 GLUT 查看器，与 IRIX 系统监控
  `osview`/`gr_osview`、Linux/BSD 的 `xosview`（X11 监控）完全无关；
  搜到"SSH -X 转发 / xosview headless"之类方案都是另一个工具，不要套用。
  无窗渲染别信传闻：GAPS 仓库**没有 `RN_WINDOWLESS` 宏**（全仓 0 命中），
  真实机制是各 app 的 `make mesa` 目标（`-DUSE_MESA -lOSMesa`，见
  `makefiles/Makefile.apps`），`scn2img`/`conf2img` 有 OSMesa 分支，可无窗
  出图，但要先自己编译 GAPS。`Xvfb` 只存在于 X11，本机没有；macOS 上
  `osview` 仍按 GLUT 窗口处理。OSMesa 在 macOS 的可用性未验证（brew 无
  `osmesa` formula，只有 `mesa`）。
  类名文本建议套官方模板 `a {label} in a scene`（eval 编码标签时用它），
  裸词查询是 demo 的做法。

所以：问"这场景里哪些是椅子"时，**有 [N,768] 特征才谈得上**；答案必须写明
特征来源模型、点数、top-k 分数与阈值，并声明这是开放词表命中而非语义真值。
从单个资产文件出发的请求直接说拿不到，别用 2D 检测或目测冒充。

量化边界（论文 Table 2，零样本 20 类 mIoU）：ScanNet 47.5 / Matterport 42.6 /
nuScenes 42.1 —— 逐点约一半是错的。因此开放词表标签**只能当假设**：拿它和
文件字段（materials 名、节点名、PMI、贴图名）对撞，两边都给来源，对不上报
不一致；禁止用它回答件数、BOM、成本、公差、质量或可导入性。

## 失败模式

- STEP 入库只有 `.md` → 无 3D 后端，切托管 service 或走 step-views。
- `ov` 参数含 `viking://` 被拦截 → 改用 MCP `viking_read` /
  `viking_search` / `viking_browse`。
- 大装配慢/超时 → 记 `task_id` 轮询，或先上传子装配。
- 六视图一致 → 要轴侧图；没有就承认无法判别。
- FreeCAD 装不上 → `brew install --cask freecad`；脚本会明确报解析路径。
- Godot `--import` 退出非 0 → 读 stderr 第一条错误，别重复跑同一命令。
- FBX 转换后节点名带 `$AssimpFbx$`、层级被重排 → 按 label/名称找部件，
  不要依赖原始层级或节点索引。
- 把带蒙皮的 GLB 再喂回 assimp 报 `inverseBindMatrices` → 正常，6.0.6
  不接受自己的导出；用 `glb-inspect.py` 或 Godot 验证，别重转换。
- OBJ/FBX 转换后 `lacks NORMAL` → 源文件确实没有法线，或加 `--gn` 再评估。
- assimp 解析 FBX 失败（自家 FBX 读写有已知 bug）→ 用 Godot 4.3+ 原生
  ufbx 导入交叉验证，别手写解析器。
- 成本与历史差异大 → 核对计价口径与费率版本，不调数字凑结果。

## 脚本与依赖

- `references/glb-inspect.py`：零依赖，Python 3.9+，读 GLB 容器或 glTF JSON
  chunk；`--json` 给机器读、可做两版 diff。
- `references/model-inspect.sh`：按扩展名分流 —— GLB/glTF 原生，
  FBX/OBJ/DAE/STL/PLY 走 assimp 转 GLB 后复用同一报告；人类输出以原始
  文件名为标题，JSON 带 `converted_by`。
- `references/step-views.sh` + `step-views.py`：需要 FreeCAD cask 1.1.4+
  （macOS bundle 走 Resources 里的 python，无 FreeCADCmd），可选
  `qlmanage` 栅格化。
- `references/selftest.sh`：一条命令回归全部工具 —— glTF 实例化计数与
  world bounds、STEP 往返体积、14 视图、投影失败数、OBJ→GLB 转换；
  缺 FreeCAD / assimp 时对应段落自动跳过。改动脚本后先跑它。
- Godot：`/Applications/Godot_mono.app`（4.7.2）已实测；其他安装改 `GODOT`。

## 接入

技能目录用相对路径引用脚本（`references/*`）；各 Agent 目录由
`agents-sync` 建相对 symlink。OpenViking 侧走 MCP 或 CLI：

- MCP：`viking_search` / `viking_read` / `viking_add_resource`。
- CLI：`ov add-resource` / `find` / `abstract` / `overview` / `tree` /
  `task status`。

CAD 一条命令自检：

```bash
ov abstract viking://resources/<...>/<model>.step | grep -qE '轴侧|PMI' \
  && echo "3D parse OK" || echo "text-only, stop"
```

## 来源

- 微信 2026-11-19《OpenViking 3D 理解模型 X 汽车行业 Benchmark 数据库》
  <https://mp.weixin.qq.com/s/3y-YX7MtfF0gqkQahTsf6Q>
- InfoQ 2026-11-16《OpenViking 3D 理解模型上线轴测八视图及 PMI 解析》
  <https://xie.infoq.cn/article/c113577388fc5e540fe0a24d1>
- InfoQ 2026-11-04《OpenViking 上线原生 3D 内容理解模型》
  <https://xie.infoq.cn/article/3bc9a5197f220db773e43b754>
