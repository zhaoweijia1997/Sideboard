<p align="center"><img src="docs/icon.png" width="128" alt="Sideboard 图标"></p>

# Sideboard

[English](README.md) · **简体中文**

在 Mac 上看看你的安卓设备都在干什么。Sideboard 通过 adb 连接安卓电视、盒子、手机和平板，
用 USB 线或家里的网络都行，把能读到的都显示出来：屏幕开没开、正在显示什么、正在播放什么、
开机多久了、CPU、内存、存储、网络、温度，以及最近 24 小时的亮屏、熄屏和使用记录。
它还能当遥控器、截屏、传文件、装 App。

设备上不需要安装任何东西。

<p align="center">
  <img src="docs/screenshots/overview-zh-Hans-light.png" width="760" alt="Sideboard 显示电视的屏幕、当前应用、播放、运行时间、CPU、内存、存储、网络、音量和最近 24 小时">
</p>

> **状态：早期预览版（0.1）。** 能看设备状态，能做基本操作。后续计划见“路线图”。

## 能看到什么

**总览**
- 屏幕：开、关（电视上是待机）、屏保；今天亮屏了多久
- 前台的 App，以及正在播放的内容（标题，或电视的信号源）
- 开机后运行了多久
- CPU 占用、核心数和频率；温度（如果设备提供的话，很多电视不提供）
- 内存和存储空间，有线还是 Wi-Fi、IP 地址，音量，电池

**最近 24 小时**
- 什么时候开机、关机，什么时候亮屏、熄屏，打开过哪些 App，以及今天用得最多的 App。
  数据来自安卓系统自己的使用记录，所以 Sideboard 没打开的时候发生的事也看得到。

**详细信息**
- 型号、Android 版本和安全补丁、版本号、内核、芯片、架构
- 屏幕分辨率、应用实际渲染的分辨率、像素密度、刷新率
- CPU 频率、平均负载、占用最高的进程
- 内存明细，内部存储和 U 盘/存储卡
- Wi-Fi 网络、信号、连接速率和频段
- 电源设置：多久进屏保、多久休眠、多久无操作自动关机、插电时是否保持唤醒。只显示，从不修改。
- 装了多少个 App，其中多少个是你自己装的

<p align="center">
  <img src="docs/screenshots/details-zh-Hans-light.png" width="760" alt="详细信息页">
</p>

## 能做什么（只在你点的时候）

- **遥控器**：方向键、确定、返回、主屏幕、音量、播放/暂停、休眠和唤醒。也可以用键盘的方向键、回车、Esc 和空格。
- **截屏**：图片直接传到 Mac，存在“图片 → Sideboard”里，设备上不留任何文件。
- **传文件**：把文件拖到窗口上（或者点“发送”），会放进设备的 Download 文件夹。
- **装 App**：拖进一个 `.apk`，就会安装或更新。

## 不折腾设备

- Sideboard 只读取，从不修改设备上的任何设置，包括待机设置。
- 窗口开着、屏幕亮着的时候每 5 秒读一次；熄屏时每分钟只看一次它有没有亮起来，让设备好好休息。窗口关了就什么都不读。
- “详细信息”页只在打开时才统计进程。
- 网络设备不在线时每分钟尝试重连一次，不会把它唤醒。
- 数据不离开你的 Mac：没有账号，没有统计。本说明里的截图用的都是虚构数据。

## 开始使用

1. **安装 adb**（Google 的 Android platform-tools）。用 Homebrew：

   ```bash
   brew install --cask android-platform-tools
   ```

   或者[下载 platform-tools](https://developer.android.com/tools/releases/platform-tools)，
   解压到 `~/Library/Android/sdk/platform-tools`。

2. **在设备上打开调试。** 打开“设置 → 关于”（电视上是“设置 → 系统 → 关于”），连续点按“版本号”七次。
   然后在开发者选项里打开“USB 调试”；要通过网络连接，还要打开“网络调试”（电视和盒子）
   或“无线调试”（手机和平板，Android 11 及以上）。

3. **连接。** 插上 USB 线；或者点“添加设备…”输入它的 IP 地址，也可以扫描整个网络。
   第一次连接时设备会询问是否允许这台 Mac 调试：勾选“一律允许”，再确认。

如果网络设备一切正常却连不上，点“重启 adb”：由其他程序（比如终端）启动的 adb 服务可能没有访问本地网络的权限。

## 安装

暂时还没有发布安装包，目前请从源码编译。

需要 macOS 14 Sonoma 或更新版本，Apple 芯片和 Intel 都可以。

## 从源码编译

需要 Xcode（只装命令行工具缺少 SwiftUI 的宏插件）。

```bash
./build.sh             # 编译出 build.noindex/Sideboard.app（通用版）
./build.sh --install   # 同时拷贝到 /Applications
./build.sh --dmg       # 同时制作发布用的 .dmg
python3 tools/check_localizations.py   # 检查所有翻译
```

反馈问题时，`Sideboard.app/Contents/MacOS/Sideboard --status` 会打印 Sideboard 从每台已连接设备读到的内容，
不含序列号、地址和网络名称。`--watch` 会像窗口一样运行设备列表和仪表盘 20 秒，并打印看到的内容。
`--snapshot <文件夹>` 用虚构的设备，把窗口在每种语言、浅色和深色下各渲染一张图。

## 语言

English、简体中文、繁體中文、日本語、Русский、Español、हिन्दी —— 随时在窗口里的地球图标菜单切换，不用重启。

英文和中文以外的翻译欢迎母语者帮忙校对，见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 路线图

- [ ] 设备端配套 App（可选）：超过 24 小时的历史、Mac 关着也能记录准确的开机和关机时间、输入任意语言的文字、共享剪贴板、显示 App 名称而不是包名
- [ ] App 管理：列出、卸载、停用预装 App（可恢复）
- [ ] 清理：App 缓存和大文件
- [ ] 菜单栏模式和通知（比如某台设备整晚都开着）

## 支持 Sideboard

Sideboard 永远免费。如果它让你照看设备更省心，可以请开发者喝杯咖啡——国内可以用微信或支付宝，海外可以用 PayPal。谢谢！

<p align="center">
  <img src="docs/donate/wechat.png" height="260" alt="微信支付二维码">
  <img src="docs/donate/alipay.png" height="260" alt="支付宝二维码">
  <img src="docs/donate/paypal.png" height="260" alt="PayPal 二维码">
</p>

## 联系

问题和建议：[提交 issue](../../issues)。邮箱：zhaoweijia1997@gmail.com

## 许可证

[MIT](LICENSE)
