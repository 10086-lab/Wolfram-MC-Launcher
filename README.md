# Wolfram MC Launcher

用纯 Wolfram Language 写的 Minecraft 启动器。不需要 Node、Python 或任何第三方库。

## 功能

- **交互式菜单**，没有命令行参数，启动后改配置、切版本、登录都在菜单里完成
- **版本管理**：列出本机已装版本；从 Mojang 官方源下载任意正式版（库 + 资源 + 清单）
- **正版登录**：微软账号设备码流程，支持多账号保存与切换
- **可调配置**：内存、窗口大小、JVM 参数、游戏参数，设置写盘持久化
- **多实例**：每个实例一套独立的游戏目录，存档、资源包、按键设置互不干扰。`default` 实例就是 `~/.minecraft` 本身，老存档照常可见
- **资源下载**：内置 Modrinth 搜索，按当前版本筛出可用的资源包，直接装进当前实例的 `resourcepacks/`
- **模组管理**：列出 `mods/` 里的 jar 并标注它是 Fabric 还是 NeoForge 的；从 Modrinth 按当前版本 + 加载器筛出可装的模组直接下载；加载器不匹配时启动前会提示
- **磁盘占用统计**：分别显示 libraries / assets / versions 的体积
- **跨平台**：Windows、macOS、Linux 用同一份代码；按清单的 `rules` 自动挑平台对应的库和 natives
- **版本通吃**：1.13+ 用 `arguments`，更早的版本用 `minecraftArguments`，旧版 natives 也能处理

## 依赖

- Wolfram Engine 14 以上（开发环境 15.0.1）
- Java：启动器会扫描 `JAVA_HOME`、`PATH` 和常见安装目录，按版本清单的
  `javaVersion.majorVersion` 挑最合适的。Minecraft 1.12 及更早需要 Java 8，
  1.17+ 需要 Java 17，26.x 需要 Java 25。不会自动下载 Java
- 支持 Windows / macOS / Linux

## 安装

### 1. Wolfram Engine

到 <https://www.wolfram.com/engine/> 下载对应平台的安装包。

Linux 是 `.sh` 安装包：

```bash
bash WolframEngine_*.sh
```

macOS 是 `.dmg`，Windows 是 `.exe`，双击装完即可。

装完打开一个新终端验证：

```bash
wolframscript -code '1+1'
```

输出 `2` 就说明引擎和激活都正常。报 `command not found` 说明没进 PATH，Linux 上建个软链：

```bash
sudo ln -s /usr/local/Wolfram/WolframEngine/*/Executables/wolframscript /usr/local/bin/
```

已经装了 Mathematica 或 Wolfram|One 的可以跳过这步，`wolframscript` 是通用的。

### 2. Java

按你要玩的版本选 JDK：

| Minecraft 版本 | 需要 |
| --- | --- |
| 1.12 及更早 | Java 8 |
| 1.13 – 1.16 | Java 8 或 11 |
| 1.17 – 1.20 | Java 17 |
| 26.x | Java 25 |

装法随平台：

```bash
# Debian / Ubuntu
sudo apt install openjdk-17-jdk

# macOS
brew install openjdk@17

# 其他版本（26.x 的 25、老版本的 8）去 Oracle 或 Temurin 下压缩包
# https://adoptium.net/
```

Temurin 的压缩包解到 `/usr/lib/jvm/`（Linux）或 `/Library/Java/JavaVirtualMachines/`（macOS）就行，启动器会扫到。

### 3. 代码

```bash
git clone https://github.com/10086-lab/Wolfram-MC-Launcher.git
cd Wolfram-MC-Launcher
```

## 用法

Linux / macOS：

```bash
./run.sh
```

Windows：

```bat
run.bat
```

或者直接：

```bash
wolframscript -file mclaunch.wl
```

如果你有 Mathematica 之类的，可以直接在 notebook 里跑。

如果只是Wolfram Engine必须在**真正的终端**里跑。用管道、重定向或某些 IDE 的伪终端喂输入会失败，因为 `InputString` 依赖 tty。

### 第一次跑

菜单长这样：

```
  1) 版本        最新正式版
  2) 玩家名      Steve
  3) 内存        4G
  4) 窗口        1280x720
  5) JVM 参数    （无）
  6) 游戏参数    （无）
  --------------------------------------------
  7) 账号        离线 Steve
  8) 本地版本    0 个已安装
  9) 下载版本
  a) 安装加载器   Fabric / Forge / NeoForge
  m) 模组        2 个（NeoForge）
  i) 游戏目录    default  /home/you/.minecraft
  r) 资源下载    资源包（Modrinth）
  d) 磁盘占用
  --------------------------------------------
  s) 启动游戏
  q) 退出
```

**第一步，按 `9` 下载版本。** 会问版本号，输 `26.2` 或 `26.3`。库约 80MB、资源约 460MB，速度看你家宽带能力和微软土豆有没有发芽。

**第二步，按 `7` 选登录方式。**

- `1` 离线模式，随便填个名字直接玩
- `2` 添加微软账号，会给出一个链接和 8 位设备码，浏览器打开链接输入码、登录微软账号授权，回终端等它自己完成

**第三步，按 `s` 启动。** 启动器自己挑 Java、装库、解压 natives、拼 classpath，然后拉起游戏。默认盯 10 秒日志，看到 `Sound engine started` 之类的输出就说明进得去了。

配置会存盘，下次打开菜单直接沿用，按 `s` 就能玩。

菜单里 `s` 启动游戏，`7` 管理账号，`9` 下载版本，`i` 切实例，`r` 下资源包，`q` 退出。

### 模组

按 `m` 打开模组菜单：

- 列出 `mods/` 里所有 jar，标出体积和类型（`[fabric]` / `[neoforge]` / `[forge]`），跟当前加载器不匹配的会加一句 `[!] 当前加载器用不了`
- `1` 从 Modrinth 搜模组，按当前 MC 版本 + 加载器筛出可用的文件再下载
- `2` 删除、`3` 在文件管理器里打开 `mods/`

给 NeoForge 版本装 Fabric 模组不会起作用，游戏会直接忽略它们；启动器在启动前会把这种不匹配打印出来。

### 多实例

按 `i` 进实例管理，能新建、切换、删除。每个实例是独立的一套游戏目录：

```
~/.minecraft/               ← default 实例（老存档都在这）
~/.minecraft/instances/foo/ ← 新建的 foo 实例（默认位置）
/home/you/mc-bar/           ← 也可以指定任意目录，比如建在别的盘
```

新建时会问目录，直接回车就用 `~/.minecraft/instances/<名字>`，也可以填绝对路径、`~/xxx` 或者相对路径。指定过目录的实例记在 `~/.minecraft/instances.json`，菜单里会显示每个实例的实际路径。

存档、资源包、按键设置、显示设置各管各的，互不污染。新建实例会继承当时的配置，之后改哪个实例的配置就只写那个实例目录里的 `launcher.conf`。

`default` 实例不能删——它对应 `~/.minecraft` 本身，删了等于删游戏目录。自定义目录的实例删除时只删掉记录，不动你已经存进去的存档和文件。

### 资源包

按 `r`，输关键词，从 Modrinth 里搜。挑一个，启动器会按你当前选的 Minecraft 版本筛出适配的文件，下到当前实例的 `resourcepacks/`。

下完进游戏，`选项 → 资源包`，左边列表里点一下装上，再点箭头移到右边启用。

### 版本与模组加载器

版本就是 `~/.minecraft/versions/` 下的一个目录——跟官方启动器、HMCL、Prism 一样。装加载器不是"给当前版本加个开关"，而是**多出一个版本条目**，在 `1) 版本` 的列表里跟原版并排出现：

```
  选择要启动的版本：
   1) 1.19
   2) 26.2
   3) 26.3
   4) 26.3-forge-66.1.0
   5) neoforge-26.3.0.97
```

按 `a` 装新的加载器版本，先选基底原版，再选加载器：

```
  1) Fabric   2) Forge   3) NeoForge
```

装完自动切到新条目。

**Fabric** 走纯 API：按 MC 版本向 `meta.fabricmc.net` 要一份 profile，存成 `versions/fabric-loader-<lv>-<mc>/fabric-loader-<lv>-<mc>.json`，主类换成 `KnotClient`，不动任何原版文件。

**Forge / NeoForge** 跑官方安装器（`--installClient`），装完自己生成 `versions/26.3-forge-66.1.0/` 或 `versions/neoforge-26.3.0.97/`。第一次慢（安装器要下几十 MB），之后走缓存。

启动时读 `versions/<id>/<id>.json`，如果有 `inheritsFrom` 就递归把父版本的库和参数合并进来——官方启动器就是这么做的，加载器的 json 只列增量。注意子版本里的空 `logging` / `downloads` 是占位，不能盖掉父版本的真值。

版本号规则：Forge 是 `<MC>-<ver>`（如 `26.3-66.1.0`），NeoForge 是 `<MC 主次>.<patch>`（如 `26.3.0.97`，MC `1.21.1` 对应 `21.1.x`），Fabric 是独立的 loader 版本号。不是每个 MC 版本都有，选之前会先列出可用的。

> NeoForge 的官方 maven 国内直连不通，用 BMCLAPI 镜像；它的 HTTPS 会让 Wolfram 内置 curl 报 SSL 35，所以这条路径退回系统 `curl`（Windows 10+、macOS、主流 Linux 都自带）。

装完 Fabric 后把 `fabric-api` 之类的 mod 丢进当前实例的 `mods/` 就能用。版本和加载器都跟着实例走，换实例互不影响。

## 数据目录

默认位置跟官方启动器一致：

| 平台 | 目录 |
| --- | --- |
| Windows | `%APPDATA%\.minecraft` |
| macOS | `~/Library/Application Support/minecraft` |
| Linux | `~/.minecraft` |

想换位置可以设环境变量 `MCLAUNCH_GAME_DIR`，比如把游戏装到移动硬盘。

配置与凭证就放在这个目录下，不随仓库分发：

- `wl-launcher.conf` — 版本、内存、窗口、当前账号等
- `wl-launcher-accounts.json` — 账号库，权限 600（Windows 受限于 NTFS 权限）
- `wl-launcher-token.json` — 旧版单凭证，首次运行会自动并入账号库

## 文件

| 文件 | 说明 |
| --- | --- |
| `mclaunch.wl` | 全部逻辑，约 900 行 |
| `run.sh` | Linux / macOS 启动入口 |
| `run.bat` | Windows 启动入口 |
| `.gitignore` | 忽略日志、临时产物和本地凭证 |

## 常见问题

**「本地版本」显示 0 个**

每个版本目录必须同时有 `<版本号>.jar` 和 `<版本号>.json`。缺 json 没法还原启动参数，会被跳过。按 `9` 重新下载一次就补齐了。

**启动后闪退，日志里有 `NoClassDefFoundError`**

大概率是库文件下坏了。删掉 `libraries/` 和 `assets/objects/` 重下一次。

**提示 Java 版本不匹配**

启动器不会自动下 Java，得自己装对应版本的 JDK。装完确认 `java -version` 输出的是想要的那个，或者设 `JAVA_HOME` 指过去。

**输出中文乱码**

`wolframscript -file` 按 Latin-1 读源码，所以源码里所有非 ASCII 字符都写成 `\:XXXX` 转义形式。自己改代码加中文的话，记得一起转义。

## 已知限制

- 只处理 Mojang 官方库，不认 Fabric / NeoForge 的额外依赖
- 不会自动下载 Java，版本不匹配时会提示
- 在没有独立显卡的机器上用 llvmpipe 软渲染，帧率很低
- 下载走官方源，国内网络可能较慢

## 免责声明

本项目是一个非官方的第三方启动器，与 Mojang Studios、Microsoft Corporation 以及网易均无关联，也未获得上述任何一方的授权、认可或赞助。

- **Minecraft** 是 Mojang Studios 的注册商标，游戏本体的著作权归其所有。
- 本项目**不包含、也不分发**任何游戏本体、资源文件或账号凭据。所有游戏文件要么由启动器在你本地直接从 Mojang 官方服务器下载，要么使用你机器上已安装的版本。
- 使用本项目需遵守 [Minecraft 最终用户许可协议](https://www.minecraft.net/en-us/eula)、[使用指南](https://www.minecraft.net/en-us/usage-guidelines) 以及你所在地的法律法规。
- 中国大陆地区的 Minecraft 由网易代理运营，相关服务与条款以网易官方为准。
- 离线模式仅用于单人测试与开发调试，请支持正版。
- 本项目按「现状」提供，不对账号安全、数据丢失或由此产生的任何直接、间接损失承担责任。
