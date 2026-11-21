---
name: ui-understanding
description: Use when a task is about a user interface — a web page or app screen — and you must audit, describe, or debug it. Covers contrast ratios, target sizes, overlaps, truncation, layout numbers, design-vs-implementation comparison, native element trees, the DOM/computed-style channel, the macOS accessibility channel, what is only an image, and the unit conversions that make the numbers mean something.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# UI 理解（DOM / 可访问性 / 截图）

UI 理解 = 先确定"我有没有结构"，再量数字。
**有 DOM 或可访问性树才算量过布局**；只有截图时，一切间距与对齐都是像素推断。

三条证据通道（按可信度排序）：

- **DOM + computed style**：浏览器 DevTools MCP 读 `getComputedStyle`、`getBoundingClientRect`、
  DPR、文本溢出 —— 这是"实现是什么样"的原始事实。
- **可访问性树**：`agent-desktop` 读原生窗口的 role/name/frame —— 原生 App 的等价物。
- **像素**：截图 + OCR（`2d-understanding`）—— 没有结构时的兜底，结论必须标"推断"。

本技能自带两个纯计算脚本：`references/contrast.py`（WCAG 对比度）与
`references/geometry.py`（热区/重叠/越界）。它们不依赖浏览器，接受任何来源的数值。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断有没有结构）

| 你现在有什么 | 能答什么 | 不能答什么 |
|---|---|---|
| 网页 + 可操作浏览器 | computed style、rect、DPR、文本溢出、可访问性树 | 未渲染状态（hover 态的假设） |
| 原生窗口（macOS，可访问性已授权） | role/name/frame 层级 | 网页内部 DOM |
| 只有截图 | 像素尺寸、颜色采样、OCR 文本 | 真实间距、真实字号、真实层级 |

拿不到结构就明说"只有像素"，不要用"看起来对齐"补。

## 通道 1：DOM 与 computed style

用 **chrome-devtools MCP**（工具名前缀随环境，例如 `mcp__chrome_devtools_*`）。规则：
**新开标签页**做实验，不要导航用户正在用的页。

```text
new_page        url=data:text/html,... 或 file:///...      # 独立标签页
new_page        url=http://localhost:3000                   # 要审计的页面
evaluate_script pageId=2 function="() => {...}"             # 读数值
take_snapshot   pageId=2                                    # role/name/uid 树
take_screenshot pageId=2 filePath=<workspace 内路径>
```

`evaluate_script` 的返回值必须 JSON 可序列化。实测（本机 Chrome，DPR=2）：

```js
() => { const c = document.querySelector('#card'); const cs = getComputedStyle(c);
        const r = c.getBoundingClientRect();
        return {color: cs.color, bg: cs.backgroundColor, font: cs.fontSize,
                rect: [r.x, r.y, r.width, r.height], dpr: devicePixelRatio}; }
// -> {"color":"rgb(119,119,119)","bg":"rgb(255,255,255)","font":"16px",
//     "rect":[24,24,264,48],"dpr":2}
```

`evaluate_script` 默认 `waitForStableDom=true`（会等 DOM 稳定）；只读取样式/几何时
显式传 `waitForStableDom=false` 更快，截屏/交互前则保留默认值。`take_screenshot`
的 `filePath` 必须落在工作区根目录内（实测 `/tmp` 被拒：`not within any of the
configured workspace roots`）。

口径：

- `getBoundingClientRect()` 是 **CSS px**，不是设备像素。截图是设备像素：
  实测 viewport `1200x1402`、`dpr=2` 的截图正好 `2400x2804`（就是 ×2，无额外边距）。
  报告尺寸先写单位：`264 CSS px` vs `528 device px`。
- `getComputedStyle` 给的是**计算后**的值：`rgb(...)`、`16px`；继承来的颜色在元素上
  就是生效值，但 `background-color: transparent` 意味着要看父级。
- 文本溢出用 `scrollWidth > clientWidth`（水平）与 `scrollHeight > clientHeight`（垂直），
  再读 `text-overflow` / `white-space` 判断是不是有意截断。
- `take_snapshot` 的 `uid` **每次快照都会轮换**，页面一变就失效；重读快照，不要跨快照复用。
- 实测样例：一个 `32x32` 的按钮 rect 为 `[24,120,32,32]` CSS px —— 过 WCAG 2.2 的
  24×24 门槛，但不过 iOS HIG 的 44 pt；`geometry.py --platform ios` 会把它列进 `too_small`。
- iframe 内容不在主 frame 的 DOM 里；没切 frame 就读不到，别把"读不到"当"没有"。
- 工具调用失败（未连接浏览器）时如实说明，别用别处观感替代。

## 通道 2：原生窗口（macOS）

用 **agent-desktop**（CLI 或同名 MCP）：`snapshot --app <名字>` / `list-windows`。
得到 role、name、frame（points）。规则：先 `status` 确认 accessibility 已授权；
动作后重新 snapshot（refs 会过期）。

- 坐标是 **points**，Retina 屏上 1 pt = 2 px；与截图对比前先乘 scale factor。
- 系统语言影响 name 匹配（本机 zh-CN），优先按 window-id 过滤。

## 通道 3：只有截图

- 文本：交给 `2d-understanding` 的 `references/ocr.sh`，坐标是归一化的（见该技能口径）。
- 实测闭环：DPR=2 的 `2400x2804` 页面截图交给 `2d-understanding` OCR，取回
  `Settings saved` / `Your changes are live on all devices.` —— 像素通道能用，
  但它给不了字号与间距。
- 颜色：需要"设计稿里这个按钮是什么颜色"这类问题时，用 Pillow 取**平坦区域**的像素；
  抗锯齿边缘与渐变不许采样。
- 间距/对齐：只能报像素距离，且标注"从截图量得，非 DOM"。

---

## 脚本

### `references/contrast.py`（WCAG 2.x）

```bash
references/contrast.py "#777777" "#ffffff"
references/contrast.py "#ff0000" "#ffffff" --font-size 24     # large text
references/contrast.py "rgba(0,0,0,0.54)" "#ffffff" --json    # 半透明先合成
```

- 公式：sRGB 线性化后的相对亮度，`(L1+0.05)/(L2+0.05)`。实测参考值：
  `#000000`/`#ffffff` = 21.00；`#777777` = 4.48（**不过** AA 正文 4.5）；
  `#767676` = 4.54（过）；`#ff0000` = 4.00（不过正文，过 3.0 的 UI 门槛）；
  `rgba(0,0,0,0.54)` on white 合成为 `#757575`、4.59。
- 阈值：AA 正文 4.5、大字号 3.0、UI/图形 3.0；AAA 正文 7.0、大字号 4.5。
  大字号 = ≥24 px，或 ≥18.66 px 且加粗（WCAG 1.4.3）。
- 半透明前景会先按背景合成，输出 `composited_foreground`；背景本身也必须不透明，
  渐变/图片背景算不了——明说，不要硬算。

### `references/geometry.py`（尺寸与重叠）

```bash
references/geometry.py boxes.json --viewport 1440x900
references/geometry.py boxes.json --platform ios      # 44pt；android=48；wcag=24 CSS px
```

- 输入：`{"unit": "css-px|pt|dp|px", "boxes": [{"name","x","y","w","h"}]}`。
  来源可以是 `getBoundingClientRect`、a11y frame 或截图测量——**同一个文件只能是一种单位**。
- `unit: "px"` 是设备像素：加 `--dpr 2`/`--dpr 3` 让 24 CSS px 等门槛按 DPR 放大，
  否则 2x 截图里的热区会被判得过宽。
- 缺 `boxes` 键、box 不是对象、坐标里有 NaN/Infinity → 明确报错或记 `malformed`，
  不会输出"没有问题"的假通过。
- 输出：过小的热区（WCAG 2.2 AA 24×24 CSS px、iOS 44 pt、Android 48 dp）、
  两两重叠面积、越界框、非正尺寸/缺字段。
- 重叠不自动等于缺陷：嵌套元素天然重叠，只有面积异常或同类控件互压才是问题。

---

## Playbooks

输出都带来源：选择器/窗口、数值、单位、命令。

1. **设计稿 vs 实现**：固定视口与 DPR 截两张图 → `2d-understanding` 的像素 diff；
   再对关键元素读 rect（CSS px）核对间距差值。像素差异只能说明"变了"，
   间距数值才说明"错了多少"，两者分开报。
2. **对比度审计**：从 computed style 取 `color` 与最近的**不透明**背景色 →
   `contrast.py --font-size <计算值>`。渐变、图片、阴影背景直接报"不可计算"。
3. **热区检查**：DOM 取按钮 rect 或 a11y 取 frame → `boxes.json` → `geometry.py`；
   平台阈值写清（web/ios/android）。
4. **文本截断**：`scrollWidth/clientWidth`、`text-overflow`、`-webkit-line-clamp`；
   结论给元素选择器与两个数值，不说"看起来被截了"。
5. **原生窗口清点**：`agent-desktop snapshot` 出 role/name/frame；与截图对照时
   把 points × scale 换成像素再比。
6. **只有截图时**：OCR 文本 + 平坦区颜色采样 + 像素距离；每条都标"截图推断"。

## Grounding 规则

- 每个尺寸带单位与来源：`264 CSS px（getBoundingClientRect）`、`528 px（截图）`。
- 对比度只对**两个具体颜色**成立；不给"整体可读性"打分。
- 截图采样色 ≠ computed color；抗锯齿边缘、半透明、渐变都不可采样。
- a11y frame 与 DOM rect 坐标系不同（points vs CSS px），不混算。
- 只说"这一项检查通过/失败"，不说"符合 WCAG"或"无障碍达标"。
- 没有结构就写"未测布局"，不用观感替代。

## 失败模式

- DPR 混淆：截图是 2×（实测 2400×2804 vs CSS 1200×1402）；拿截图宽除 DOM 宽得 2 不是布局错。
- `background-color: transparent` 或渐变背景 → 对比度无解；向上找不透明祖先，找不到就报不可算。
- 字体尚未加载完就读 rect → 数字会变；等 `document.fonts.ready` 后再读。
- 暗色模式/主题变量 → 同一元素不同主题下对比度不同；报告必须写主题。
- iframe / shadow DOM → 主 frame 读不到；切 frame 或 `shadowRoot` 显式取。
- a11y `uid`/refs 过期 → 重读 snapshot。
- 截图里的文字 OCR 空 ≠ 没有文字（见 2d 技能的大图裁剪规则）。
- 任何"平均间距""整体对齐"式的归纳 → 没有逐元素数值支撑就不要写。

## 脚本与依赖

- `references/contrast.py`：纯 Python，无第三方依赖。
- `references/geometry.py`：纯 Python，读 JSON。
- `references/selftest.sh`：断言 WCAG 参考值（21.00 / 4.48 / 4.54 / 4.00 / 3.03）、
  半透明合成、大字号判定、坏输入退出码，以及几何检查（过小、重叠面积、越界、非正尺寸）。
- 通道依赖：chrome-devtools MCP（浏览器）、agent-desktop（原生窗口）、
  `2d-understanding`（OCR）。缺失时只用像素通道并如实标注。
