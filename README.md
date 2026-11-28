<div align="center">
  <img src="AppIcon.iconset/icon_256x256.png" width="128" height="128" alt="Apollo AgentMeter Icon" />
  <h1>Apollo AgentMeter</h1>
  <p><strong>Native macOS Menu Bar Quota & Rate-Limit Monitor for Codex & Antigravity (Gemini / Claude / GPT / Argon)</strong></p>
  <p>原生 Apple Silicon 状态栏 AI 剩余额度与重置时间实时监控工具</p>
</div>

---

## ✨ 核心特性 (Features)

- **顶部状态栏一览无余**：常驻 macOS 状态栏，实时显示 `Codex ∞/xx% · Gemini xx%/xx%`（5h 短窗 / 7 天周窗剩余百分比）。
- **零打扰交互**：启动后默认静默折叠于状态栏，**仅当主动点击状态栏条目时才展开悬浮面板**，再次点击或点击 `−` 即收起。
- **开箱即用自动发现**：
  - 自动读取本地 `~/.codex/sessions` 最新会话速率限制与重置时间戳，过期自动回满；
  - 自动发现本机运行中的 Antigravity Language Server（支持 Antigravity 2.x 守护进程的 `httpPort` / `httpsPort`、`antigravity acp` 的本地免令牌 HTTP/HTTPS 连接，以及旧版进程参数发现；本地请求绕过代理），动态拉取最新模型分组额度（`Gemini`、`Claude / GPT`、`Gemini 4 Argon`）。
- **macOS 原生毛玻璃无框账本**：按模型分组，纵向排列并对齐各模型的短窗、周窗剩余额度与重置倒计时。侧边色条表示用量；已用 60%–80% 时显示预警，超过 80% 时标出已用百分比。
- **深浅主题与自由拖动**：一键切换主题，按住面板空白区域即可拖动，松开后自动记住位置。

---

## 📦 安装方式 (Installation)

### 方式一：通过 Releases DMG 安装（推荐）
1. 在 [Releases](../../releases) 页面下载最新的 **`Apollo-AgentMeter-1.0.3.dmg`**。
2. 双击挂载 DMG 镜像，将 **`AgentMeter.app`**（显示为 **Apollo AgentMeter**）拖入 **`Applications`** 文件夹。
3. 从「应用程序」或 Spotlight 启动即可。

> **提示**：如首次打开未公证的开源应用提示安全拦截，可在终端运行：
> ```bash
> xattr -cr "/Applications/AgentMeter.app"
> ```

### 方式二：从源码编译 (Build from Source)
无需复杂的 Xcode 工程，单文件纯原生 AppKit + SwiftUI 实现：
```bash
# 1. 生成多分辨率图标 AppIcon.icns
swift generate_icon.swift

# 2. 编译 Apple Silicon 原生二进制
swiftc -O -framework AppKit -framework SwiftUI AgentMeter.swift -o AgentMeter.app/Contents/MacOS/AgentMeter
```

---

## 📄 开源协议 (License)

MIT License © Apollo
