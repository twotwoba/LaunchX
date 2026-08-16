# LaunchX

一个现代、优雅且智能的 macOS 启动器。高性能的应用和文件搜索，丰富的扩展功能，让你的 Mac 使用效率翻倍。

![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)

**搜索应用、文件、书签、剪贴板、提醒事项，复盘股票、AI 研判趋势，调度 Claude Code / Codex —— 一切从 `⌥Space` 开始。**

## 截图

<p align="center">
  <img src="./screenshots/main-panel.png" alt="LaunchX 主面板" width="720">
</p>

## 功能特性

### 核心功能

- **应用搜索** - 快速搜索并启动应用程序，支持英文、拼音、拼音缩写及 fzf 风格子序列模糊匹配
- **文件搜索** - 高性能文件索引，FSEvents 实时监控文件变化；选中后按 `⌘K` 可直接执行 cd 至此、复制路径、在 Finder 中显示、隔空投送、删除等操作
- **全局快捷键** - 自定义组合键或双击修饰键（双击 ⌥/⌘）快速唤起任何 App 或高级扩展
- **别名系统** - 每个应用、网站、扩展都能设置短别名（如 `gh` → GitHub、`gp` → 股票面板），输入两三个字母直达
- **IDE 项目** - 快速打开 VSCode、Zed、Cursor、Antigravity、JetBrains 系列 IDE 的最近项目
- **网页直达** - 配置常用网站，一键跳转或以关键词发起搜索
- **最近使用** - LRU 算法智能追踪最近使用的应用，常用优先
- **工具管理** - 所有工具统一收拢：别名、快捷键、启用开关，一张清单管理全部能力

### 高级扩展

- **股票面板** - 复盘研究工具：双击日 K 任意一根蜡烛即可回看当天分时，支持多天多开比对，历史分时回溯至 2015 年；叠加 MACD、KDJ 等技术指标；AI 多维度趋势研判会自动拉取历史 K 线、指标与资金流向，接入任意 OpenAI 兼容模型，推理模型思考流实时展示，支持自定义提示词模板；面板可置顶、尺寸可调
- **剪贴板管理** - 自动记录剪贴板历史（文本、图片、链接、颜色），分类过滤、关键词搜索、纯文本粘贴，敏感 App 可加入忽略名单
- **代码片段 (Snippet)** - 文本自动替换，支持动态变量（`{date}`、`{time}`、`{uuid}` 等）
- **AI 翻译** - 集成多种 AI 服务进行智能翻译，`⌥W` 划词即译，推荐硅基流动中的免费模型
- **书签搜索** - 从 Safari、Chrome、Helium 导入书签并快速搜索，自动同步变化
- **提醒事项管理** - 展示当天提醒事项，备注中设有 URL 时可通过 `⌘K` 快速打开
- **Claude Code 切换 (cc-switch)** - 输入 `cc` 唤起切换面板，Provider、上下文、MCP、Skills 即搜即切，不用手改配置文件
- **Codex 管理** - 与 cc-switch 同款体验，预设角色上下文一键启用；鉴权写入 config.toml，GUI 启动不丢环境变量
- **2FA 验证码** - 从短信中自动提取验证码（macOS 26 以下版本，新系统已内置）
- **系统命令** - 快速执行系统设置（深色模式、锁屏、关机、清空废纸篓、隐藏 Dock 等 10+ 命令）
- **实用工具** - Base64 编解码、IP 查询、URL 处理、UUID 生成、退出进程等
- **默认终端** - 一键唤起终端，配合文件夹 `⌘K` 的「cd 至此」秒开工作目录
- **内置 2 个改键选择** - 单/双引号互换，右 ⌘ 改为 Hyper 按键（F19）；caps/ctrl 互换去除了

## 安装

### 系统要求

- macOS 14.0 或更高版本

### 下载安装

1. 从 [Releases](https://github.com/twotwoba/LaunchX/releases) 下载最新的 `.dmg` 文件（Apple 芯片 / Intel 均有原生构建）
2. 打开 DMG 文件，将 LaunchX 拖入 Applications 文件夹
3. 首次启动时，按照引导授予必要权限

### 权限说明

LaunchX 需要以下系统权限才能正常工作：

| 权限 | 用途 |
|------|------|
| **辅助功能** | 全局快捷键注册、键盘事件监听、代码片段自动替换 |
| **完全磁盘访问** | 索引和搜索所有文件、读取浏览器书签 |

首次启动时会有权限引导流程，按照提示操作即可。所有数据仅存储在本地。

## 快速上手

### 基本使用

1. **唤起搜索框** - 按下 `Option + Space`（可自定义，或双击修饰键）
2. **搜索应用** - 输入应用名称，支持拼音、拼音缩写、模糊匹配
3. **启动应用** - 按 `Enter` 打开选中的应用
4. **上下选择** - 使用 `↑` `↓` 或 `Ctrl+n/p` 选择结果
5. **就地操作** - 选中文件/文件夹后按 `⌘K` 呼出快捷操作菜单

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Option + Space` | 唤起主搜索面板（默认） |
| `Enter` | 打开选中项 |
| `↑` / `↓` 或 `Ctrl+n/p` | 上下选择 |
| `Tab` | 展开 IDE 项目列表 / 切换焦点 |
| `⌘K` | 文件/文件夹快捷操作（cd 至此、复制路径等） |
| `Esc` | 关闭面板 |
| `Cmd + ,` | 打开设置 |

### 别名与扩展唤起

在设置中可为各扩展功能配置独立别名与快捷键，例如：

- `gp` - 股票面板
- `cc` / `cx` - Claude Code / Codex 切换面板
- `bk` - 书签搜索
- `⌥W` - AI 划词翻译
- 剪贴板面板、默认终端等均可自定义

更多功能继续开发中...

## 配置

### 搜索范围

在设置中可自定义：

- **应用搜索范围** - 默认搜索 `/Applications`、`/System/Applications` 等
- **文档搜索范围** - 默认搜索下载、文档、桌面文件夹，可添加外置磁盘路径
- **排除文件夹** - 如 `node_modules`、`dist` 等
- **排除应用** - 隐藏不需要的应用

### IDE 支持

自动扫描以下 IDE 的最近项目：

- Visual Studio Code
- Zed
- Cursor
- Antigravity
- IntelliJ IDEA / PyCharm / WebStorm / GoLand 等 JetBrains 系列

### AI 能力配置

AI 翻译与股票 AI 分析均支持任意 OpenAI 兼容服务：

- OpenAI (GPT)、Anthropic (Claude)、DeepSeek、智谱 GLM、阿里云通义千问等
- 硅基流动等提供免费额度的服务即可开箱体验
- 在设置中配置 API 地址、密钥与模型即可

## 技术架构

- **搜索引擎** - 基于 Trie 前缀树的高性能内存索引，重复搜索零开销，搜索响应 < 1ms
- **文件监控** - 使用 FSEvents 实时监控文件变化，变更延迟低至 1.3s
- **混合架构** - AppKit + SwiftUI，轻量锁替代串行队列，非关键路径延后执行
- **数据持久化** - SQLite 索引数据库 + JSON 配置文件，数据全部本地存储

## 更新日志

查看 [CHANGELOG.md](CHANGELOG.md) 了解完整更新历史。

## 开发

### 技术栈

- Swift 5.9
- SwiftUI + AppKit
- SQLite3
- Carbon Framework (全局快捷键)

### 项目结构

```
LaunchX/
├── App/                    # 应用入口和面板
├── Models/                 # 数据模型
├── Services/               # 业务逻辑服务
│   └── SearchEngine/       # 搜索引擎核心
├── ViewModels/             # 视图模型
├── Views/                  # UI 视图
└── Assets.xcassets/        # 资源文件
```

## 交流

如果您在使用过程中有任何建议、疑问或困难，可以提 issue 或者加我wx：EricYuan228

## 贡献

欢迎提交 Issue 和 Pull Request！

## 许可证

[Apache License 2.0](LICENSE)

## 致谢

感谢所有为这个项目提供灵感和帮助的开源项目。
