# 机型兼容性与验证边界

项目没有 M6 白名单。原有 XML 已包含 Intel 和 M1–M5 机型资料；此前 README 重点介绍 M6，是因为本地实测环境是 Mac mini M6。以下「已实现」指软件路径存在，不等于每台机器均通过实机验证。最低系统版本仍为 macOS 13。

| 硬件 | 监控路径 | 调速路径 | 本项目验证状态 |
| --- | --- | --- | --- |
| M1 / M2 有风扇机型 | SMC + 可用的 HID、IOReport；基础款 M1 缺少 SMC 命名时补充推断分组 | 探测每个风扇的模式键，float 目标转速 | 模拟设备测试；待实机验证 |
| M3 / M4 有风扇机型 | 既有机型别名与传感器映射 | 直接模式写入；遇到 `0x82` 或模式写入未生效时探测 `Ftst` 解锁 | 模拟拒绝、延迟解锁、双风扇及恢复测试；待实机验证 |
| M5 / M6 有风扇机型 | 既有映射或发现的推断分组 | 小写 `F{i}md` 优先，也支持大写 `Md` | M6 `Mac18,5` 读取与 GUI 已实测；真实调速待验证 |
| Intel Mac | Intel SMC 数据库及实际可用通道 | `F{i}Md` 或 `FS! `；支持 `fpe2` 目标转速 | 模拟旧式位掩码、双字节编码；待 Intel 实机验证 |
| 无风扇机型，如 Apple Silicon MacBook Air | 监控系统公开的传感器 | 无可控制风扇 | 零风扇返回与 UI 空态已实现；待实机验证 |

## 本次补齐

- 按 `hw.optional.arm64` 识别本机是否为 Apple Silicon，Rosetta 下同样有效；未知机型族（如 `VirtualMac`）不会退回 Intel 数据库。为其他机型构建目录时按机型身份判断，测试据此在同一进程中读取 Intel 与多代 Apple Silicon 目录。
- 当 Apple Silicon 缺少某类 SMC 映射时，按已发现的 `Tp*` / `Te*`（CPU）、`Tg*`（GPU）建立带 `inferred` 的组。已有映射优先，Intel 不启用该推断。`Tf*`、`Tm*` 在不同芯片上含义不一致，不作通用猜测。
- 将模式值 1 识别为手动，模式 3 识别为系统控制，防止控制会话把系统接管误认为目标仍由应用维持。恢复自动时写入 0 后回读为 3 也视为成功。
- 固件以 `0x82` 拒绝手动模式，或写入成功但读回仍不是手动模式时，探测单字节 `Ftst`，每 100 ms 重试，最多 20 次。缺少解锁键、其他写入错误、读回错误或超时均报告失败；不会换模式键继续尝试。模式未生效的报错包含模式键、请求值和实际读回值。
- 只释放本连接取得的全局解锁；双风扇逐个恢复时保留解锁至最后一个释放。无法恢复时保留状态供控制会话重试。发现其他手动风扇时不取得新的全局解锁；不要同时运行多个调速工具。
- 回读模式和目标 RPM，固件静默忽略写入也会报错并恢复；目标值允许 ±1 RPM 的取整误差，控制会话按同一容差判断是否需要重写。Intel 位掩码更新保留其他风扇位。
- helper 在取得风扇或 `Ftst` 之前，先把所有权写入 `/var/run/local.macsfancontrol.swift.helper.json`；写入失败则不取得。helper 崩溃或被强制结束后，launchd 重启它时会恢复记录中的风扇为自动，并仅在 `Ftst` 仍为 1 时释放解锁。`/var/run` 在开机时清空，与 SMC 复位一致。

## 如何验证新机型

先运行 `swift run FanControl --probe-json`，记录真实机型、风扇范围、模式键、温度有效性。该命令只读取，不安装 helper、不写转速。无风扇机型应返回空风扇列表，仍可显示传感器。

真实调速需在目标机器启用签名 helper 后单独验证：硬件范围内的固定转速、双风扇独立控制、温控输入失效、恢复自动、退出、睡眠与断连。模拟设备测试不证明这些操作在所有固件上有效。部分固件缺少 `Ftst` 或拒绝冷机启动风扇，软件会报告错误。

## 开源参考

- [Stats 的传感器表](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)：核对 M1–M4 温度键，确认不同代际的键和核心含义存在差异。
- [MacsFan 的 SMC 控制实现](https://github.com/matejrondzik/macsfan/blob/main/MacsFan.swift)：核对 `Md` / `md`、`Ftst` 与读回确认流程。
- [MacFanControl 的兼容记录](https://github.com/raminsharifi/MacFanControl#compatibility)：交叉核对 M3 Pro 的模式 3、解锁及其他型号的验证边界。
- [smcFanControl 的 SMC 实现](https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.c)：核对 Intel 的 SMC 协议与编码。

新增代码为本项目独立实现，没有引入上游源码或依赖；原有第三方 XML 的来源说明仍见 [REFERENCE.md](REFERENCE.md)。
