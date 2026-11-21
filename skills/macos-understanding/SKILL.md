---
name: macos-understanding
description: Use when a task is about the Mac itself or an installed app — host specs and OS state, what is installed, an app's version/bundle id/category, why an app will not open (quarantine, signature, architecture, minimum OS), or whether an app is running. Covers the local read-only channels (sw_vers, sysctl, system_profiler, PlistBuddy, codesign, spctl, xattr, lsappinfo), what each verdict does and does not prove, and the privacy boundaries of reading a Mac.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# macOS 理解（主机事实 + 已装 App）

macOS 理解 = 用本机只读通道量"这台机器是什么、装了什么、为什么这个 App 打不开"。
**先量后说**：没有命令输出的"应该是最新版""可能是签名问题"都不能当结论。

三条证据通道：

- **主机**：`sw_vers`、`sysctl`、`df`、`pmset`、`csrutil`、`fdesetup` —— 系统自我报告的事实。
- **App 身份与来源**：`Contents/Info.plist`、`lipo`、`codesign`、`spctl`、`xattr` ——
  bundle 自己声明的元数据 + 代码签名/门禁的真实判定。
- **运行态**：`lsappinfo` —— 当前 GUI 会话里在跑什么（不是"装了什么"）。

三条通道都是只读的；本技能不调用 `sudo`，不写偏好设置，不读用户内容。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能不能答）

```bash
cd <本技能目录>
references/sysfacts.sh          # 主机规格与状态
references/appinfo.sh Safari    # 单个 App 的深挖
references/apps.sh --count      # 装了多少个 App
```

| 问题 | 能答的通道 | 拿不到时的说法 |
|---|---|---|
| 机器型号/芯片/内存/系统版本 | `sysfacts.sh` | — |
| 磁盘余量、电源、SIP、FileVault | `sysfacts.sh` | 字段为 null 即测不到，明说 |
| 某 App 装没装、什么版本 | `appinfo.sh` / `apps.sh` | 别用 Spotlight 的名称搜索代替 |
| 这个 App 从哪来、有没有公证 | `codesign` + `spctl` | `spctl` 只给本机策略判定 |
| 打不开是不是"已损坏" | quarantine + 签名 + 架构 + 最低系统 | 四项要分开报 |
| 现在有没有在跑 | `lsappinfo` | SSH 会话里看不到 GUI App |

依赖：macOS 自带工具（`sw_vers`、`sysctl`、`system_profiler`、`PlistBuddy`、`codesign`、
`spctl`、`xattr`、`lsappinfo`、`lipo`、`df`、`pmset`、`csrutil`、`fdesetup`）+ `python3`。
Linux 上没有这些命令，本技能不适用。

## 主机：`sysfacts.sh`

```bash
references/sysfacts.sh            # 人类可读
references/sysfacts.sh --json     # 机器可读，测不到的字段是 null
```

实测（本机，macOS 27.2.1）：

```text
os: macOS 27.2.1 (26B131)
kernel: 27.2.0  arch: arm64  model: MacBookPro18,4
chip: Apple M1 Max  cores: 10  memory: 64 GiB
disk: 1.8 TiB total, 808 GiB free on /
power: AC Power, battery 80%
sip: enabled  filevault: On
```

口径：

- 内存用 `hw.memsize`（字节），显示为 GiB（1024³）；`df` 的数值也按 GiB 报。
  系统"关于本机"里写 GB 的地方实际可能是 GiB，报告带单位并写清换算。
- `system_profiler SPHardwareDataType` 实测 0.29 s，可以用；**不要跑全量
  `system_profiler`**（几十秒级）。
- 电池只在笔记本上存在；台式机返回 null，不是错误。
- `csrutil status` / `fdesetup status` 不需要 `sudo`；输出是"开/关"的布尔事实，
  不展开讨论安全策略。
- uptime 从 `kern.boottime` 换算成秒，报告写"秒/时"。

## 单个 App：`appinfo.sh`

```bash
references/appinfo.sh /Applications/Safari.app
references/appinfo.sh Terminal                 # 按名字在标准目录里解析
references/appinfo.sh Summer --json
```

输出字段与来源：

- `bundle_id` / `version` / `build` / `min_os` / `category`：读
  `Contents/Info.plist`（PlistBuddy；`defaults read` 是回退）。版本口径写清是
  `CFBundleShortVersionString`（给人看的）还是 `CFBundleVersion`（构建号）。
- `category`：`LSApplicationCategoryType`（如
  `public.app-category.developer-tools`）。这是开发者声明的分类，不是 App Store 分类，
  未知时原样输出。
- `binary{executable, path, exists}`：`CFBundleExecutable` 解析出的主可执行文件。
  它必须是 `Contents/MacOS` 下的**纯文件名**：带 `/` 或 `..` 的值会被拒绝并记 note，
  不会让工具去读 bundle 之外的文件。
- `architectures`：`lipo -info` 的解析结果。`arm64e` 与 `arm64` 是不同架构，
  原生 Apple Silicon 起得来只需要 `arm64`/`arm64e` 至少一个。
- `signed` 与 `signing{identifier, authorities, team_id, flags, error}`：`codesign -dv --verbose=2`。
  **实测陷阱**：对一个 bundle 跑 `codesign -dv` 可能报的是其中主可执行文件的签名
  （我曾把 `/bin/echo` 拷进自制 `.app`，`codesign` 报 `Identifier=com.apple.echo`）。
  所以 `signing.identifier` 必须与 `bundle_id` 对照看，不一致就说明 bundle 没被整体签名。
- `gatekeeper`（字符串，`accepted`/`rejected`）+ `gatekeeper_detail{status, source,
  origin, exit_code, message, scope}`：`spctl -a -vv` 的解析结果。
  它给的是**本机策略判定**：`accepted` + `source=Notarized Developer ID` 才同时说明
  "签名有效且已公证"；`accepted` + `source=Apple System` 是系统自带。
  拒绝时原文照抄（`message`），不翻译成"已损坏"。
- `quarantine{attribute, present, raw}`：`xattr -p com.apple.quarantine`。有值说明文件
  带着下载标记；没有不代表安全，只代表"没有这个标记"。
- `running{running, pids}`：`lsappinfo list` 里 `bundleID="<id>"` 的精确匹配。
- `size_bytes` / `size_kib`：`du -sk` 的快速估算（只对 bundle 目录），不是 APFS 实际占用。
  bundle 是符号链接时，只有链接目标仍是带 `Contents/` 的 bundle 才测；否则 `null` + note，
  避免顺着链接遍历任意目录（Safari 就是指向 cryptex 的符号链接，仍能测到）。
- `resolved_path` / `plist_reader`：路径经符号链接解析后的真实位置，以及
  实际读到 Info.plist 的工具（`PlistBuddy` 或 `defaults`）。
- bundle 自带的字符串都按不可信处理：控制字符会被替换为空格，所以 Info.plist 里的
  换行 + `\x1f` 无法伪造一条记录，显示名也不会向终端注入转义序列。

## 装了什么：`apps.sh`

```bash
references/apps.sh                     # 表格：name / bundle id / version / category
references/apps.sh --count             # 只输出数量
references/apps.sh --filter summer     # 名字或 bundle id 子串
references/apps.sh --json              # 数组
```

实测（本机）：`/Applications` 67、`~/Applications` 3、`/System/Applications` 47、
`/System/Applications/Utilities` 18 —— 共 135 个 `.app` 条目，其中 1 个是 952 B 的
macOS alias 文件（`/Applications/豆包浏览器.app`，不是 bundle），可读 bundle 134 个。
脚本只统计真实 bundle，跳过的条目写 stderr；`--count` 与 `--json` 的长度一致。
逐 App 只读 Info.plist，**不**对每个 App 跑 `codesign`（太慢）。
目录之外的 App（Setapp、自定义 cask 路径、`/opt/homebrew/Caskroom` 里的原始包）
不在清单里——报告写"扫描了哪些目录"，别把"清单里没有"说成"没装"。

---

## Playbooks

输出都带来源：命令、字段、路径。无法回溯的数值不写。

1. **"这台机器什么配置"**：`sysfacts.sh --json`；报告顺序：系统 → 机型/芯片/内存 →
   磁盘 → 电源 → 安全状态。不评价"够不够用"。
2. **"装没装 / 什么版本"**：先 `apps.sh --filter <name>`；命中多个同名 App 时逐个
   `appinfo.sh <path>` 并报告路径差异（App Store 版与官网版常并存）。
3. **"为什么打不开/提示已损坏"**：按顺序查 quarantine → `spctl` 判定 →
   `codesign` 的 Authority/TeamIdentifier → `architectures` → `min_os` 与
   `sysfacts` 的系统版本。每项只报事实；"损坏"是系统文案，不是诊断结论。
4. **"是不是原生 Apple Silicon"**：`lipo -info`；只有 `x86_64` 说明要走 Rosetta。
5. **"这个 App 属于哪类"**：`LSApplicationCategoryType` + 名称/bundle id；
   声明缺失就写"未声明"，不按名字猜。
6. **"现在在跑什么"**：`lsappinfo list` 的 bundleID 集合；与 `apps.sh` 的安装清单
   分开报（装了 ≠ 在跑）。

## Grounding 规则

- 规格带单位与来源：`64 GiB（hw.memsize）`、`808 GiB 可用（df -k /）`。
- 签名/门禁只报命令输出：`accepted, source=Notarized Developer ID`，不转述成"安全"。
- `spctl accepted` 不等于"已公证"——看 `source=` 行；`codesign` 有 Authority 不等于
  bundle 完整。
- 版本号区分 `CFBundleShortVersionString` 与 `CFBundleVersion`，不混用。
- 装了什么（磁盘）与在跑什么（GUI 会话）是两件事，结论分开写。
- 不读用户内容：不碰 Messages/Mail/浏览器数据、不 `defaults read` 个人域、
  不看 TCC 保护目录；被拒绝就报"无权限"，不绕过。

## 失败模式

- `spctl` 对未公证的 Developer ID App 也可能 `accepted`（本机策略允许），
  必须带 `source=` 才能区分。
- `codesign -dv <bundle>` 可能给出主可执行文件的签名标识（实测 `com.apple.echo`
  出现在自制 bundle 上）——与 `bundle_id` 不一致就是没整体签名。
- 自制/损坏 bundle：`spctl` 可能报
  `code has no resources but signature indicates they must be present`；原文照抄。
- App Store 安装的 App 没有 quarantine 标记；"无标记"不能推断来源。
- `lsappinfo` 只反映当前用户的 GUI 会话；SSH/CI 里可能一个 App 都看不到。
- Info.plist 可能是二进制格式或本地化目录；PlistBuddy 能读二进制，`defaults read`
  需要完整路径。
- 全量 `system_profiler` 很慢（数十秒），只用 `SPHardwareDataType` 等具体类型。
- `/Applications` 之外的位置（Setapp、自定义 cask 路径）不在清单里，别把
  "清单里没有" 说成 "没装"。
- 恶意/损坏 bundle 可以在 Info.plist 里放任意字符串或 `..` 路径；工具会拒绝越界路径
  并清洗控制字符，报告里的字段值不能当成"应用自报身份已可信"——仍要看签名是否与
  `bundle_id` 一致。
- bundle 是指向非 bundle 目录的符号链接时，`size` 报 `null`；不要据此判断下载体积。
- 名字不是目录的 `.app`（macOS alias 文件、普通文件）按 broken bundle 处理：exit 0、
  `bundle_id: null`、note 说明；不要把它当成"App 已安装"。
- 脚本需要可写的 `TMPDIR`（`mktemp -d`）：`TMPDIR` 不可用时直接退出 1、stdout 为空。

## 脚本与依赖

- `references/sysfacts.sh`：`sw_vers`/`sysctl`/`df`/`pmset`/`csrutil`/`fdesetup`/
  `system_profiler SPHardwareDataType`；`--json`。
- `references/appinfo.sh`：PlistBuddy、lipo、codesign、spctl、xattr、lsappinfo、du；`--json`。
- `references/apps.sh`：扫描标准应用目录，只读 Info.plist；`--filter/--count/--json`。
- `references/selftest.sh`：断言主机字段与系统命令一致、Safari 的身份/签名/门禁、
  未签名夹具被 `spctl` 拒绝、清单数量与 JSON 长度一致；GUI 相关断言在无 GUI 会话时跳过。
