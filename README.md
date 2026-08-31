# ABS — AskClaw VPS 跑分脚本

[English](README.en.md)

ABS 测试 Linux VPS 的 CPU、内存、磁盘和 fsync，并给出一个简单结论：**保留、谨慎保留、不建议保留或测试不完整**。

## 运行

```bash
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash
```

默认输出中文，通常在安装依赖后 3 分钟内完成。脚本可能安装 `sysbench`、`fio`、`python3` 和 `curl`。

```bash
# 不安装缺失工具
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- -n

# 英文输出
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --lang en
```

> `curl | bash` 会直接执行下载内容。需要先检查时：
>
> ```bash
> curl -fsSLo abs.sh https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh
> less abs.sh
> bash abs.sh
> ```

## 结果

```text
===================== ABS 结果 =====================
得分：完整，得分 1568（仅本地；网络参考分 136）
结论：谨慎保留 — 磁盘性能偏弱
本地：完整，得分 1568（仅本地；网络不计分）
网络：参考分 136（Cloudflare HTTP，仅供参考，不计分）
====================================================
```

- **保留**：本地性能整体良好
- **谨慎保留**：可以使用，但有明显短板
- **不建议保留**：本地性能较弱或存在严重瓶颈
- **测试不完整**：CPU、内存、磁盘或 fsync 测试缺失

`完整` 只表示核心测试全部完成，不表示机器一定很快。`不完整，不能比较` 不应与完整结果直接比较。

## 测试内容和评分

- **CPU**：单线程和全线程吞吐
- **内存**：顺序读取和写入
- **磁盘**：顺序读写、4K QD1 和压力测试
- **fsync**：4K 持久化写入
- **网络**：Cloudflare 简测，仅供参考

```text
40% CPU + 15% 内存 + 30% 4K QD1 磁盘 + 15% fsync
```

网络不计入总分。ABS 还检查最弱分项：分项低于 250 时“不建议保留”，低于 500 时最多“谨慎保留”。

比较机器时，应使用相同的 ABS 版本、测试模式、线程数、fio 大小和 `DIRECT` 设置。只有 `DIRECT=1` 的完整本地结果可直接比较。

## 常用命令

```bash
# 快速检查，约 60 秒
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --quick

# 完整测试，约 5–8 分钟
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --full

# 跳过网络；本地得分仍有效
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --no-network

# 保存 JSON
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --json-file result.json

# Cloudflare + 3 个公共 iperf3 区域
curl -fsSL https://raw.githubusercontent.com/getaskclaw/abs/main/abs.sh | bash -s -- --network-full
```

完整选项见：

```bash
bash abs.sh --help
```

## 语言和机器输出

- 终端默认中文；使用 `--lang en` 或 `ABS_LANG=en` 切换英文
- `results.tsv` 的指标名、`result.json` 的字段和值保持英文，便于程序读取
- 切换终端语言不会改变评分或机器输出格式

## 安装和网络

依赖安装失败时，ABS 会显示简短原因、修复提示和日志路径，然后继续生成不完整结果。ABS 不会自行运行 `dpkg --configure -a` 等系统修复命令。

默认网络简测：

- 从 Cloudflare 下载 10 MB
- 上传 5 MB 零数据
- 单次超时 45 秒
- 失败后重试一次

更完整的网络测试使用 `--network-full` 或 `--network-yabs`。

## 安全和文件

- ABS 不上传跑分结果
- 日志保存在私有随机目录 `/tmp/abs.*`
- 磁盘测试文件放在独立临时目录，结束后删除
- 原有 `abs.test*` 和 `abs-dd.test` 文件不会被删除
- `fio` 缺失时使用 `dd` 粗略检查，但不计分
- Alpine 最小系统需要先安装 Bash：`apk add bash`

中国网络无法访问 GitHub Raw 时：

```bash
curl --resolve cdn.jsdelivr.net:443:104.16.175.226 \
  -fsSL https://cdn.jsdelivr.net/gh/getaskclaw/abs@main/abs.sh | bash -s -- -n
```

## 开发测试

```bash
python3 -m unittest -v tests/test_abs.py
```

GitHub Actions 会在 push 和 pull request 时运行测试。

## License

MIT
