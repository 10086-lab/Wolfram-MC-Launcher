# Wolfram MC Launcher

用纯 Wolfram Language 写的 Minecraft 启动器。不需要 Node、Python 或任何第三方库。

## 功能

- **交互式菜单**，没有命令行参数，启动后改配置、切版本、登录都在菜单里完成
- **版本管理**：列出本机已装版本；从 Mojang 官方源下载任意正式版（库 + 资源 + 清单）
- **正版登录**：微软账号设备码流程，支持多账号保存与切换
- **可调配置**：内存、窗口大小、JVM 参数、游戏参数，设置写盘持久化
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

菜单里 `s` 启动游戏，`7` 管理账号，`9` 下载版本，`q` 退出。

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
