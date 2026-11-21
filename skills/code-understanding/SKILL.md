---
name: code-understanding
description: Use when you must understand an unfamiliar repository or answer what/where/why about code — onboarding, locating an implementation, change-impact, hotspots, dead code — before editing. Covers inventory (languages, entry points, generated areas, churn), definition outlines via ast-grep's bundled parsers, and the handoff to LSP for references/implementations. Separates measured facts from grep guesses.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# 代码理解

代码理解 = 先建立可复述的结构事实，再读代码，最后才敢说"这里就是这样"。
顺序固定：**清点 → 定义 → 引用 → 运行时**。跳步就会把"看起来像"当成结论。

四条证据通道，强弱递减：

1. **清单**（`repo-map.sh`）：语言配比、入口、生成的/第三方代码、热点文件。
   十进制秒级，价格为零，先跑。
2. **定义**（`symbols.sh` / ast-grep）：语法级 outline，能区分"定义"与"调用"。
3. **引用**（LSP）：`references` / `implementation` / `typeDefinition`。
   这是唯一能给"谁调用了我"背书的通道；grep 只能给候选。
4. **运行时**：测试、启动、复现脚本。行为问题只有它能定论。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能答到什么程度）

```bash
references/repo-map.sh . --json   # 非 ASCII 文件名用 core.quotepath=false 读取 | head -40
```

- 不是 git 仓库 → `git: null`，没有 churn/hotspot，明说。
- 主语言不在 ast-grep 内置解析器里（py/ts/tsx/js/go/rs/java 之外）→
  outline 拿不到，只能 grep，结论必须标"文本匹配，未做语法确认"。
- 生成代码占比高（`generated_suspects`、`vendored_dirs`）→ 先排除再读，
  否则热点会被 `.lock`/`.min.js` 污染。
- 仓库超大（>50k files）→ 先限定子目录，别全仓 outline。

## 清点：`repo-map.sh`

```bash
cd <本技能目录>                    # 例：~/.claude/skills/code-understanding
references/repo-map.sh .                 # 人类可读
references/repo-map.sh . --json          # 字段固定，可进脚本
references/repo-map.sh . --churn 500     # 换热点窗口
```

字段口径：

- `extensions[].lines`：非二进制文件的 `wc -l` 汇总。是行数，不是复杂度。
- `churn[]`：最近 N 个 commit 里每个文件出现的次数。合并提交、大范围格式化
  会放大它 —— 热点只说明"改得多"，不说明"重要"。
- `largest[]`：行数最多的文件。大文件常是生成代码或上帝类，先看 `ext`。
- `entry_points`：文件名/位置启发式（`main.py`、`main.go`、`package.json`、
  `src/main.rs`…）。**启发式，不是解析结果**；monorepo 会漏，多入口会少报。
- `test_files`：路径/命名启发式（`tests/`、`*_test.*`、`*.spec.*`）。
  命名不规范的测试不计入 → 用它估覆盖率一定偏低。
- `generated_suspects`：`*.min.js`、`*_pb2.py`、`*.lock` 等。命中不等于全是
  生成物，但先默认跳过再逐个确认。

## 定义：`symbols.sh`

```bash
references/symbols.sh src/               # TSV: file<TAB>line<TAB>kind<TAB>first line
references/symbols.sh src/ --json        # {symbols_total, by_kind, skipped_files, symbols}
references/symbols.sh lib.py --lang python
```

- 用 ast-grep 自带的 tree-sitter 解析器，**不需要下载/编译 grammar**。
  这是相对 `tree-sitter-cli`（要 `--grammar-path` + 编译）和
  universal-ctags（本机缺失）的关键取舍：可离线、开箱即用。
- kind 名是各语言 grammar 的原生节点名，已实测：python `function_definition`
  /`class_definition`；ts `function_declaration`/`class_declaration`/
  `interface_declaration`/`method_definition`；go `function_declaration`/
  `method_declaration`/`type_declaration`；rust `function_item`/`struct_item`/
  `impl_item`；java `method_declaration`/`class_declaration`。
- Python 的方法也是 `function_definition`（嵌在 class 里），不要据此说
  "这是顶层函数"。
- 输出的是**节点首行**，不是签名解析。不要把截断文本当完整签名引用。
- `skipped_files` 明确列出跳过的文件：没有解析器的扩展名、`--lang` 不匹配的语言，
  以及不是合法 UTF-8 的源码（ast-grep 会失败，这些文件会先被筛出）；脚本绝不静默丢文件。
- 结构查询用 ast-grep 直接写，比 grep 可靠：

```bash
ast-grep run --pattern 'subprocess.$M($$$A)' --lang python src/
ast-grep run --kind function_declaration --lang go .
```

## 引用与语义：LSP（不是 grep）

有 LSP 时（`lsp` 工具或语言服务器）必须用它：

- "谁调用了这个函数" → `references`；grep 命中的注释、字符串、同名局部变量
  都是假阳性。
- "实现是什么" → `implementation` / `typeDefinition`。
- "改这个签名会炸哪里" → `references` 收全量，再按调用点读。

没有 LSP 时的降级：grep/`tgrep` 找候选 → 逐个打开确认 → 结论标
"文本匹配（近似），未经符号解析"。**不能**把 grep 结果说成调用图。

动态语言（Python/Ruby/JS）里字符串反射、`getattr`、DI 容器、装饰器注册都不在
静态图里；这类问题直接走运行时（打日志、跑测试），不要靠读代码推断。

## 运行时

只有当问题涉及"实际行为"时才值得跑：单测、启动命令、最小复现脚本。
读代码得不到的证据（时序、并发、真实配置、网络）必须跑。

跑之前先确认不会改状态：迁移、`git clean`、外部写操作一律先问。

---

## Playbooks

每条结论都带来源：文件:行、命令输出、LSP 结果。无来源的判断写"推断"。

1. **新仓库上手**：`repo-map` 全文 → 读 `entry_points` 与 `manifests` →
   `symbols.sh` 出主目录 outline → 只对热点文件（`churn`）细读。
   输出：一句话定位 + 3–5 个关键文件 + 数据流。
2. **"X 在哪实现"**：`symbols.sh` 找同名定义 → 无命中再 ast-grep pattern →
   仍无则 grep（标近似）→ 命中后读函数与其直接依赖。只报定义位置与
   调用点，不整段复述文件。
3. **改动影响面**：LSP `references` 收全量 → 按"签名变化/行为变化"分组 →
   列出未覆盖的调用方式（反射、字符串、模板、配置）。动态入口单独列出
   并标"静态不可见"。
4. **热点定位**：`--churn` 取 top 10 → 与 `largest` 求交 →
   这些是"改得多又大"的文件，通常是隐患；只陈述事实，不臆测原因。
5. **死代码候选**：无 `references` 的定义 → 排除入口/装饰器注册/导出表/
   测试用例 → 剩下的标"疑似未使用"，并说明排除了什么。
6. **测试覆盖感知**：`test_files` 与源码目录的对应关系 → 无测试的目录列表。
   这是结构性缺口，不是覆盖率数字；要数字就跑覆盖率工具。

## Grounding 规则

- 行数是规模代理，不是复杂度；`churn` 是变更频率，不是重要性。
- 启发式（entry_points、test_files）要标启发式。
- "没人调用"需要 LSP 全量 references + 排除反射；grep 无命中只能叫"未找到"。
- 生成的/第三方代码不计入结论，除非明确在读它们。
- 读过的范围要写出来；没读的目录不评价。
- 脚本给的事实可以被引用；你对代码意图的解释必须标注为解释。

## 失败模式

- `repo-map` 在 monorepo 根目录只看到杂项 → 进到子包再跑一次。
- `git: null` 但目录里有 `.git` → 在子目录运行，git 只在仓库根生效。
- `symbols.sh` 输出 0 条 → 语言不在支持列表，看 `skipped_files`，换 grep。
- kind 名报 `Cannot parse kind as a valid selector` → 该语言没有这个节点名，
  到 `ast-grep run --kind <k> --lang <l> --debug-query=ast` 确认实际节点名。
- 行数巨大（单个文件 10k+）→ 先 `symbols.sh` 出 outline 再定位，别整文件读。
- churn 被格式化提交刷满 → 用 `--churn` 缩小窗口或 `git log --no-merges`。
- 把 `method_definition` 命中当顶层函数 → ts/java 的方法在 class 内，
  看所在行上下文。
- LSP 不可用 → 不要伪造 references；降级到 grep 并明确标注。

## 脚本与依赖

- `references/repo-map.sh`：git / find / awk / python3（仅用于 JSON 组装）。
- `references/symbols.sh`：ast-grep ≥0.50（内置解析器）+ jq。
- `references/selftest.sh`：造夹具仓库，断言清点字段与符号计数。
  改脚本后先跑它。
