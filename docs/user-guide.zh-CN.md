# Fulcrum 用户指南

从零开始讲清楚 Fulcrum 的每一项功能——假设你从未用过启动器类产品。
[English](user-guide.md)

## 什么是启动器？

平时用电脑是这样的：翻菜单找应用、层层点进文件夹找文件、同一段话复制粘贴第无数次。**启动器**把这些全部换成一个习惯：按一下快捷键，输入你想要的东西，回车。它是整台电脑的搜索框，悬浮在你正在做的事之上。

Fulcrum 就是这样的产品，覆盖 macOS、Windows 和 Linux——三个平台功能一致、键位一致。你搜索过什么、复制过什么，都不会离开你的电脑。

## 一个习惯走天下

- **召唤**：按 `Alt+Space`（macOS 上是 `⌥Space`），面板出现。
- **输入**：你想要的东西——应用名、算式、搜索词。
- **回车**：执行选中的结果。
- **Esc**：一层一层退掉屏幕上的东西。输入框里有字，第一下清空；已经空了，第二下隐藏面板。Esc 永远不会执行任何东西。
- **↑ / ↓**：移动选中项。**Ctrl+K**（macOS 上 `⌘K`）：打开选中结果的附加动作（复制、删除、置顶、粘贴……）。

面板随时可以隐藏，它会安静待命直到你再次召唤；点别处时面板也会自动让开。

> 快捷键可以改——见[设置](#设置)。如果 `Alt+Space` 没反应，多半是被别的应用占了；Fulcrum 会自动退到 `Ctrl+Alt+Space`，并在状态栏告诉你。

## 日常功能

### 启动应用

直接输入应用名——`firefox`、`term`、`calc`。Fulcrum 用模糊匹配搜索已安装的应用：`ffx` 能找到 Firefox，手滑打错也能容忍。常用的应用会随使用越来越靠前。

### 行内计算

在搜索框里直接敲算式：`128*768`、`(2+3)^4`、`sqrt(2)`。答案直接出现在结果里，回车即复制。函数（`sin`、`log2`、`min`……）、常量（`pi`、`e`）、精确算术都支持。

### 剪贴板历史

你复制的每一段文字都会被记住（只记在本机）——可搜索、可置顶、绝不外发。

- 输入 `clip`（或任何你复制过的内容里的词），选中那条记录。
- **回车直接粘贴进你刚才在用的应用**——不用切换窗口，不用再按 Ctrl+V。这是日常最顺手的一招：这边搜到，那边就粘贴好了。
- Ctrl+K 提供传统玩法：**复制**（老行为）、**置顶**（不被新记录挤掉）、**删除**。

剪贴板历史可以在设置里关掉。Linux 上由 GTK 宿主记录运行期间的剪贴板变化。

### 片段（Snippet）

片段就是存在一个关键词下的文字：你的地址、银行账号、标准的会议回复。

不用离开启动器就能创建：

```
add snippet addr 上海市静安区南京西路 42 号
```

就这样——关键词是 `addr`，文字是后面整段，出现的那一行回车即保存。输入关键词或文字片段就能找到；回车复制，Ctrl+K 可以**粘贴到前台应用**或**删除**。输入 `snippets` 可以列出全部。

片段跟随 [Sync beta](#sync-beta) 同步。

### 快捷链接（Quicklink）

快捷链接是带关键词的收藏。行内创建：

```
add link yt https://youtube.com/search?q={query}
```

之后 `yt lofi hip hop` 就会打开那个搜索。URL 里的 `{query}` 会被替换成关键词后面的内容。输入 `quicklinks` 可以查看和删除。

### 网页搜索

Fulcrum 支持 DuckDuckGo 风格的 bang：

| 输入 | 打开 |
|---|---|
| `!g rockets` | Google 搜索 |
| `!d rockets` | DuckDuckGo 搜索 |
| `!gh rivet` | GitHub 搜索 |
| `!so segfault` | Stack Overflow 搜索 |
| `!w saturn` | 维基百科 |
| `!yt lofi` | YouTube 搜索 |
| `!m eiffel tower` | Google 地图 |
| `!t fulcrum` | X/Twitter 搜索 |

其他没被别处匹配的普通文字，最后会出现一条通用网页搜索（默认 `!g`，可配置）。

### 窗口管理

输入 `window` 或命令名的一部分：**Left Half**（左半屏）、**Right Half**（右半屏）、**Maximize**（最大化）、**Almost Maximize**（近全屏）、**Center**（居中）、**Restore**（还原）。命令作用于你召唤 Fulcrum 之前最前面的那个窗口。Restore 撤销该窗口上一次平铺。

### 找文件（macOS）

`find invoice` 通过 Spotlight 搜索文件名。Windows 和 Linux 上会诚实地提示需要平台搜索索引，而不是假装搜过。

### 系统命令

输入 `lock`、`sleep`、`restart` 锁屏、休眠、重启——Fulcrum 只提供你的平台上真实存在的命令。

## AI（自带密钥）

Fulcrum 的 AI 是 BYOK 模式：用你自己的 OpenAI、Anthropic 或本地 Ollama 密钥。Fulcrum 不收费、也不经手——密钥存在本地文件里、永不同步；只有你执行 AI 命令时，提示词才会发给你配置的服务商。

一次性设置：

1. 输入 `settings`，运行 `ai-provider` 那一行，循环切换到你的服务商（`openai`、`anthropic` 或 `ollama`）。
2. 输入 `ai key sk-…`（你的真实密钥）回车。Ollama 不需要密钥——只要 `ollama serve` 在跑就行。

用法：

- `ai summarize`——总结剪贴板里的内容。
- `ai clean`——修剪贴板文本的语法和拼写。
- `ai translate zh`——把剪贴板翻译成中文（或任何语言）。
- `ai explain`——解释剪贴板里的内容。
- `ai chat 解释一下黑话`——会记住本次会话前面几轮的提问。
- 或者直接问：任何以 `？`/`?` 结尾、足够长的输入会自动出现「Ask AI」一行。

答案会**流式地打进面板里**——它生成的时候你就能开始读——完成后自动落到剪贴板。Esc 关掉它；对 `ai` 里的"上一条回答"行按 Ctrl+K 可以直接粘贴进你在用的应用。

## 插件

插件可以用任何能输出 JSON 的语言编写——内置画廊自带十一个真实插件：单位换算（`u`）、Unix 时间戳（`ts`）、正则表达式（`re`）、时区（`tz`）、GitHub 仓库搜索（`gh`）、crates.io（`crate`）、Homebrew（`brew`）、Docker 镜像（`dk`）、winget（`winget`）、Bitwarden（`bw`）、汇率换算（`cur`）。

- 输入 `gallery` 查看全部；回车安装或卸载。
- 输入 `plugins` 查看已装插件，逐个开关。
- 输入 `plugins <名字>` 看插件详情页：每条命令带可复制的示例。
- `install plugin /路径/文件夹` 从任意文件夹安装插件——写一个插件只需一个 manifest 加一个脚本，见 [docs/plugins.md](plugins.md)，Python 就够。

## 设置

输入 `settings`，运行对应的行即可修改——每行在合法取值间循环：

- **language**——界面语言（zh/en；更新对话框跟随）。
- **theme**——system / light / dark，面板立即跟随。
- **hotkey**——在 `alt+space`、`ctrl+alt+space`、`ctrl+shift+space`、`alt+shift+space` 间循环。组合键被占用时 Fulcrum 会退回默认并提示。
- **max-results**——列表最多显示几行。
- **clipboard-enabled**——剪贴板历史开关。
- **web-search-enabled**——网页搜索行开关。
- **plugins-enabled**——插件加载开关。
- **ai-provider**——见 AI 一节。

进阶用户可以直接改 `settings.json`。hotkey 接受 `mod+key` 形式——修饰键 `alt/ctrl/shift/cmd/win/super`（至少一个），键位从这些里选：`space`、`a`–`z`、`0`–`9`、`f1`–`f12`、`comma`、`period`、`minus`、`equal`、`tab`。同一写法三平台通用。

## 更新

输入 `update`，运行 **Check for updates now**。有新版本时后台下载、实时进度。macOS 上 Fulcrum 原地换包重启；Windows 和 Linux 会打开下载好的安装包并给出诚实的手动步骤提示。更新包全部有签名；校验失败会被拒收，绝不安装。

## Sync beta

如果你在用 iCloud Drive、Dropbox、Syncthing 或任何目录同步服务，把 `sync-root`（通过 `settings.json` 或环境变量 `FULCRUM_SYNC_DIR`）设到同步盘里的一个目录。设置和片段会镜像过去——新机器或被抹掉的机器在首次启动时自动恢复。剪贴板历史和 AI 密钥**刻意**不参与同步。

## 键位速查

| 按键 | 动作 |
|---|---|
| `Alt+Space`（默认） | 显示 / 隐藏面板 |
| 输入 | 搜索一切 |
| `↑` / `↓` | 移动选中 |
| `回车` | 执行选中（剪贴板行为直接粘贴） |
| `Ctrl+K` / `⌘K` | 选中项的附加动作 |
| `Esc` | 逐层退掉：附加动作 → AI 回答 → 查询词 → 面板 |

## 疑难排查

- **快捷键没反应。** 组合键被别的应用占了。Fulcrum 会退到 `Ctrl+Alt+Space` 并在状态栏说明；也可以从托盘图标（Windows）、菜单栏（macOS）或 `fulcrum --toggle`（Linux）打开。
- **macOS 上「粘贴到前台」没反应。** 合成按键需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Fulcrum。窗口管理命令用的是同一个权限。
- **Linux 上「粘贴到前台」。** X11 开箱即用。Wayland 需要安装 `wtype`（合成器不允许应用直接注入输入——这是安全特性，Fulcrum 尊重它）。
- **AI 提示没有密钥。** 先在设置里选好服务商，再运行 `ai key <密钥>`。Ollama 不需要密钥，只要 `ollama serve` 在跑。
- **Linux 上剪贴板历史是空的。** 只记录 Fulcrum 运行期间的复制，面板只显示启动以来捕获的内容。
- **数据都在哪？** 全部在一个数据目录里（`FULCRUM_DATA_DIR`）：各存储是 JSON，密钥在 `ai-keys.json`。删掉它，Fulcrum 就是全新状态。

## 隐私

搜索、历史、片段永不离开你的设备。没有遥测。Fulcrum 发起的网络请求只有三种：你触发的更新检查（以及节流后的静默检查，都指向签名的发布源）、你显式运行的网页搜索、你显式运行的 AI 提示——只发给你配置的服务商，带着你自己的密钥。
