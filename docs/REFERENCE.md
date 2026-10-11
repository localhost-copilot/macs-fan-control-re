# 参考与实现取舍

## 实现说明与资源来源

`Sources/FanCore/Resources` 中的五份 XML 来自 CrystalIDEA 的 Macs Fan Control，记录传感器名称、机型别名和风扇位置。这些是第三方数据，不主张其为本项目原创，也不授予其再分发许可。Swift 源码为本项目独立实现。

AppleSMC 请求使用显式 80 字节缓冲区：key +0、size +28、type +32、result +40、command +42、index +44、payload +48。通过固定偏移读写字段，确保传给 IOKit 的数据符合接口要求的内存布局。

硬件控制提供系统自动、固定转速和基于传感器的三种模式。团队签名的 XPC 使用 SMAppService；本地 ad-hoc 构建通过管理员授权安装 root 副本、LaunchDaemon 和双向 cdhash 约束。两者均使用本项目的独立 Mach service。

API 参考：

- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple NSXPCConnection.setCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple IOHIDEventSystemClientCopyServices](https://developer.apple.com/documentation/iokit/2269511-iohideventsystemclientcopyservic)
- [Chromium 的 HID 温度接口声明](https://chromium.googlesource.com/chromium/src/+/refs/tags/123.0.6285.0/components/power_metrics/m1_sensors_mac.mm)：用来核对 IOKit 私有入口的 C 调用签名和事件编号；本项目通过运行时动态解析这些入口，缺失时只使用 SMC。

私有 SMC/HID 接口不是稳定的 macOS SDK 合约，因此应在目标机型上验证读取、授权和恢复行为后再分发。

## 电气遥测与 M6 模式键

- [Stats 传感器读取实现](https://github.com/exelban/stats/blob/master/Modules/Sensors/readers.swift)与 [C 接口声明](https://github.com/exelban/stats/blob/master/Modules/Sensors/bridge.h)：用于核对 HID usage page/usage、事件类型与 IOReport 调用签名。本项目独立实现动态解析和 Energy Model 全通道采样，不复制其固定 CPU/GPU 等聚合逻辑。
- 本机只读验证发现 PMU 同名设备拥有相同 IORegistry 路径、不同 LocationID，后者四字节对应 SMC 键。部分电气事件把 float 位模式当作定点数返回；因此使用明确对应的 SMC 键解码，JSON 保留 rawValue 和 backingSMCKey。无法确认的通道不猜测单位转换。
- [同机型风扇控制记录](https://github.com/HDZucht/Mac-mini-M6-fan-control-LLM)描述小写 `F0md` 模式键；本机只读检查确认存在。写入优先小写，再检查旧式键；写入失败不会尝试其他模式键绕过错误。

## Mac18,5 的 CPU/GPU 显示补充

本机实测能读取 `Tp*`、`Te*`、`Tg*` 温度。[同机型的开源实测记录](https://github.com/HDZucht/Mac-mini-M6-fan-control-LLM#sensors-on-the-mac-mini-m6)也把这些键分别推断为 CPU 和 GPU。只在 Mac18,5 启用这一分组，名称明确附带 `inferred`；不声称具体性能核/能效核编号，不把该组平均值当作官方封装温度。`TCMb` 的含义在资料之间存在分歧，保留原始未知键，未将它指定为 CPU 温度。没有采用该外部项目的硬件写入或服务安装代码。
