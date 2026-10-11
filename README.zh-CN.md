# Macs Fan Control

[English](README.md) | **简体中文**

原生 macOS 风扇控制与硬件监控工具。支持温度、电压、电流和功耗监控，通过独立的特权 helper 调节风扇转速，无需第三方依赖。

**面向 Apple Silicon 和 Intel Mac，按实际 SMC 能力选择控制协议。** 用户已确认 M4 Mac mini（`Mac16,10`，macOS 27）调速可用；其他机型与睡眠等恢复场景仍需实机验证。无风扇机型仅提供监控。详见[机型兼容性](docs/COMPATIBILITY.md)。

## 构建与启动

可在 [Releases](https://github.com/localhost-copilot/macs-fan-control-re/releases) 下载打包版本：Apple Silicon（包括 M6）选择 `arm64`，Intel 选择 `x86_64`。安装包采用 ad-hoc 签名，未公证；Intel 硬件兼容性尚未实测。也可按以下步骤从源码构建。

需要 macOS 13+、Xcode / Swift 5.9+。无需第三方 Swift 包。

使用 DMG 时，打开磁盘映像，将 **Macs Fan Control** 拖到 **Applications** 即可安装。也提供 ZIP 下载。

```sh
swift test
bash scripts/build-app.sh
open "dist/Macs Fan Control.app"
```

也可用 Xcode 打开 `Package.swift`。打包脚本生成可双击运行的 `.app`，默认使用本地 ad-hoc 签名。

```sh
# 完整交互演示：模拟两个风扇，不写入硬件
open -n "dist/Macs Fan Control.app" --args --demo

# 只读探测风扇、温度、电压、电流、功耗，随后退出
swift run FanControl --probe
# 完整清单含不可用状态、原始 HID 数值和对应 SMC 键
swift run FanControl --probe-json
```

## 已实现

- 可调整左右宽度的双列表主窗口；风扇最低/当前/最高 RPM、自动/自定义切换、双击和右键菜单。
- 固定 RPM 的滑块、数值输入；基于传感器的起始/最高温度、曲线预览、输入校验和取消语义。
- Automatic、Full blast、自定义预设保存/重命名/删除/应用，以及把单个风扇的更改保存到当前预设。上次成功应用的控制设置会自动保存，无需另存预设；重启或升级后，在硬件发现与校验通过后恢复。主动切回 Automatic 后，下次启动也保持自动控制；恢复失败会提示且不会反复尝试。
- 菜单栏：单色/彩色/无图标、风扇 RPM、指定传感器读数；数值使用固定宽度槽位，读数变化时不左右跳动。手动控制时彩色图标变橙，高温读数着色。预设切换、逐风扇控制、隐藏/重新打开与退出。
- 调速对话框实时生效：拖动滑块、切换到基于传感器或修改温度后立即作用于风扇，曲线实时显示当前工作点；取消恢复打开前的设置。
- 工具栏式偏好设置窗口（General、T° Sensors、Menu bar display），另有 Advanced 页管理 helper 与诊断；登录最小化启动、Dock 图标、摄氏/华氏、精确显示、传感器显示管理、中英文主要界面。
- SMC 自动枚举 `T*` / `V*` / `I*` / `P*` 通道，支持 float 和有效的 16 位有符号/无符号定点编码；保留未知键和不可用状态，每分钟重新发现。
- HID 温度、电压、电流；通过 LocationID 区分同名 PMU 通道，并用对应 SMC 键读取存在 HID 编码异常的电气通道。保留原始 HID 数值供诊断。
- IOReport Energy Model 的全部可发现通道：两次能耗采样换算瓦数，首次采样、计数重置或睡眠间隔显示等待；不把重叠功耗相加成系统总功耗。
- 温度/电压/电流/功耗分类、单位、来源、通道数和不可用原因。温控候选仅包含有效温度；电气读数不会进入温控计算。
- 独立 root XPC helper：双向验证代码签名、硬件范围与传感器；探测 `F{i}md`、`F{i}Md` 或 Intel 的 `FS! ` 位掩码，支持 float / `fpe2` 目标 RPM。模式 3 表示系统控制；手动模式写入被固件以 `0x82` 拒绝时探测 `Ftst` 解锁并限时重试。最后一个受控风扇恢复自动后释放本连接取得的解锁，失败可重试。模式与目标写入均回读确认。
- 传感器失效、写入失败、客户端断线和心跳超时恢复系统控制；失败的恢复操作继续重试。退出和睡眠主动释放本应用控制的风扇。
- 本地 ZIP 诊断导出，不上传、不采集磁盘序列号；明确标识的模拟模式。

## 启用真实调速

读取无需管理员权限。运行打包后的 app 时会自动安装 helper（启动时，或首次调整风扇时），macOS 请求一次管理员授权。状态与移除见 **Preferences → Advanced**。

默认 ad-hoc 本地构建会弹出 macOS 管理员授权，安装 root 拥有的独立 app 副本与 LaunchDaemon。先复制到 root 临时目录，再验证 app/helper 的确切代码签名哈希，最后注册服务；XPC 双向绑定当前构建。无需付费开发者证书。重新构建后需要再次启用以更新绑定。安装位置：

- `/Library/PrivilegedHelperTools/local.macsfancontrol.swift.helper.app`
- `/Library/LaunchDaemons/local.macsfancontrol.swift.helper.plist`

使用 Apple 团队签名的构建则保留 SMAppService 安装方式：

```sh
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' bash scripts/build-app.sh
# Apple Development 身份也可用于开发测试。
```

把团队签名的 app 放到稳定位置（例如 `/Applications/Macs Fan Control.app`），启用后在系统设置的登录项/后台项目批准。主应用和 helper 必须由同一个 Team ID 签名。辅助程序只接受本项目 app identifier；客户端也验证 helper 身份。切换安装方式前先使用旧版本的 Remove helper 移除服务。

通过 **Remove helper…** 先恢复自动控制再注销服务。不要与其他调速工具同时设置同一个风扇。普通关闭窗口仅隐藏到菜单栏；退出会释放本应用的控制。

## 范围与已知限制

- 这是独立项目，与 CrystalIDEA 无关联。
- 控制器实现温度区间、方向迟滞、渐变和 31 秒刷新。
- SSD 温度来自系统 HID/NAND 通道；尚未实现独立的 SATA/NVMe SMART 插件、Thunderbolt 外接磁盘和独立 eGPU 温度通道。系统未提供的传感器不会伪造读数。
- 主列表默认只显示机型数据库命名的传感器和分组平均值；传感器菜单中的“显示全部原始通道”可列出全部发现的通道。未命名通道隐藏时每 10 次刷新才重新读取一次。缺少 SMC CPU/GPU 映射的 Apple Silicon（含基础款 M1、M6）补充分组平均值（名称带 `inferred`），保留已有机型映射。按 `Tp*` / `Te*` 与 `Tg*` 分组是推断，不代表官方封装温度或准确核心编号；仅聚合实际有效值。HID 与 SMC 可能指向同一物理传感器，通道数不等于物理传感器数。
- “全部”指系统当前公开且可枚举的通道，不能访问固件未公开的传感器。未确定物理位置的通道保留原始名称。本机 IOReport 公开 GPU 与 PCIe 能耗，未枚举到 CPU/ANE/DRAM 能耗，不伪造这些通道。
- 低温时部分 Apple Silicon 硬件可能不接受手动启动风扇；具体机型的专用模式键兼容性仍需实机验证。
- 主要界面提供英文和简体中文，硬件名称与底层错误可能保留英文。
- 未公证。M4 Mac mini 调速已获用户确认；Intel/其他 Apple Silicon 机型及睡眠后的真实硬件恢复仍需实测。

## 代码结构与验证

- `Sources/FanCore`：SMC ABI、HID 读取、机型数据库、控制器、控制会话和 XPC 协议。
- `Sources/FanControl`：
  - `AppModel` 状态与控制流程，`HardwareMonitor` 后台采样队列，`HelperClient` / `LocalHelperInstaller` helper 连接与安装。
  - `Application` 窗口、菜单与偏好设置窗口；`StatusItemRenderer` 绘制固定宽度的菜单栏项。
  - 视图：`MainView`、`FanControlSheet`、`CurvePreview`、`PreferencesView`、`Dialogs`（预设/关于）；`Theme` 为传感器图标与配色。
- `scripts/make-icon.swift`：以代码绘制应用图标。
- `Sources/FanHelper`：签名约束的 XPC 服务，串行执行硬件访问，每 1.5 秒更新。
- `Tests/FanCoreTests`：温度解码、输入边界、控制器限幅、过期回退、传感器失效、部分写入失败与恢复重试等真实行为测试。
- `docs/COMPATIBILITY.md`：机型验证状态、排查方法与控制协议参考。第三方资源来源声明见 [README](README.md#disclaimer)。

演示模式命令行启动使用独立的 UserDefaults 域 `local.macsfancontrol.swift.demo`。普通启动的设置域是 `local.macsfancontrol.swift`；主窗口的“Use real sensors”可从演示切回真实硬件。演示和真实硬件的控制设置分别保存，演示设置不会应用到真实风扇。旧版本未保存的 Custom 参数无法找回，升级到支持恢复的版本后需重新设置一次。
