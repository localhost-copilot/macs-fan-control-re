# 机型兼容性

需要 macOS 13+。应用按实际 SMC 键选择控制协议，不按芯片名称限制调速；传感器可读取不代表风扇写入已通过实机验证。

| 硬件 | 验证状态 |
| --- | --- |
| M4 Mac mini（`Mac16,10`），macOS 27.0.1 | 已实测读取；用户确认修复后的调速可用。使用 `F0Md`，没有 `Ftst`。睡眠、崩溃恢复仍待专项实测。 |
| 其他 Apple Silicon 有风扇机型 | 已实现传感器目录、动态发现和按能力选择的控制路径；模拟测试通过，具体机型仍需实测。 |
| Intel Mac | 已实现 `F{i}Md` / `FS! ` 和 `fpe2` 转速编码；模拟测试通过，硬件调速仍需实测。 |
| 无风扇机型 | 仅监控，无调速功能。 |

## Mac18,5（M6）/ macOS 27.0.1 功耗与温度实测

功耗读数是 macOS 的能量计数器差分，不是功率计测量；powermetrics 自己也注明为估算值。下面的对照只证明单位、归属和变化趋势正确，不保证与墙插功率完全相等。

| 负载（各约 20 秒） | CPU 功耗（CLPC） | GPU 功耗 | SMC `PMVC` 增量 | SMC `PDTR` 增量 |
| --- | --- | --- | --- | --- |
| 空闲基线 | 0.28 W | 0.14 W | 0 | 0 |
| 6 个 E 核后台线程 | +0.6 W | 0 | +0.6 W | +0.7 W |
| 1 线程 | +7.5 W | 0 | +8.4 W | +10.4 W |
| 4 线程 | +14.6 W | 0 | +15.3 W | +19.5 W |
| 12 线程 | +8.1 W | 0 | +10.1 W | +12.9 W |
| 仅 GPU（Metal） | +0.4 W | +10.8 W | +10.4 W | +13.1 W |

- CLPC GPU 与 Energy Model GPU 是两条独立报告，在 10.8 W 时相差 < 0.5%，可确认 CLPC 报告 ID 与 nJ 单位。
- 未标注用途的 SMC 电源轨增量与 CPU+GPU 增量同步变化（`PMVC` 比值约 0.94–1.25），差值来自内存、互连和供电损耗。12 线程低于 4 线程时，SMC 电源轨也同步下降。
- 温度：仅 P/M 核负载时 `Tp*` 最高升高约 32 °C；仅 E 核后台负载时只有 `Te*` 上升；仅 GPU 负载时 `Tg*` 升幅最大。据此在数据库中把这三族分别登记为 CPU 性能集群、CPU 能效集群和 GPU，不再标记 inferred。单个传感器对应哪个核心仍未知。
- 本机 `sudo powermetrics` 的 CPU 路径只读 Energy Model 集群通道或 `PMP / Energy Counters`，两者本机都不存在。GPU 与本应用读的是同一个计数器。

## 验证与排查

`swift run FanControl --probe-json` 只读取机型、风扇和传感器，不安装辅助程序或写入转速。完整测试使用 `swift test`，安装包资源检查使用 `bash scripts/check-packaged-app.sh`。

真实调速需要运行打包后的 app 并授权辅助程序；重新构建后需要更新辅助程序。不要同时使用多个调速工具控制同一风扇。

模式与目标转速写入后均读回确认；读回延迟时会有限重试。只有存在 `Ftst` 的机器才尝试该解锁路径。最终失败会报告模式键或转速的请求值与读回值；恢复失败会保留记录并继续重试。

验证新机型时，应分别检查固定转速、温控、恢复自动、退出、睡眠和断连。模拟测试不能代替这些实机操作。缺失的 CPU/GPU 名称可能按 SMC 键族推断并标记 `inferred`，不代表官方核心身份或封装温度。

## 控制协议参考

- [MacsFan](https://github.com/matejrondzik/macsfan/blob/main/MacsFan.swift)：模式键、解锁与写入后的重试。
- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md)：SMC 协议与实机行为研究。
- [smcFanControl](https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.c)：Intel SMC 编码。

第三方传感器 XML 的来源声明见 [README](../README.md#disclaimer)。
