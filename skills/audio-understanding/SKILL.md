---
name: audio-understanding
description: Use when a task involves audio — recordings, podcasts, meetings, screen-recording tracks, voice memos — in WAV/MP3/M4A/AAC/FLAC/AIFF/MOV, and you must describe it, QC it, or transcribe it. Covers container and stream facts with an afinfo cross-check, lossy-vs-PCM and sample-rate/bit-depth limits, integrated LUFS / LRA / true peak, silence intervals, clipping evidence, and whisper.cpp transcripts with per-segment timings and model provenance.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# 音频理解

音频理解 = 把一段听不见的波形变成可复述、可验证的数值事实，再谈内容。
**先量后说**：没测过的响度、"大概没削波"、"应该说的是这个意思"，一律是猜测。

三条通道，各自有明确的能力边界：

- **容器与流**：`probe.sh`，ffprobe 取证 + afinfo 交叉验证。
- **响度/静音/削波**：`loudness.sh`，一趟解码跑四个 analysis filter。
- **语音内容**：`transcribe.sh`，whisper.cpp，附模型来源与墙钟时间。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能不能答）

```bash
cd <本技能目录>                              # 例：~/.claude/skills/audio-understanding
references/probe.sh meeting.m4a              # 先看是什么，再决定能不能测
```

| 问题 | 能答的通道 | 拿不到时的说法 |
|---|---|---|
| 什么格式/采样率/声道/位深 | ffprobe 头部 | — |
| 有损还是 PCM、压缩了什么 | `codec_name` + `bits_per_sample` | codec 不认识 → "编码未知" |
| 有没有多轨、带不带视频 | stream 枚举 + afinfo `Num Tracks` | afinfo 打不开 → "只有 ffprobe 单通道" |
| 容器时长和流时长是否一致 | `format.duration` vs `stream.duration` | 两者都缺 → 只能报容器值 |
| 整体多响、动态多大 | ebur128（LUFS/LRA/true peak） | 有损源 → 数字来自解码样本，不是母带 |
| 哪段是静音 | silencedetect（阈值是参数） | 阈值没写进结论 → 结论不可复现 |
| 削没削波 | `max_volume` + true peak + flat factor | ffmpeg 没有"削波样本计数" → 只能说疑似 |
| 说了什么、什么时候说的 | whisper-cli + 模型来源 | 没有可用模型 → 给下载命令，不猜内容 |
| 谁在说（说话人分离） | — | 未验证，不要凭直觉标注 |

依赖：`ffmpeg`/`ffprobe`、`python3`；`afinfo`（macOS 自带）；
`whisper-cli`（`brew install whisper-cpp`）+ 一个真实模型。缺哪个就写哪个没测。

---

## 容器与流：`probe.sh`

```bash
references/probe.sh track.wav                  # 人类可读 + flags
references/probe.sh track.wav --json           # 机器可读
```

输出字段与**口径**：

- `audio_streams[].codec` + `kind`：`pcm` / `lossless-compressed`（flac、alac、wavpack…）
  / `lossy`（mp3、aac、opus、vorbis…）/ `unknown`。分类来自 codec 名单，不是猜的：
  名单外的编码会报 `unknown` 并加 `unknown_codec` flag，不会硬塞进"有损"。
- `sample_rate`、`channels`、`channel_layout`：**mono PCM WAV 的 `channel_layout` 是
  `null`**（实测 pcm_s16le 1ch），而 mp3/aac 单声道反而写 `"mono"`。
  所以声道布局一律以 `channels` 为准，`null` 不等于"布局未知"。
- `bits_per_sample`：PCM 是真实位深（16/24）；**有损编码是 0**；
  **flac 也是 0**，真实位深在 `bits_per_raw_sample`（实测 flac 为 `"16"`）。
  报位深时先看 `bits_per_sample`，为 0 再看 `bits_per_raw_sample`。
- 采样率异常：`< 16000` 记 `low_sample_rate`（只剩 `sr/2` Hz 以下的频段，
  转写前会被重采样到 16 kHz）；不在
  {16000,22050,24000,32000,44100,48000,88200,96000,176400,192000} 里记
  `unusual_sample_rate`。44.1k 与 48k 本身不是异常，只是两种不同来源。
- 多轨：`multiple_audio_streams`（实测一个 mov 里 2 条 aac 音轨能被分开报出），
  带视频记 `has_video`。**有损文件里的封面图也是 video stream**，
  脚本按 `disposition.attached_pic` 排除，不给 mp3 误报 `has_video`（实测带封面的 mp3 无此 flag）。
- 时长不一致：`|format.duration - stream.duration| > 0.05s` 记 `duration_mismatch`。
  实测录屏式文件：容器 4.000s、音轨 2.000s，delta −2.000s —— 这种文件
  **不能拿容器时长当音频时长**。
- `timestamp_offset`：`start_time != 0` 时记。实测 mp3 从 0.025s 起、
  mpegts 从 1.400s 起（编码器 delay / muxer 偏移），拼接、对齐字幕前必须知道。
- `afinfo` 交叉验证：同一文件由 CoreAudio 再报一遍 `Num Tracks`、`Data format`、
  `estimated duration`。它读 WAVE/AIFC/MPG3/m4af/MooV/flac，**读不了 mpegts**
  （实测 `Fail: AudioFileOpenURL failed`，exit 1 → 记 `afinfo_unavailable`，
  这是"没有第二通道"，不是"文件坏了"）。
- 两个通道不一致时各记一个 flag，**不做平均**：
  实测 mp3 的 afinfo 时长 2.038s vs ffprobe 2.000s（编码器 padding），
  录屏 mov 的 afinfo 只报音轨 2.000s、容器 4.000s（`afinfo_duration_delta`）。

退出码：0 正常；1 用法错；2 读不到文件；3 没装 ffprobe；4 ffprobe 打不开。

## 响度、静音、削波：`loudness.sh`

```bash
references/loudness.sh podcast.mp3                  # 默认静音阈值 -40 dB / 0.3s
references/loudness.sh podcast.mp3 --json
references/loudness.sh call.wav --silence-db -35 --silence-min 0.6
```

一趟解码，同一条 filter chain：`ebur128=peak=true,silencedetect,volumedetect,astats`。

- `loudness.integrated_lufs`：积分响度（EBU R128）。**地板是 −70.0 LUFS**，
  纯数字静音也只会报 −70.0，脚本同时给 `integrated_floor: true`，
  别把"−70"当成测出来的极小声。
- `loudness.lra_lu`：响度范围。单频正弦实测 0.0 LU；接近 0 说明整段动态一致
  （正弦、纯静音、或压限压到几乎没有起伏），不是"安静的录音"。
- `loudness.true_peak_dbfs`：true peak（4× 过采样）。**纯静音是 `-inf`，JSON 里是 `null`**。
- `volume.mean_db` / `volume.max_db`：volumedetect 的样本均值/峰值（0.1 dB 精度）。
- `clipping`：ffmpeg 没有"削波样本数"，这里给三个证据 + 一个推论：
  - `true_peak_dbfs >= 0` 或 `max_volume_db >= -0.05` → `suspect: true`；
  - `flat_factor`：astats 的波形平坦度。实测削波正弦 32.456、干净正弦 0.000，
    但**安静的正弦（−20 dB）也有 6.021、3 声道 96k 文件是 −37.068**，
    所以 flat factor 单独为正**不能**判削波，只能配合满刻度峰值一起看；
  - `abs_peak_count` / `samples`：原始计数，供自己复核。
- `silence.intervals`：`silence_start` / `silence_end` 配对，单位秒，端点来自
  silencedetect 的 100ms 网格（实测 1.000→1.500，时长 0.500）。
  **尾部静音会在文件结束处闭合**（实测 1.000→2.000），不会漏一个 open interval。
- `silence.threshold_db` / `min_duration_s`：把参数写进结果，否则"有 3 段静音"
  这句话不可复现。实测同一个 0.5s 空隙：`-40dB/0.3s` 报 1 段，`-35dB/0.6s` 报 0 段。
- 解析口径：ebur128 每 100ms 打一行 `[Parsed_ebur128_0 @ …] t: … I: … LUFS`，
  只有缩进的 summary 块（`I: / LRA: / Peak:` 三行，行首是空格而不是 `[Parsed_...]`）才是总结值；
  astats 先按声道各打一块、最后打 `Overall`，脚本一律取**最后一次出现**，
  所以声道数不影响取值。

退出码：0 正常；1 用法错；2 读不到；3 没装 ffmpeg；4 解码失败或没有音轨。

## 语音转写：`transcribe.sh`

```bash
references/transcribe.sh memo.m4a                        # 人类可读
references/transcribe.sh memo.m4a --json                 # 逐段 seconds
references/transcribe.sh zh.mp3 --lang zh                # 强制中文
references/transcribe.sh memo.m4a --model ~/.cache/whisper.cpp/ggml-small.bin
WHISPER_MODEL=/path/ggml-small.bin references/transcribe.sh memo.m4a
```

- 模型解析顺序：`--model` → `$WHISPER_MODEL` → `~/.cache/whisper.cpp/ggml-*.bin`
  → `/opt/homebrew/share/whisper-cpp/ggml-*.bin` → `./models/ggml-*.bin`。
  每个目录内按质量阶梯取：
  small → base → tiny → medium → large-v3-turbo → large-v3/v2/v1 → 其他 `ggml-*.bin`。
  **不按字母顺序**，否则 `.en` 英文专用模型会先命中，非英语音频就废了。
- 拒绝两类模型，都 exit 2 并说明原因：
  - `for-tests-*`：whisper.cpp 自带测试夹具，有真的元数据但没有权重。
    实测它 **exit 0、`transcription: []`、`result.language` 是 "af"** —— 用它会把
    "没有内容"伪装成"没有语音"。
  - 小于 1 MB 的文件：装不下权重，直接拒。
- 没有可用模型时打印**可直接粘贴的 `curl` 下载命令**（tiny 74 MB / base 142 MB，
  来自 huggingface.co/ggerganov/whisper.cpp）并 exit 2。
- 输入一律先转 16 kHz 单声道 `pcm_s16le`。whisper-cli 1.8.4 其实能直接吃 44.1k 立体声
  WAV/AIFF/MP3（走 miniaudio，实测文字一致，只有大小写与末段时长略有差别），
  但转换让时间戳稳定、也不依赖那个未写进 `--help` 的行为（`--help` 只承诺 flac/mp3/ogg/wav）。
- 输出 `segments[]`：`start_s` / `end_s` **秒**（JSON 原始是毫秒 offset），`text` 去首尾空白。
  `text` 是各段拼接，**不改写、不纠错**。
- 时间戳是 whisper 的 10 ms 网格：**最后一段的 `end_s` 可能超过音频时长**
  （实测音频 3.920s，末段 0.000→4.000s）。做断言时要留 ~0.2s 容差。
- `language`：`-l auto` 时是检测结果；**显式 `-l zh` 时只是回声**
  （实测对英文音频 `-l zh` 报 `zh`，文本仍是英文）→ `language_requested` 一起输出。
- `empty: true` 时脚本在 stderr 警告，但 exit 0：纯音、纯静音、语言不对都会
  得到空段（实测 440 Hz 正弦与 anullsrc 都是空），这是有效结果，不是崩溃。
- `wall_ms` 是 whisper-cli 那一步的墙钟（用 python3 取毫秒时间戳，含进程启动）。
  实测 base 处理 3.92s 音频 0.68s（5.7× 实时），24.12s 中文 1.23s（19.6× 实时）。

退出码：0 正常（含空转写）；1 用法错；2 读不到文件/没有可用模型；
3 缺工具；4 ffmpeg 解码失败；5 whisper-cli 失败或没写出 JSON。

## 模型与语言的选择（有实测的部分）

| 场景 | 建议 | 依据（本机实测） |
|---|---|---|
| 英语短句、要快 | tiny 或 base 都够 | tiny 3.92s→0.66s，文本正确 |
| 英语长句、要标点 | base 起 | 同一段 17s 英语，tiny 把 riverbank 断成 river bank、vow 听成 bow |
| 中文短句 | tiny 内容基本正确，标点/简繁会缺会漂 | 4.6s 中文 TTS：tiny 与 base 都得到"今天天气很好,我们去公园散步"；base 多一个句号；字符形式（简/繁）跨运行不稳定，见下行 |
| 中文长句、含人名/术语 | 至少 base，重要内容换模型复核 | 24.1s 中文：tiny 10 段、同音错"張維/上限"；base 2 段、同音错"嫉妒(季度)/上限" |
| 繁体/简体 | 不可作为语种/地区判据 | 同一段简体 TTS：tiny 第一次输出"今天天气很好"（简体），重跑两次输出"今天天氣很好"（繁体）；多线程推理不是逐位确定的，简繁形式会漂 |

中文结论只覆盖**干净 TTS 短音频**；长录音、多人、口音、噪声下的中文质量**未验证**。
同音字错误（嫉妒/季度、上限/上线）是这类模型的常态，人名、数字、术语要二次核对。

## Playbooks

输出都带来源：命令、字段、文件路径。无法回溯的数值不写。

1. **播客/会议 QC**：
   `probe.sh` 拿格式与异常 → `loudness.sh` 看积分响度是否落在目标带
   （参考惯例：播客交付常以 −16 LUFS 为目标、广播 −23 LUFS；LRA 极小时要先怀疑压限过度）、
   静音占比、true peak 是否越 0
   → `transcribe.sh --json` 出逐段文本 → 抽查开头/人名/数字。
   报告顺序固定：格式 → 响度 → 静音 → 内容。
2. **录屏音轨**：`probe.sh rec.mov` 先看 `has_video` 与 `duration_mismatch`
   （实测容器 4.0s、音轨 2.0s），再 `loudness.sh rec.mov`（音轨自动选取），
   最后 `transcribe.sh rec.mov`（ffmpeg 抽取音轨，实测可直接转写视频文件）。
   音轨比视频短就明说"最后 N 秒没有音频"，不要拿容器时长算语音覆盖率。
3. **削波/响度 triage**：`loudness.sh --json` 看三件事：
   `true_peak_dbfs`、`max_volume_db`、`flat_factor`。三者都顶格 → 真削波；
   只有 flat factor 异常（如 −20 dB 正弦的 6.021）→ 量化/平坦波形，不是削波。
   有损源的峰值受解码器影响，别拿它做母带级判断。
4. **ASR 到笔记**：`transcribe.sh --json` → 用 `segments[].start_s` 做时间轴，
   每段标注模型名与语言（`model.type`、`language`、`language_requested`）。
   同音字、专有名词、货币/数字必须复核；空段要写成"无语音段"，不要编内容。
5. **多语言/多模型对比**：同一文件跑两次（`--model` 指定不同模型），
   比 `text` 与 `segments`；差异处标记"模型不一致"，这是最便宜的不确定性信号。
   `.en`（含量化名如 `ggml-tiny.en-q5_1.bin`）在显式 `--lang <非英语>` 时
   直接拒绝（exit 2）；`--lang auto` 只会警告"英语专用模型可能把其他语言转成英语"。

## Grounding 规则

- LUFS/LRA/true peak 是**解码后样本**的测量；有损源解码会改变波形，
  数字只能横向比较同源文件，不能当母带指标。
- 静音是"低于阈值且持续 ≥ N 秒"，阈值必须随结论一起写出来。
- 削波只能说"疑似"，并附 `true_peak` / `max_volume` / `flat_factor` 三个原始值。
- 位深分 `bits_per_sample` 与 `bits_per_raw_sample`，报哪个标哪个；有损文件没有位深。
- 声道布局以 `channels` 为准，`channel_layout` 可能是 `null`。
- 转写文本是模型输出，**不是听到的事实**；引用时写明模型类型与语言字段的来源。
- 时间戳精度是 10 ms 网格，末段可能超出文件时长；不要用它反推码率或精确时长。
- 空转写 ≠ 没有声音：可能是静音、语言选错、模型不对，三种都要排除后才能下结论。
- 不做说话人身份、情绪、内容真伪的判断；没有对应通道就不答。

## 失败模式

- `say -v Tingting` 生成"中文"素材，结果转写全是乱码 → 本机 `say -v '?'` 只有 12 个
  en 音色，**未知音色名会被静默替换成默认英文音色**（实测得到一个 17.36s 的英文念字符音频，
  `-l zh` 转写成 "Hum, 封, 含言, 含你, 含你。"）。先查音色再生成夹具。
- `afinfo` 报 `Fail: AudioFileOpenURL failed` → mpegts 等容器它不支持（实测 mpegts），
  这是通道缺失，不是文件损坏；只用 ffprobe 即可。
- afinfo 与 ffprobe 时长差几十毫秒 → mp3 的编码器 delay/padding（实测 2.038 vs 2.000），
  不是坏文件，但拼接/对字幕时要用 ffprobe 的流时长。
- `channel_layout` 为 `null` 却要判断单声道 → 看 `channels`。
- flac 报 `bits_per_sample: 0` → 真实位深在 `bits_per_raw_sample`。
- 全静音文件报 `I: -70.0 LUFS`、`Peak: -inf` → 前者是地板，后者是 `null`，不是测量失败。
- flat factor 为正就判削波 → 实测 −20 dB 正弦 6.021、3 声道 96k −37.068，会误报。
- 用 `for-tests-ggml-tiny.bin` 做冒烟测试 → exit 0 + 空转写 + `language: "af"`；
  脚本按名字拒绝，别绕过。
- 语言自动检测在非语音上会自信地错：17s 哼唱被判 `en`，for-tests 模型报 `af`。
- 视频文件的容器时长比音轨长 → 用 `audio_streams[].duration_s`，不要用 `format.duration`。
- 8 kHz 源不会立刻让转写崩：实测同一句干净 TTS 语音在 8 kHz 与 16 kHz 下文本一致，
  但它只剩 4 kHz 以下频段，噪声/多人场景不能外推 —— `probe.sh` 仍会报 `low_sample_rate`。
- 长文件没有进度输出（`-np` 抑制了 whisper 的进度），等它跑完；不要让上层超时误杀。

## 脚本与依赖

- `references/probe.sh`：ffprobe + python3（macOS 上再叠加 afinfo）。
- `references/loudness.sh`：ffmpeg（ebur128/silencedetect/volumedetect/astats）+ ffprobe + python3。
- `references/transcribe.sh`：ffmpeg + whisper-cli + python3；模型需一次性下载（本机
  `~/.cache/whisper.cpp/` 已有 tiny 74 MB、base 141 MB）。
- `references/selftest.sh`：用 ffmpeg lavfi 造夹具（正弦、静音空隙、−20 dB、削波、
  纯静音、录屏式 mov），断言字段值；`say` 与真实模型存在时才跑转写断言，
  libx264 缺失时跳过视频夹具。**不需要网络**。改脚本后先跑它。
