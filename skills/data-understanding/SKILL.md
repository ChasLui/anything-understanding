---
name: data-understanding
description: Use when a task involves a data file — CSV/TSV, JSON/JSONL, Parquet, or SQLite — and you must inspect it, check data quality, or answer a question with SQL. Covers content-based kind detection, delimiter and encoding, row/column shape, per-column types and nulls, duplicates, mixed-type columns, Parquet layout and compression, SQLite schema, and read-only SQL over any of them.
metadata:
  version: "1.0.0"
  date: "2026-11-21"
---

# 数据理解（CSV / JSON / Parquet / SQLite）

数据理解 = 先把形状和质量量出来，再用 SQL 取数。
**先 probe 后查询**：不知道分隔符、行数口径、空值和混合类型就开始 sum，
得到的是"看起来合理"的错数。

两条证据通道：

- **形状与质量**：`probe.py` 按内容判定格式，出行列数、逐列类型/空值/样本基数、
  重复行、Parquet 布局、SQLite 表结构。
- **取数**：`sql.py` 只读 SQL（CSV/TSV/JSON/JSONL/Parquet 载入内存表 `data`；
  `.db` 以 `mode=ro` 原地查询）。

Excel（xlsx）不在本技能范围：那是 `doc-understanding` 的 `probe.py` / `extract.py`，
本技能的 `probe.py` 会直接提示委托。

下文命令都以本技能目录为 cwd，脚本路径写作 `references/...`。

---

## Gate（先判断能不能答）

```bash
cd <本技能目录>
references/probe.py orders.csv
```

| 问题 | 能答的通道 | 拿不到时的说法 |
|---|---|---|
| 到底是什么格式 | 内容 magic/首字节 | 空文件 → `empty`，明说 |
| 几行几列、什么分隔符 | 流式扫描 + Sniffer | 嗅探失败时假定 `,` 并记 notes |
| 哪些列有空值/混类型 | 前 50,000 行列扫描 | 超出写 notes，计数是下界 |
| 有没有重复行 | 逐行比对（前 200,000 行） | 超出时 notes 写明只查了前 N 行 |
| Parquet 怎么存的 | footer metadata | — |
| 库里有哪些表 | `sqlite_master` | 加密库打不开，明说 |
| 求和/分组 | `sql.py` | 混合类型会让聚合失真，先看 probe |

依赖：`python3` + pandas、pyarrow；`charset_normalizer`（编码探测，缺失时按 utf-8）。

## 形状与质量：`probe.py`

```bash
references/probe.py orders.csv
references/probe.py events.jsonl --json
references/probe.py part.parquet
references/probe.py app.db
```

口径（引用时带上限定语）：

- `kind` 由内容判定，不看后缀：`PAR1` → parquet、`SQLite format 3` → sqlite、
  zip 里 `xl/`/`word/` → 提示委托、`{`/`[` → json、制表符多于逗号 → tsv。
  实测：`.csv` 文件里是制表符，报 `tsv`；单列表 `.csv` 兜底按后缀报 `csv`；
  0 字节文件报 `empty` 并给 notes。
- CSV：`delimiter` 由 `csv.Sniffer` 在 64KB 样本上推断（实测 `;` 正确）；
  `encoding` 由 charset_normalizer 在 256KB 样本上判定（纯 ASCII 报 `ascii`）。
- 表头前的**空行与 `#` 开头行会被跳过**（很多导出带 banner）：notes 写
  `N leading blank/# line(s) skipped before the header`；`sql.py` 用同样的
  `skiprows` 载入，两边行数才一致。实测 golang `x86.csv`（banner + 6 列）：
  修复前按 1 列解析并报 2321 行不匹配，修复后 2308 行 × 6 列。
  代价：如果第一行数据本身以 `#` 开头，它会被当注释吃掉——这种文件显式说明。
- `rows` 是**数据行**，不含表头；`columns` 是表头列数。列数不符的行会被补齐计数，
  并在 notes 报 `N row(s) did not match the M-column header`。
- 逐列 `type`：`int` / `float` / `date` / `bool` / `str` / `null` / `mixed`。
  `int` 与 `float` 同列时归为 `float`（不是 mixed）；真正的混类型才标 `mixed`
  （实测 `10` 与 `n/a` 同列 → mixed）。`date` 只认 ISO 形状（`2026-01-02`）。
- `nulls` 是空单元格计数；`distinct_sample` 是前 5000 个唯一值的**样本**，
  不是精确基数。
- 列扫描上限 `PROFILE_ROWS = 50000` 行：超出的文件在 notes 写
  `per-column scan limited to the first 50000 rows`（实测 50,010 行触发）。
- 行数是整文件统计；重复行只在前 `DUP_SCAN_ROWS = 200000` 行内比对，
  超出时 notes 写 `duplicate check limited to the first 200000 rows`
  （1.5M 行 / 18 MB 实测 89 MB RSS，不再随文件线性增长）。
- `duplicate_rows`：整行单元格完全相同才计为重复。
- JSON：`shape` 为 `array` / `object` / `jsonl`，由内容判定；jsonl 的坏行会被计数
  并在 notes 报告（`N line(s) are not valid JSON`），其余行照常统计。
- Parquet：`rows` / `columns` / `row_groups` / `metadata bytes`，每列给
  physical type、logical type、compression（实测 ZSTD / SNAPPY）。
- SQLite：只读连接；`tables` 给行数、列名类型、索引数，`views` 单独计数；
  表超过 50 张时只描前 50 并注明。

## 取数：`sql.py`

```bash
references/sql.py orders.csv --query "select name, sum(score) from data group by 1"
references/sql.py events.jsonl --query "select x, count(*) from data group by 1"
references/sql.py part.parquet --query "select avg(a) from data"
references/sql.py app.db --query "select count(*) from users"
references/sql.py codes.csv --strings --query "select code from data"   # 保留前导零
```

- 只接受 `SELECT` / `WITH` / `EXPLAIN`；其余语句直接拒绝（exit 1）。
  `.db` 用百分号编码的 `file:` URI + `mode=ro` 打开（文件名含 `#`/`?` 也不会
  截断路径或掉只读参数），并加 SQLite authorizer：`WITH ... DELETE/UPDATE` 这类
  能绕过前缀检查的写法也会被拒绝（`not authorized`）。只读 pragma
  （`table_info`/`index_list` 等）仍可用，写类 pragma 拒绝。
- 文本编码由 `charset_normalizer` 探测（UTF-16 BOM 直接识别），Latin-1/UTF-16
  CSV 都能进 SQL；JSON 用 `utf-8-sig` 读，BOM 不再报错。
- 嵌套值（JSON dict/list、Parquet struct/list）在装载时序列化为 JSON 字符串，
  不会因 `to_sql` 绑定失败而崩。
- 非 SQLite 文件载入内存 SQLite 表 `data`；CSV 分隔符同样用 Sniffer 推断。
- 输出 TSV：首行是列名，`NULL` 打印为空串——**先看表头再读值**。
  `--json` 输出行对象数组。
- **前导零陷阱（实测）**：`007` 默认被 pandas 推断成整数，查询得 `7`；
  邮编、工号、编号列用 `--strings` 让 CSV/TSV 单元格按文本载入（实测 `007` 保留）。
  JSON 由结构决定类型，Parquet 由 schema 决定类型，`--strings` 对这两类不生效。
- 列名是 SQL 关键字（如 `when`、`order`）时要加双引号：`"when"`。

---

## Playbooks

输出都带来源：文件名、命令、字段。无法回溯的数值不写。

1. **数据摸底**：`probe.py --json` 出 kind / 行数 / 列数 / 分隔符 / 编码 / 逐列类型；
   报告顺序固定：格式 → 形状 → 逐列质量 → notes。
2. **质量闸门**：看 `nulls`、`mixed`、`duplicate_rows`、ragged 行；先报"这列是
   mixed，聚合前要清洗"，再谈任何 sum/avg。
3. **两表核对**：`sql.py app.db --query "select count(*) from a left join b ..."`，
   输出计数与样本行；只读连接保证不动库。
4. **Parquet 存储检查**：`row_groups`、每列 compression；行数大而 row group 少时
   说明写端攒了批，别据此推断读取性能。
5. **JSON 日志清点**：`probe.py --json` 看 shape/rows/keys 与坏行数；
   再 `sql.py` 按 key 聚合。
6. **编码/分隔符排错**：`probe.py` 的 `encoding`/`delimiter` 是推断值；
   与肉眼不一致时用 `--json` 记录，再换工具复核，不要静默采用。

## Grounding 规则

- 行数口径分开说：数据行（本工具）vs 含表头（有些工具）。
- `distinct_sample` 是样本，不是 `count(distinct ...)`；要精确基数就用 `sql.py` 查。
- 类型是**文本推断**：`007`、`1,000`、`N/A` 都会被归到 int/str 等类，
  推断结果不是 schema 声明。
- 编码与分隔符是推断值，失败会走默认（`,` / utf-8）并写 notes。
- NULL 在 TSV 输出里是空串，不能与"真正的空字符串"区分——需要区分就用 `--json`。
- 不给业务结论：`score: mixed` 说明"这列混了类型"，不说明"数据有错"。

## 失败模式

- 0 字节文件 → `kind=empty` + notes；不要当成空表继续查询。
- 超 50,000 行 → 逐列类型/空值/基数是前 50,000 行的结果；notes 里有说明。
- 混合类型列做 SQL 聚合 → pandas 推断可能把整列落成 object，`sum` 得到文本拼接或
  NULL；先看 `probe.py` 的 `type`。
- 前导零 / 长数字 ID → 默认丢精度或丢零；用 `--strings`。
- SQL 关键字列名 → 加双引号，否则 `syntax error`（实测 `when`）。
- 多字符分隔符 / 引号内换行 → `csv.Sniffer` 可能判错；用 `--json` 核对再手工指定。
- SQLite 加密（SQLCipher）→ 打不开，报错即事实，别猜内容。
- xlsx/docx → 本技能只提示委托，不半解析；用 `doc-understanding`。

## 脚本与依赖

- `references/probe.py`：stdlib + pandas/pyarrow（parquet）、charset_normalizer（可选）。
- `references/sql.py`：pandas（非 SQLite 输入）+ stdlib `sqlite3`。
- `references/selftest.sh`：造 CSV/TSV/JSON/JSONL/Parquet/SQLite/宽表夹具，断言
  分隔符、行列数、类型合并、mixed、重复行、扫描上限 notes、parquet 压缩、sqlite
  表与索引、空文件、单列表，以及 SQL 只读拒绝与前导零两种模式。改脚本后先跑它。
