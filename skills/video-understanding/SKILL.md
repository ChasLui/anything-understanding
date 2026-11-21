---
name: video-understanding
description: Use when a task involves a video file (MP4/MOV/MKV/WebM/AVI/TS) and you must describe, audit, or debug it — duration and stream layout, rotation and displayed size, variable frame rate, HDR/color tagging, scene cuts, black and silent intervals, frame extraction, contact sheets. Covers which ffmpeg measurement answers which question, what each number does and does not mean, and how to hand frames to OCR.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# 视频理解（容器 + 时间轴 + 帧）

视频理解 = 把一部片子变成可复述、可验证的数值事实，再谈内容。
**先量后说**：没有探测结果的描述（"应该是竖屏""这段挺黑的""帧率 30"）
一律是猜测，不能作为结论。

三条证据通道：

- **容器与流**：`ffprobe` 读容器/码流头部，出规格、旋转、帧率、色彩标签。
- **时间轴结构**：`scene`/`blackdetect`/`silencedetect` 过滤器出剪辑点、黑场、
  静音段 —— 都是测量值，不是"看起来换镜头了"。
- **像素帧**：抽帧与 contact sheet 产出图像；帧里的**文字**交给兄弟技能
  `2d-understanding` 的 `references/ocr.sh`，本技能不复制那个脚本。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能不能答）

```bash
cd <本技能目录>
references/probe.sh clip.mp4
```

拿不到就明说，不要用播放器的观感补：

| 问题 | 能答的通道 | 拿不到时的说法 |
|---|---|---|
| 时长/容器/码率/流数量 | 容器头（ffprobe） | — |
| 竖屏还是横屏、画面多大 | display matrix 的 rotation | "无 rotation side data，方向不可判定" |
| 恒定还是可变帧率 | `r_frame_rate` vs `avg_frame_rate` | 只有一帧的片段判不了 VFR |
| 是不是 HDR | `color_transfer` = smpte2084 / arib-std-b67 | 无 tag → "未标注"，不是"是 SDR" |
| 哪些时间点换镜头 | `select` 的 scene score | 分数是候选，不是语义剪辑点 |
| 黑场/静音在哪 | `blackdetect`/`silencedetect` | 无音轨 → "未测静音" |
| 某一秒的画面 | `frames.sh --at` | 超出时长 → 无帧（exit 3） |
| 画面里的文字 | 兄弟技能 `2d-understanding/references/ocr.sh` | OCR 空 ≠ 没字 |

依赖：`ffmpeg`/`ffprobe`（本机实测 9.0.2）+ `python3`。
本机**没有** mediainfo 和 mpv；`exiftool` 有，但视频容器用它拿不到流布局。

---

## 容器与流：`probe.sh`

```bash
references/probe.sh clip.mp4            # 人类可读
references/probe.sh clip.mp4 --json     # 机器可读，字段缺失一律 null
```

输出字段与**口径**（引用时必须带上限定语）：

- `bytes`：文件字节数（`stat`），不是码流数据量；`bitrate_bps` 默认取容器头，
  缺失时按 `bytes*8/duration` 推算并标 `bitrate_source`。
- `stored_size` vs `displayed_size`：容器里写的宽高是**存储尺寸**；
  `rotation_deg`（display matrix side data）为 ±90/±270 时 `displayed_size` 交换宽高。
  实测 `-display_rotation 90` 的原样 copy：`stored 320x240`、`rotation 90`、
  `displayed 240x320`；ffmpeg 解码默认 autorotate，输出帧就是 240x320。
  另测 `-display_rotation 270` 和 `-90` 都被 ffmpeg 归一化成 side data `-90`，
  `180` 写成 `-180` 且不换宽高。报告布局尺寸用 `displayed_size`，
  报告"码流里存的像素"用 `stored_size`，说哪个标哪个。
- `fps` / `fps_r` / `fps_avg` / `vfr`：`fps` 是 `r_frame_rate` 的十进制值；
  `vfr` 只在两者差异 >0.5% 时为 true。实测丢帧 VFR 夹具：`r 25/1`、
  `avg 625/37`（16.892），`vfr=true`。**avg_frame_rate 是容器统计的平均值**，
  不是"每一帧的间隔"：VFR 片子里帧间隔不均匀，这个平均值不能当帧时钟用。
- `pix_fmt` / `color.*` / `hdr`：HDR 判定只看 `color_transfer` 是否为
  `smpte2084`（PQ）或 `arib-std-b67`（HLG）；无 tag 时 `hdr=null`，
  只能说"未标注"。实测两个坑：
  - `-color_trc smpte2084` 单给 libx264/libx265 **不写进码流**（probe 仍读到 null），
    要 `-x264-params transfer=smpte2084:colorprim=bt2020:colormatrix=bt2020nc`
    或 `-vf setparams=color_trc=...` 才会出现；`-color_range` 同理可能丢。
  - 10-bit `yuv420p10le` 不等于 HDR：位深和传输函数是两件事。
- `bit_rate_bps`（每流）：MP4/MOV 有；**Matroska 没有**，实测返回 null。
  缺失就是缺失，不要用容器码率除以流数去"估"。
- `audio[].language`：容器标签，常见 `und`（未定）或缺失；它不是"没人说话"。
- `counts`：`video/audio/subtitle/attachment` 计数。附件（字体等）在 mkv 里
  是独立 stream，字幕语言在 `stream_tags.language`。
- `frames`：`nb_frames`，MP4 有、部分容器没有；没有就是 null。

## 时间轴：`scene.sh`

```bash
references/scene.sh clip.mp4                              # 三段时间轴
references/scene.sh clip.mp4 --threshold 0.3 --json
references/scene.sh clip.mp4 --min-black 0.1 --pix-th 0.10 \
  --silence-db -45 --min-silence 0.5
```

三次独立 ffmpeg pass，**故意不合成一次**：`select` 会丢帧，把
`blackdetect` 接在它后面就只测了"留下来的切点帧"，得到的黑场是假的。

- **景别切换（cuts）**：`select='gt(scene,T)',showinfo,metadata=print`
  一次拿到时间戳和 `lavfi.scene_score`。分数是 0..1 的**亮度变化分**：
  实测红→黑 `0.65`、黑→蓝 `0.25`。它不是"换镜头概率"，纯色硬切分数偏低，
  运镜/闪光分数偏高。默认 `T=0.2`；实拍噪点大用 0.3–0.4，
  fade 过渡想要更多候选就降到 0.1。showinfo 里的 `mean:[16 128 128]`
  是像素均值（0..255），**不是** scene score，别抄错字段。
- **黑场（black）**：`blackdetect=d=<min>:pix_th=<0..1>`，`pix_th` 是
  像素级亮度阈值（默认 0.10），不是 letterbox 检测 —— 上下黑边会不会入选
  取决于时长和阈值，不要据此断言"这是宽银幕"。实测 `black_start:1
  black_end:2 black_duration:1`。
  黑场一直持续到文件尾时，`black_end` 是**最后一个黑帧的 pts**：
  2 s / 10 fps 的纯黑夹具报 `0.000-1.900`，比真实时长少一个帧间隔。
- **静音（silence）**：`silencedetect=n=-40dB:d=0.3` 走**第一条音轨**；
  实测 2 s 正弦 + 1 s `anullsrc`：`silence_start 2.000`、`silence_end 3.000`、
  `duration 1.000`（原始输出是 `1.999977`，脚本四舍五入）。
  多音轨要按 `-map 0:a:N` 分别跑，本脚本只测第一轨。
- 时间戳都是容器时间轴；VFR 夹具（duration 2.96）也照此报告，不重采样。

## 帧：`frames.sh`

```bash
references/frames.sh clip.mp4 --interval 1 --out frames/
references/frames.sh clip.mp4 --at 0.5,2 --out frames/ --json
references/frames.sh clip.mp4 --tile 8 --cols 4 --width 320 --out frames/
```

- **`--interval S`**：`fps=1/S` 采样，第一帧在 `t=0`，之后每 S 秒一帧，
  **最后一帧 < duration**。实测 3 s / `S=0.5` → 6 帧 `0,0.5,1.0,1.5,2.0,2.5`；
  `S=1` → 3 帧 `0,1,2`。不要按"帧数 = duration/S"断言，以 manifest 为准。
- **`--at t1,t2`**：三次尝试、每次都校验 `|t_s - 请求| <= max(0.25s, 1.05/fps)`
  （fps 由 ffprobe 取）：① input seek + `-copyts`（精确优先）；
  ② 加 `-noaccurate_seek`（低帧率、请求落在末帧之后时取覆盖该时刻的帧）；
  ③ output seek（`-ss` 在 `-i` 后，MPEG-TS 这类 `start_time != 0` 的容器兜底）。
  三次都不满足就报"无帧"（请求早于首帧同样如此），不再把几秒后的画面当答案。
  manifest 里的 `t_s` 是 `showinfo` 读回来的**真实帧 pts**，`requested_t_s` 是请求值。
  实测 25 fps / 帧格 0.04 s：请求 `0.5` 得到 `0.52`（第一个 ≥ 请求的帧），
  请求 `1.0` 恰好命中 `1.0`。这就是"取图会向前对齐一格"的量化误差。
- seek 快慢实测（30 s 640x480 @ t=28）：input seek `0.13 s`，output seek
  `0.22 s`，两帧字节相同。`-noaccurate_seek` 在 ffmpeg 9.0.2 上试了三组
  （含 10 s GOP 的文件）都没改变取到的帧 —— 老说法"input seek 只到关键帧"
  在本机复现不出来，别照抄；要么用本脚本，要么自己复测。
- **`--tile N`**：`fps=1/step` + `scale=W:-2` + `tile=CxR`，一张 PNG。
  `step` 缺省 = duration/N；给了 `--interval` 就用它。`--cols` 默认 4，
  cell 宽默认 160。实测 4 格 160px → `640x120`；8 格 `--cols 4 --width 320`
  → `1280x480`。cell 高用 `-2` 取偶数（yuv420 要求）。
  rotation 源会被 autorotate：实测 8 格 / `--cols 2 --width 100` 的竖屏源
  得到 `200x536`（每格 100 宽、按显示方向算高）。
- manifest 的 `timestamp_source` 固定写 `showinfo pts_time`：时间戳是读回来的，
  不是算出来的。请求时间点超出时长 → 该点无帧，`exit 3`（manifest 照常打印）。
- 自己写 ffmpeg 时注意 ffmpeg 9 已**移除** `-vsync`，要用 `-fps_mode vfr`。

## 帧里的文字：交给 `2d-understanding`

不复制 OCR 脚本，直接调用兄弟技能的通道：

```bash
references/frames.sh clip.mp4 --interval 1 --out frames/
../2d-understanding/references/ocr.sh frames/frame_001_t0.000.jpg --json
```

- 坐标、语言、大图裁剪规则全在 `2d-understanding/SKILL.md`，不要在这里重写。
- 实测纯色帧 OCR 返回 `lines: []`：**OCR 空 ≠ 画面没字**，
  可能是纯色/无字，也可能是大图或小字丢失，先按 2d 技能的裁剪规则重跑。
- 视频抽帧是 JPEG（有损），OCR 前不要把帧再缩放一次。

---

## Playbooks

输出都带来源：命令、字段、文件路径。无法回溯的数值不写。

1. **"这是什么片子 / 规格是什么"**：`probe.sh --json` 出容器、时长、流数量、
   分辨率、fps、pix_fmt、HDR、rotation。描述顺序固定：容器 → 时长/码率 →
   视频规格（含 displayed_size）→ 音频 → 字幕/附件。不写"画质不错"。
2. **转码/播放失败诊断**：probe 看 codec/profile/pix_fmt（`yuv420p10le`、
   `yuv444p` 很多播放器不支持）、rotation（播放器不 autorotate 就会躺倒）、
   HDR tag（无 tag 的 PQ 内容会被当 SDR 洗白）、`vfr`（部分剪辑软件对 VFR 处理差）。
   每一项只能说"这个字段是这样"，不能断言"所以一定播不了"，要复现一次。
3. **找剪辑点/切片**：`scene.sh` 先出 cuts，再看 black/silence 对齐。
   切点分数只作候选；把 `--threshold` 调一次看结果是否稳定，
   两档阈值给出不同切点数量时，报告"候选不稳定"，不要挑一档当事实。
   长片/4K 别直接跑全片：实测 8s 4K HEVC 全片 `scene.sh` 10.7s（user 27s），
   成本几乎全在解码；先用 `-ss/-t` 截 30–60s 或生成 720p 代理再测。
   黑场/静音边界**抽一帧确认**再定性：`frames.sh --at <边界>` 看是真黑场，
   还是片头 fade-in 前的黑帧 —— 阈值只说明"亮度低于 pix_th"，不说明成因。
4. **取封面/关键帧并读字**：`frames.sh --at <t>` 取图 → 兄弟技能 OCR。
   时间点要写进结论（含实测 pts 与请求值的差）。
5. **审片联系表**：`frames.sh --tile 12 --cols 4 --width 320`，按 duration/12
  均匀采样；sheet 是单张图，**格子里没有时间戳**，要标时间就在结论里写
  采样公式或改用 `--interval` 的 manifest。
6. **多音轨/字幕清点**：`probe.sh` 的 `counts` + `audio[].language` +
  字幕流；语言标签缺失就写"未标注"，不猜语种。

## Grounding 规则

- 时间戳带单位，并说明来源：容器时间轴 / 实测帧 pts / 请求值，三者不混用。
- `stored_size` 与 `displayed_size` 分开说；只报一个就标是哪个。
- 无 `color_transfer` tag 时只能报"未标注"，不能报 SDR，也不能报 HDR。
- scene score 是 0..1 亮度变化分，不是语义；引用时带阈值。
- 黑场/静音是**阈值判定**：给出 `pix_th`、`-dB`、最短时长，否则结论不可复现。
- 流级码率缺失写 null；容器码率不能拆成流码率。
- 抽帧时间戳写实测值；请求值与实测值不同就都写出来。
- 没测的通道明说（"无音轨，未测静音"），不用别处的观感替代。

## 失败模式

- `ffprobe` 报不出 per-stream `bit_rate`（mkv 常见）→ 正常，写 null，别推算。
- `rotation` 缺失但画面明显是竖的 → display matrix 被转码链丢过或已烙进像素，
  报"方向不可判定 / stored == displayed"。
- `vfr=true` 却拿 `avg_frame_rate` 当帧时钟 → 时间点会漂；用 `--at` 抽帧核对。
- 黑场在文件尾结束 → `black_end` 是最后一帧 pts，短片段会少报一个帧间隔。
- 静音检测只覆盖第一条音轨 → 多音轨时其余轨道的静音没测。
- 请求时间戳超过时长 → `frames.sh` 不产帧、exit 3（manifest 仍会打印）；
  别拿空目录当"没有画面"。
- 多视频流/多音轨：`scene.sh` 只测第一条视频流和第一条音轨，其余轨道
  要按 `-map` 自己补跑，否则是漏测而不是"没有切点/静音"。
- 阈值太高漏切、太低全成切点 → 两档阈值交叉验证后再下结论。
- ffmpeg 版本差异会改行为（实测 9.0.2：`-vsync` 已删；`-color_trc` 不写码流）。
  换机器先跑一遍 `references/selftest.sh`。
- 只有 ffmpeg/ffprobe 可用：本机无 mediainfo、无 mpv，不要写依赖它们的命令。

## 脚本与依赖

- `references/probe.sh`：ffprobe + python3（组装 JSON，无 jq 依赖）。
- `references/frames.sh`：ffmpeg + ffprobe + python3；`--json` 出 manifest。
- `references/scene.sh`：ffmpeg ×3 pass + python3；`--json` 出区间。
- `references/selftest.sh`：lavfi 造夹具（红/黑/蓝三段 + 正弦与静音 +
  rotation copy + VFR + HDR 标签 + 字幕/附件 mkv），断言实测字段，约 10 s。
  改脚本后先跑它。
