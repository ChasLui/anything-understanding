---
name: doc-understanding
description: Use when a task involves documents — PDF, DOCX, PPTX, XLSX, Markdown/HTML/RTF — and you must read, audit, compare, or extract from them. Covers page/slide/sheet inventory, whether a PDF has a real text layer or is a scan, embedded fonts, table extraction with its limits, DOCX tracked changes, XLSX formulas, and render+OCR for scanned pages.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# 文档理解（PDF / Office / 文本）

文档理解 = 先把结构量清楚，再抽内容，最后才解释。
**先 probe 后 extract**：不知道有没有文本层、有几页、是不是扫描件就开始抽取，
得到的"空结果"会被误读成"文档没内容"。

三条证据通道：

- **结构**：`probe.py` 出页数/幻灯片/工作表、文本层覆盖、字体嵌入、修订、公式。
- **内容**：`extract.py` 按页/幻灯片/工作表抽文本与表格，并标明哪些页没有文本层。
- **像素**：`render.sh` 把扫描页渲成 PNG，再交给兄弟技能 `2d-understanding` 的
  `references/ocr.sh`。本技能不复制 OCR 脚本。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能不能答）

```bash
cd <本技能目录>
references/probe.py report.pdf
```

| 问题 | 能答的通道 | 拿不到时的说法 |
|---|---|---|
| 几页/几张幻灯片/几个工作表 | 容器结构 | — |
| 是电子文档还是扫描件 | 每页文本层字符数 | 混合时逐页列出 |
| 加密了吗 | `encrypted` | 加密就只能看元数据，明确说 |
| 字体嵌入没嵌入 | 字体 xref | 非嵌入 = 渲染依赖查看器 |
| 表格能不能抽 | pdfplumber 是否检出 | 无画线表格实测检不出 |
| 文档有没有修订 | DOCX XML 计数 | 有修订时抽取文本不含插入内容 |
| 工作表里有公式吗 | `formulas` 计数 / `--formulas` | 无缓存值的公式导出为空 |

依赖：`python3` + PyMuPDF、pdfplumber、python-docx、python-pptx、openpyxl；
`pdftotext`（`--layout`）；`pandoc`（`--markdown`）。缺哪个就只降级对应的那一类，
`probe.py` 会把缺失写进 `notes`。

## 结构：`probe.py`

```bash
references/probe.py report.pdf            # 人类可读
references/probe.py report.pdf --json     # 字段缺失一律 null
references/probe.py deck.pptx sheet.xlsx notes.md
```

字段口径（引用时带上限定语）：

- `pages` / `pages_with_text` / `scanned_pages`：`scanned_pages` = 该页文本层为空。
  **空白页也会被列进来** —— 判"扫描件"前用 `render.sh` 渲一张看一眼。
  实测：电子页 `chars=47`，图片页 `chars=0`、`images=1`。
- `pdf_version`：来自文档头（`1.7` 这类）。`page_size_pt` 是第一页的 pt 值。
- `fonts[].embedded`：该字体是否有可提取的字体程序（`extract_font` 扩展名不是
  `n/a`）；`embedded=false` 时渲染依赖查看器的字体替换，PDF 仍能打开，
  但排版可能变。Helvetica 这类 base-14 字体常被误判成内嵌，看这个字段时注意。
- `images_total` / `links_total` / `annotations_total` / `form_fields_total`：
  全文件累计，不是"每页平均"。
- DOCX：`paragraphs` 只数 body 段落；表格文字要 `extract.py` 才会出来。
  `words` 只统计段落文本（不含表格、页眉页脚）。`comments`/`tracked_*` 来自
  `word/comments.xml` 与 `document.xml` 的原始 XML。
- PPTX：`notes` 只数**非空**备注页；`pictures` 只数 PICTURE 形状。
- XLSX：`formulas` 用 `data_only=False` 扫描；默认上限 200,000 格
  （`probe_xlsx(..., formula_scan_limit=N)` 可改），超出时 notes 写
  `formula scan stopped at N cells`——此时计数是**下界**，不是全部；
  `merged` 是合并区域数；`charts` 来自 worksheet 的 `_charts`。
- 加密 PDF：只给 `encrypted=true` + notes，**不读内容**。
- 压缩包类文档（DOCX/PPTX/XLSX/ODT/EPUB）先查展开体积：解压后超过 200 MB
  直接报 `archive expands to N MB; not parsed`，不交给解析器（zip bomb 防线）。
- 页范围选不中任何页（`--pages 99`）直接报错退出，不静默输出空串；
  `--layout` 只在选中页连续时才整段调用 `pdftotext`，避免带出未请求的页。
- XLSX 数组公式（`ArrayFormula`）计入 `formulas` 并由 `--formulas` 输出，
  与普通 `=...` 公式同等对待。

## 内容：`extract.py`

```bash
references/extract.py report.pdf                 # 每页文本，带 `--- page N ---`
references/extract.py report.pdf --pages 1-3
references/extract.py report.pdf --layout        # pdftotext -layout
references/extract.py report.pdf --tables out/   # 每表一个 CSV + markdown 预览
references/extract.py deck.pptx                  # 每页文本 + 备注
references/extract.py sheet.xlsx --formulas      # 公式本身
references/extract.py doc.docx --markdown        # pandoc -> GitHub markdown
```

- 没有文本层的页会打印 `[page N: no text layer — OCR needed]`，并在 stderr 汇总，
  不会静默输出空字符串。
- `--layout` **不是**"读序更好"的同义词：实测一个双栏页，默认 block 顺序是
  左栏两行 → 右栏两行；`-layout` 按 x 坐标输出，把左右栏并到同一行。
  `-layout` 适合表单/对齐信息，多栏正文先两种都跑再选。
- 表格靠画线：pdfplumber 对无边框表格实测 **0 检出**，输出 `[no tables detected]`。
  有检出时也给行列数，表头是否正确要人核。
- DOCX 文本 = 段落 + 表格（表格以 `--- table i (RxC) ---` 标注）。
  **带修订的文档，`w:ins` 里的插入内容不会出现在文本里**（python-docx 实测，
  pandoc `--track-changes=all` 也没显示手写 `w:ins`）；probe 报
  `tracked_insertions>0` 时，结论必须写"文本未含修订插入"。
- XLSX 文本用 `data_only=True`：**没有缓存值的公式单元格导出为空**；
  要公式本身用 `--formulas`，要公式计数看 `probe.py`。
- `--markdown` 走 pandoc：docx/html/rtf/odt/epub 可用，**PDF 不行**（pandoc 不读 PDF）。

## 扫描件：`render.sh` + OCR

```bash
references/render.sh scan.pdf --page 1 --dpi 150 --out page1.png
../2d-understanding/references/ocr.sh page1.png --json
```

- 输出 `path  WxH  page N/M @ Ddpi`；尺寸 = pt/72×dpi，向上取整
  （实测 800×400 pt @150 → 1667×834）。
- 150–200 dpi 够读正文；低于 100 dpi 小字会丢。渲染出的图如果再缩放，OCR 会更差，
  所以直接对原始渲染图跑 OCR。
- 实测闭环：图片型 PDF（`chars=0`）→ 150 dpi 渲染 → OCR 取回
  `INVOICE 2026-0042`，确认"扫描件也能读"，但这是 OCR 结果，不是文档文本层。
- OCR 空 ≠ 没字；先按 `2d-understanding` 的裁剪规则重试。

---

## Playbooks

输出都带来源：页码、sheet 名、slide 号、命令。无法回溯的数值不写。

1. **报告/合同速读**：`probe.py` 看页数与文本层 → `extract.py --pages 1-2` 看结构 →
   再按需要的页抽全文。交付时写"读了哪些页"，不要暗示读过全文。
2. **扫描件取字**：probe 列出 `scanned_pages` → 逐页 `render.sh` + OCR →
   结果标注"OCR（Vision，150dpi）"，并保留页码。混合文档要分开报：哪些页来自文本层、
   哪些来自 OCR。
3. **表格抽取**：先 `--tables out/` 看有没有检出与行列数 → CSV 人工核对表头 →
   markdown 预览只用于展示，不作为数据源。
4. **两版比差异**：两次 `probe.py --json` 比页数/字体/表格数；再按页 `extract.py`
   做文本 diff。页码错位就报"页码语义不同（版本间增删页）"，不要硬对齐。
5. **PPT/Excel 清点**：pptx 看 slides/pictures/notes；xlsx 看 sheets 的 dims/rows/
   formulas/merged。工作簿里公式与缓存值分开报。
6. **打印/排版问题**：probe 的字体 `embedded`、页面 pt 尺寸；非嵌入字体与
   A4/Letter 混排是常见原因。结论只到"这个字段如此"，不替用户断言打印结果。

## Grounding 规则

- 页码、sheet 名、slide 号是引用的一部分；不写就等于不可复核。
- 抽取文本是**转换结果**：列顺序、脚注位置、页眉页脚都可能变；不要当原文排版引用。
- 表格结构是**画线推断**：无边框、跨页表、"表格其实是图片"都会误判。
- OCR 出来的内容标 OCR + dpi + 语言；不要与文本层内容混在一个引用里。
- 加密、无文本层、无画线表格：说"读不到/检不出"，不说"文档里没有"。
- `chars` 是文本层字符数，`words` 是分词结果，两者没有换算关系。

## 失败模式

- `encrypted=true` → 只报元数据；需要密码，别尝试破解。
- `scanned_pages` 命中但渲染后 OCR 也空 → 该页可能真是空白页或纯图形；看渲染图再定。
- 双栏/多栏文本顺序怪 → 对比默认与 `--layout`，选匹配版面的一种并说明选了哪个。
- 无边框表格 `[no tables detected]` → 换思路：按行坐标聚类或直接给渲染图。
- DOCX 有 `tracked_insertions` → 文本不含插入内容；要么请用户接受修订，要么读 XML。
- XLSX 公式单元格导出为空 → `--formulas` 或让 Excel 重算并保存缓存值。
- `pandoc` 对 PDF 报错 → 正常，PDF 用 `--text/--layout`。
- 中文字体未嵌入 → 打开正常但打印/别的机器可能替换字体；只报事实。
- `--tables` 对 docx/pptx 不支持 → 用 `--text`，表格会以 `--- table i ---` 附在文本里。

## 脚本与依赖

- `references/probe.py`：PyMuPDF（pdf）、python-docx、python-pptx、openpyxl；可选依赖缺失时逐类降级。
- `references/extract.py`：同上 + pdfplumber（表格）+ pandoc/pdftotext（外部命令）。
- `references/render.sh`：PyMuPDF 渲染，无额外依赖。
- `references/selftest.sh`：造 PDF/DOCX/PPTX/XLSX/MD/HTML 夹具，断言结构、文本层判定、
  表格 CSV、修订计数、公式、渲染尺寸；OCR 段只在兄弟技能与已缓存 Vision 二进制存在时跑。
  改脚本后先跑它。
