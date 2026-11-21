---
name: 2d-understanding
description: Use when a task involves images — screenshots, photos, icons, logos, UI mockups, diagrams — in PNG/JPEG/WebP/GIF/SVG, and you must describe, compare, audit, or debug them. Covers exact vs displayed dimensions (EXIF orientation), alpha and blankness, dominant colors, content bbox, text extraction (macOS Vision OCR), SVG structure and renderability, and pixel diffs between versions.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# 2D 理解（栅格图 + 矢量图）

2D 理解 = 把图像变成可复述、可验证的数值事实，再谈观感。
**先量后说**：没有测量结果的描述（"看起来是深色主题""应该是 200px 宽"）
一律视为猜测，不能作为结论。

两条通道：

- **栅格**（PNG/JPEG/WebP/GIF）：用 `image-inspect.py` 取证，OCR 取文字，
  ImageMagick 做像素比对。
- **矢量**（SVG）：用 `svg-inspect.py` 数结构、查外部依赖、真渲染一次。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能不能答）

```bash
references/image-inspect.py shot.png --json | head -40
```

按文件类型分流，拿不到就明说：

| 问题 | 能答的通道 | 拿不到时的说法 |
|---|---|---|
| 尺寸/格式/位深/DPI | 容器头（Pillow） | — |
| 显示尺寸与存储尺寸不同 | EXIF Orientation | "存储像素 X，查看器显示 Y" |
| 是否带透明、空不空 | 像素统计（先看头：>40 MP 默认不解码） | — |
| 主色/配色 | 降采样量化 | 标注"降采样、量化" |
| 图里的文字 | macOS Vision OCR | 无 OCR → "未提取文字" |
| SVG 能不能渲染 | rsvg-convert 真渲染（限 2000×2000，不按原始尺寸分配） | "未验证渲染" |
| 两版差多少 | ImageMagick RMSE/AE | 尺寸不同 → 不能比像素 |

依赖：`python3` + Pillow；`magick`（ImageMagick 7）；`rsvg-convert`（librsvg）；
OCR 需 macOS + Xcode CLT（`swiftc`），首次编译后缓存。
缺哪个就在结论里写哪个没测，不要用别的通道冒充。

---

## 栅格：`image-inspect.py`

```bash
cd <本技能目录>                          # 例：~/.claude/skills/2d-understanding
references/image-inspect.py shot.png            # 人类可读
references/image-inspect.py shot.png --json     # 机器可读，可做两版 diff
references/image-inspect.py huge.png --force-pixels   # >40MP 时强制算像素
```

输出字段与**口径**（引用时必须带上限定语）：

- `size`：存储像素。`displayed_size` 只在 EXIF orientation ≥5 时出现，
  是查看器/浏览器实际展示的宽高。**报告布局尺寸用 `displayed_size`**，
  否则会把竖拍照片当横图。
- `alpha.transparent_ratio`：alpha ≤ 8 的像素占比，全图统计（不降采样）。
  `opaque_bbox` 是 `RGBA.getbbox()`：不透明内容的外接框，全透明图没有框。
- `pixels`：在长边 ≤1024 的降采样上算的灰度均值/标准差；
  `blank=true` 只表示"像素值几乎一致"，**不代表图没意义**（纯色 logo 会被
  判 blank，但它的 content_bbox 是有意义的）。
- `colors.dominant`：缩到 ≤256px 后 median-cut 量化到 6 色，`ratio` 是像素
  占比。用于配色判断；不要当精确色值。
- `content_bbox`：以主色为背景估计、容差 12 的差异外接框。背景渐变、噪点、
  阴影会让框偏大或缺失 —— 缺失时脚本会写进 `issues`。
- `dpi`：只影响打印尺寸。96 vs 72 不改变屏幕像素，不要据此断言"清晰度"。
- `icc`：无 ICC 时按 sRGB 解释，与带 Display P3 的图直接比色会偏。

## 文字：OCR（macOS Vision）

```bash
references/ocr.sh shot.png                       # TSV: confidence x y w h text
references/ocr.sh shot.png --json                # JSON lines，含归一化 bbox
references/ocr.sh shot.png --lang zh-Hans,en-US --json
```

- 坐标是 Vision 的归一化系：**原点左下**，`x,y,w,h ∈ [0,1]`。
  换算像素：`px = x*width`，`py = (1-y-h)*height`。方向搞反是最常见的错。
- 首次调用要 `swiftc -O` 编译（实测 2s～70s 视冷启动），之后按源码 hash 缓存。
- **大图会静默返回空**：Vision 对过大的图不报错、直接给 0 行。实测一张
  7680x3240（24.9MP）Retina 截图：整图 0 行；同一图**裁剪**成 3700x1562
  有 57 行，而**缩放**成同样 3700x1562 是 0 行（LANCZOS 与 NEAREST 都是 0）；
  另裁 3840x900 的几个区域分别得 19/32/37 行。所以不是简单的边长或面积阈值，
  重采样本身也会让整片文字消失，机制未定位。
  结论：**大图先按区域裁剪再 OCR**（`sips -c <h> <w> --out out.png in.png`
  居中裁；要指定区域就用 Pillow/`magick -crop`）。`ocr.sh` 的长边 3200 是兜底，
  只保证"不再整片归零"（同一截图 19 行），精度不如裁剪。
  **OCR 返回空 ≠ 图里没字**，先裁剪重跑再下结论。
- 反过来，字太小也会 0 行（6000x400 里 11px 文字识别不到，60px 能识别），
  这种要放大或裁到文字区域。长边 6000 的 400px 高图直连是可识别的
  （实测 1 行），所以别把"大图必空"当普适规则。
- `confidence` 是识别置信度，不是"这段文字在屏幕上的重要性"。
- OCR 只给文字与位置：**不给控件语义**。看到 "Delete" 不等于确认这是删除按钮，
  按钮语义要来自 UI 树（accessibility tree）或代码。

## 像素比对：`image-diff.sh`

```bash
references/image-diff.sh before.png after.png diff.png --json
```

- `rmse` 是 ImageMagick 归一化后的 0..1；`psnr` 单位 dB，完全一致时实测
  `120`（IM 的 PSNR 上限；若 IM 输出 `inf`，JSON 里是 `null`）；
  `diff_ratio` = AE(1% fuzz)/像素总数。
- `same_size` / `identical_bytes` 是 JSON 布尔值（`true`/`false`），不是 0/1。
- **不报 SSIM**：IM7 的 `compare -metric SSIM` 对相同图输出 0（相异度口径），
  和所有其他工具相反，容易把结论说反。
- 尺寸不同时不计算像素指标，脚本会 `same_size:false`；这时只能比几何/布局。
- 退出码 3 表示"比完了但不字节相同"，可直接用于视觉回归门禁。

## SVG：`svg-inspect.py`

```bash
references/svg-inspect.py logo.svg          # 结构 + 渲染验证
references/svg-inspect.py logo.svg --json
references/svg-inspect.py logo.svg --no-render
```

- 报 `viewBox`、`width/height`、元素计数、路径段数、文本、字体、
  内嵌栅格、**外部引用**（`<image href="photo.png">` 这类不算自包含）。
- 解析成功 ≠ 能渲染：带 `--no-render` 或没装 `rsvg-convert` 时，
  结论里写"未验证渲染"。实测缺 `viewBox` 且无宽高的 SVG 会被 rsvg 拒绝。
- 字体只在 SVG 里声明，不代表渲染端有该字体；跨机渲染要再核对。

---

## Playbooks

输出都带来源：命令、字段、文件路径。无法回溯的数值不写。

1. **"这张图是什么"**：`image-inspect --json` 出尺寸/透明度/主色/bbox，
   再 OCR 出文字。描述顺序固定为：形态（尺寸、比例、是否透明）→ 配色 →
   内容区域 → 文字。不写"看起来很专业"这类不可验证的判断。
2. **截图 QA**：确认 `displayed_size` 与设计稿尺寸一致 → 检查 `blank` →
   OCR 关键文案是否存在 → 需要视觉比对时跑 `image-diff`。文案缺失就报缺失，
   不要用"布局上应该有"补。
3. **图标/logo 审计**：`has_alpha_channel` + `transparent_ratio` 判断是否
   真透明；`content_bbox` 与画布的关系说明留白是否均匀；矢量优先查 SVG 的
   `viewBox` 与外部引用。
4. **两版差异**：先 `image-inspect` 比 `size`，再 `image-diff` 比像素；
   `diff_ratio` 小但 `rmse` 高 → 是少量像素的大幅变化（文字/图标位移），
   不是整体压缩差异。
5. **压缩/格式体检**：`bytes` 与像素数算 bits-per-pixel；对截图这种大面积
   纯色的图，PNG 明显更小；JPEG 有 `mode P/1` 或色带时报告有损痕迹。
6. **图片里有没有某段文字**：OCR 结果按 `confidence` 从高到低列，
   说明用了哪些语言、有没有多语言混排；没命中就说"OCR 未识别到"，
   不要断言"图上没有"（OCR 会漏小字、竖排、艺术字）。

## Grounding 规则

- 颜色只报量化后的主色 + 占比，不报"精确 #RRGGBB"（除非逐像素验证过）。
- 尺寸分"存储像素"和"显示像素"，说哪个就标哪个。
- 像素统计是降采样的；需要精确计数时用 `--force-pixels` 并说明代价。
- OCR 给文字与位置，不给语义；语义来自 UI 树、代码或用户。
- 没渲染的 SVG 不评价外观；没解码的图不评价内容。
- 比对前先对齐尺寸；尺寸不同只说差异，不给相似度。

## 失败模式

- `displayed_size` 缺失但图是竖的 → EXIF 被剥离过，说明"方向不可判定"。
- `transparent_ratio=0` 却号称透明背景 → 常见是把透明区域合成为白底。
- `blank=true` 但图有意义 → 降采样后颜色数太少；看 `content_bbox` 与
  `dominant`，别直接判"空图"。
- OCR 返回空 → 先看尺寸（大图静默返回空，wrapper 已压到 3200），再试裁剪到
  文字区域或放大 2×；都空才能报"未识别到"。
- `ocr.sh` 报缺 `swiftc` → 非 macOS 或没装 CLT；改用外部 OCR 服务，
  并说明换了通道。
- `rsvg-convert` 报 "has no dimensions" → SVG 缺 `width/height`，补上再渲染。
- `image-diff` 报 sizes differ → 不是失败，是尺寸不一致；先比 `displayed_size`。
- 大图内存爆 → 用 `--force-pixels` 之前先看 `size`；>40MP 默认跳过像素统计。

## 脚本与依赖

- `references/image-inspect.py`：Pillow，无 numpy。
- `references/ocr.sh` + `ocr.swift`：macOS Vision，缓存编译产物。
- `references/image-diff.sh`：ImageMagick 7。
- `references/svg-inspect.py`：stdlib XML + 可选 rsvg-convert。
- `references/selftest.sh`：造夹具、断言字段；OCR 只在已缓存编译产物时跑。
  改脚本后先跑它。
