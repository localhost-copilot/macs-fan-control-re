# 验证记录

## 安装包资源修复与 DMG（2026-10-11）

- v1.0.0 的主应用崩溃报告指向 `Bundle.module` 的资源查找失败；管理员授权已完成，LaunchDaemon 仍在运行。CI 编译产物中的 SwiftPM 资源访问器包含构建机路径，未找到 app 内的资源包。
- app 与 helper 现在从各自可执行文件旁的 `Contents/Resources` 加载传感器目录。打包检查将 app 复制到临时目录并隐藏 `.build`，分别运行两个可执行文件的 `--check-resources`，不需要管理员权限或硬件写入。
- 本地 22 项测试通过；打包 app 的只读探测在 Mac mini M6（`Mac18,5`）上读取 1 个风扇和 428 个传感器通道。
- DMG 采用背景图片、应用图标和 Applications 链接的拖拽布局；已检查图片、Finder 布局元数据及磁盘映像校验和。
- 此轮未执行真实风扇转速写入，未验证升级后的完整管理员授权及 XPC 控制链路。

## M6 全通道与风扇接入补充（2026-10-10）

- `swift test`：21 项 XCTest 通过（16 项 FanCore、5 项应用/安装器），0 失败。新增电气定点解码、温控类型隔离、功耗首次采样/重置/睡眠间隔、同名 PMU 身份、单位显示与 shell 路径转义检查。
- 安装器测试实际签名临时 Mach-O：当前 ad-hoc cdhash 通过安装命令校验，重新签名后的替换构建被拒绝。另用 `SigningIdentity` 和 `codesign -R '=cdhash …'` 验证打包 app/helper 的双向绑定条件。此检查不需要 root，不等于管理员安装/XPC 联通测试。
- Release 构建和签名验证通过；已启动真实监控 GUI，检查电压分类、V 单位与可读计数。截图：`screenshots/m6-voltage.png`。
- 打包程序 `--probe-json` 检测到 1 个风扇：最低 1000、最高 4900、当前/目标约 1000 RPM，模式键 `F0md`，自动模式。
- `--probe-json` 检测到 **428 个通道条目、399 个有效值、0 个重复 ID**。静态快照见 `m6-sensor-inventory.json`，其中读数随时间变化；这些是接口通道，不是独立物理传感器数量。

| 通道 | 总数 | 本次有效 |
| --- | ---: | ---: |
| SMC 温度 | 148 | 126 |
| SMC 电压 | 37 | 36 |
| SMC 电流 | 44 | 44 |
| SMC 功耗 | 59 | 59 |
| HID 温度 | 43 | 43 |
| HID 电压（含 SMC 对应键读取） | 46 | 43 |
| HID 电流（含 SMC 对应键读取） | 42 | 39 |
| IOReport 功耗 | 6 | 6 |
| 计算平均温度 | 3 | 3 |

确认了两个具体驱动行为：同名 PMU 设备的 IORegistry 路径也相同，必须加入 LocationID；部分电气 HID 事件读数约 16000，而对应 SMC 浮点键返回合理电压/电流。现优先读取已明确对应的 SMC 键，保存 HID 原始数值作诊断。

本轮未执行管理员安装或真实调速。辅助程序在 SIGTERM、断连、传感器失效和超时后恢复自动模式的代码已接入；真实硬件上的安装、模式切换和恢复仍未实测。以下为之前各阶段的验证历史。

CPU/GPU 显示补充验证：15 项测试通过，Release 重新打包成功。本机只读采样显示 CPU 传感器组平均 40.7°C、GPU 组平均 40.3°C、SSD 37.0°C。前两组按键族推断，UI 明确带 `inferred`；具体核心身份未验证。测试还覆盖重复发现不重复计入平均值、保留已有映射、排除含义不明确的键和限制为目标机型。

验证环境：macOS 27.0，Apple Silicon `Mac18,5`，Apple Swift 6.4。验证时间：2026-10-10。

## 自动检查

- `swift test`：14 项 XCTest 通过，0 失败。包括 12 项硬件数据/控制会话测试和 2 项应用预设持久化测试。
- `bash scripts/build-app.sh`：Release 编译、独立 helper 打包、资源 bundle、原创应用图标、ad-hoc 签名成功。
- `codesign --verify --deep --strict`：打包脚本完成签名验证。
- 两份 Packaging plist 通过 `plutil -lint`。
- `git diff --check`：无空白错误。

## 实机只读检查

`swift run FanControl --probe` 成功打开 AppleSMC。检测到一个风扇，硬件范围 1000–4900 RPM，采样时约 1000 RPM。读取到多组 SMC 温度和 IOKit HID 温度，包括 Airport Proximity、Power Supply Proximity、Power Manager Die Average、SSD。温度是实时采样，数值随负载变化。

## 实际 GUI 检查

在已打包的 `.app --demo` 中通过 macOS Accessibility 操作并查看窗口：

- 主窗口显示两组模拟风扇与实时变化的模拟温度。
- 打开 Custom，输入 2400 RPM 并确认，主列表显示 2400 及 Constant value of 2400。
- Full blast 使两个模拟风扇显示 5800 RPM。
- 传感器模式：90°C 起始、80°C 最高时禁用确认；改为 40°C 后恢复可提交状态；提交后显示 Based on Ambient。
- 预设保存进入下拉列表，退出并重新启动应用后仍存在，重新选择可应用；偏好设置和传感器页正常打开。
- 重启时不会自动应用手动模式。预设读写、重命名、删除及“读取偏好不覆盖预设”由 AppModelTests 额外覆盖。

截图见 `screenshots/`。这些界面检查不是完整的 UI 自动化测试套件。

## 未执行与边界

- `security find-identity -v -p codesigning` 返回 **0 个有效身份**。本次没有注册/批准 root helper，也没有写入任何真实风扇目标转速。
- 未验证 Developer ID / Apple Development 签名后的完整 XPC 授权链、真实调速、真实睡眠/崩溃恢复以及其他机型兼容性。
- 控制安全性测试使用可注入硬件替身，覆盖失效、超时、部分写入和恢复重试；它不能代替真实硬件验证。
- 独立 SMART 磁盘与 eGPU 通道等功能限制见 README。
