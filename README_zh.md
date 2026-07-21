# ibattery-mcp

[![CI](https://github.com/China-Drummond/ibattery-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/China-Drummond/ibattery-mcp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/China-Drummond/ibattery-mcp)](https://github.com/China-Drummond/ibattery-mcp/releases)

一个 [MCP](https://modelcontextprotocol.io)（Model Context Protocol）服务器，
把你的苹果设备——这台 Mac、附近的蓝牙外设、iPhone/iPad、Apple Watch——的电量和
充电状态，暴露成 AI 助手（Claude Code、Claude Desktop、[Work Buddy](https://docs.work-buddy.ai/)
或其他任何 MCP 客户端）可以调用的工具。

[English](./README.md)

## 当前状态

| 设备 | 状态 |
|---|---|
| 本机 Mac 电量 | ⚠️ 已实现、有单元测试 — 但还没有在真实硬件上验证过 |
| 通用蓝牙设备（标准 Battery Service，大部分蓝牙鼠标/键盘） | ⚠️ 已实现、有单元测试 — 真实蓝牙扫描已测试，但还未找到兼容外设确认过 |
| iPhone / iPad | ✅ USB/WiFi 同步已验证 · ✅ 锁屏时的蓝牙读取路径已在真实锁屏 iPhone 上验证 |
| Apple Watch（通过配对的 iPhone） | ✅ 已在真机上验证 |
| AirPods | ✅ 通过 BLE 广播实时获取电量、充电状态、盒盖状态和每只耳机的入盒状态（并以 `system_profiler` 作为兜底）— 已在真实 AirPods 4 上验证。已知限制：AirPods 4 合盖消息的状态字节取值在四个已知文档值之外，因此合盖期间入盒状态如实返回 `null`（开盖期间正常报告） |
| 局域网内其他 Mac | ❌ 不做了 —— 见下方[为什么不做局域网内其他 Mac？](#为什么不做局域网内其他-mac) |

本项目仍处于 1.0 之前的活跃开发阶段，详见 [CHANGELOG.md](./CHANGELOG.md)。

## 为什么蓝牙功能需要一个单独的辅助 App？

macOS 会把 CoreBluetooth 的隐私（TCC）检查归属到"负责的进程"身上，而不是实际
调用 API 的那个二进制文件。MCP server 本质上就是被宿主（Claude Code、Claude
Desktop 等）直接 fork 出来的子进程——从来不是通过 macOS 的 LaunchServices
（`open`）启动的。这意味着一个裸的 MCP server 永远没法成为自己的"负责进程"，
一碰蓝牙就会被系统杀掉。`ibattery-mcp` 用了跟普通 Mac App 一样的解决办法：一个
小的伴生 App，`ibattery-ble-helper`，专门持有所有蓝牙访问权限，用正常方式启动
（`open`，或设成登录项）；无状态的 MCP server 通过本地 Unix socket 跟它通信。
完整来龙去脉见[设计文档](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)。

除了按需扫描之外，辅助 App 还会在后台持续监听 BLE 广播（启动时监听 15 秒，
之后每 30 秒监听 5 秒）：AirPods 在使用中会以明文广播自己的电量、充电和入盒
状态，并在盒盖合上后不久停止广播——持续监听正是为了捕捉盒盖合上那条携带精确
入盒状态的消息。同一个监听器也能发现附近的 iOS 设备，从而在它们锁屏、无法通过
WiFi 同步访问时，依然能通过标准蓝牙 GATT 读取电量。

## 为什么不做局域网内其他 Mac？

跟 iPhone/iPad、Apple Watch、AirPods 不一样——那几个功能之所以能做，是因为
macOS/iOS 本来就已经在悄悄收集、同步这份数据了（lockdownd 的配对关系，或者
iCloud 密钥同步让这台 Mac 自己的蓝牙栈提前知道），本项目只是把已经存在的数据
读出来。但另一台 Mac 的电量没有这样一条现成通道——Find My 虽然能看到，但走的
是封闭的 iCloud 云端路径，没有任何本地或可脚本调用的接口。真要看到另一台 Mac
的状态，需要在**每一台**相关的 Mac 上都跑一个自建的点对点 App，大概率还会撞上
和蓝牙一样的局域网权限"责任进程"问题——意味着要再建一个常驻辅助 App、自己设计
发现和认证机制，而且没有任何官方通道可以借力。设计阶段权衡这个代价之后，主动
决定不做这个功能。完整推理过程见
[设计文档](./docs/superpowers/specs/2026-07-20-lan-multi-mac-design.md)。

## 安装

### 前置条件

- macOS 13 (Ventura) 或更新版本
- [Homebrew](https://brew.sh)

### 安装

```bash
brew install China-Drummond/tap/ibattery-mcp
```

这会同时安装 `libimobiledevice` 和 `pkg-config` 依赖（iPhone/iPad/Apple Watch
支持需要），并在你的机器上从源码构建 `ibattery-mcp`。

### 蓝牙设备支持的一次性设置

蓝牙设备（通用 BLE 外设）需要辅助 App 处于运行状态：

```bash
open "$(brew --prefix ibattery-mcp)/libexec/ibattery-ble-helper.app"
```

第一次启动会弹出蓝牙权限申请，点允许。之后辅助 App 会一直在后台运行，只需要
做一次（重启电脑后需要再开一次，除非你把它设成登录项）。

### iPhone/iPad/Apple Watch 支持的一次性设置

用数据线把 iPhone/iPad 连接到这台 Mac 一次，在弹出的提示上点"信任"。这样就
建立了 libimobiledevice 需要的配对关系；之后如果设备开启了 Wi-Fi 同步，也可以
无线连接。

## 配置

把 `ibattery-mcp` 加到你的 MCP 宿主配置里。比如，对于读取 `command`/`args`
形式 JSON 配置的宿主：

```json
{
  "mcpServers": {
    "ibattery-mcp": {
      "command": "ibattery-mcp"
    }
  }
}
```

## 可用工具

- **`get_all_devices_status()`** —— 一次性返回当前这台 Mac 能发现的所有设备的
  电量/状态。适合做"设备状态总览"（比如晨间简报）的主力工具。
- **`get_device_battery(query)`** —— 查询名字或类型匹配某个关键词的单个设备
  （比如 `"iPhone"`、`"MacBook"`）。
- **`list_known_devices()`** —— 列出本次会话里已经看到过的设备，不触发新的扫描。

## 参与贡献

开发环境搭建、跑测试、提交改动的流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 许可证

[MIT](./LICENSE)

## 致谢

- [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) ——
  本项目 MCP 协议层基于的官方 Swift SDK。
- [libimobiledevice](https://libimobiledevice.org) —— 本项目用于 iPhone/iPad
  和 Apple Watch 通信的开源库（作为外部依赖使用，未打包捆绑）。
- [AirBattery](https://github.com/lihaoyun6/AirBattery) —— 启发本项目的前驱
  工作。`ibattery-mcp` 是独立的、干净重写的实现（原因见[设计文档](./docs/superpowers/specs/2026-07-19-ibattery-mcp-design.md)），
  与它不共享任何代码。

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=China-Drummond/ibattery-mcp&type=Date)](https://star-history.com/#China-Drummond/ibattery-mcp&Date)
