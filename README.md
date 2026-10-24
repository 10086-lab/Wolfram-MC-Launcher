# Wolfram MC Launcher

用纯 Wolfram Language 写的 Minecraft 启动器。不需要 Node、Python 或任何第三方库。

## 功能

- **交互式菜单**，没有命令行参数，启动后改配置、切版本、登录都在菜单里完成
- **版本管理**：列出本机已装版本；从 Mojang 官方源下载任意正式版（库 + 资源 + 清单）
- **正版登录**：微软账号设备码流程，支持多账号保存与切换
- **可调配置**：内存、窗口大小、JVM 参数、游戏参数，设置写盘持久化
- **磁盘占用统计**：分别显示 libraries / assets / versions 的体积

## 依赖

- Wolfram Engine 14 以上（开发环境 15.0.1）
- Java 21 以上；Minecraft 26.x 需要 Java 25
- Linux（其他平台未测试）

三样都不花钱。Wolfram Engine 是免费下载的，只有 Mathematica 完整版才收费。

## 安装

### 1. Wolfram Engine

到 <https://www.wolfram.com/engine/> 下载 Linux 版（`.sh` 安装包），执行：

```bash
bash WolframEngine_*.sh
```

装完打开一个新终端，首次运行会要求用 Wolfram ID 激活：

```bash
wolframscript -code '1+1'
```

输出 `2` 就说明引擎和激活都正常。

如果报 `wolframscript: command not found`，说明没进 PATH，建个软链：

```bash
sudo ln -s /usr/local/Wolfram/WolframEngine/*/Executables/wolframscript /usr/local/bin/
```

已经装了 Mathematica 或 Wolfram|One 的可以跳过这步，`wolframscript` 是通用的。

### 2. Java

```bash
sudo apt install openjdk-21-jdk
```

要玩 26.x 系列得用 JDK 25，Debian 仓库里通常没有，去 [Oracle](https://www.oracle.com/java/technologies/downloads/) 或 [Temurin](https://adoptium.net/) 下：

```bash
sudo tar -xzf jdk-25_linux-x64_bin.tar.gz -C /usr/lib/jvm/
```

启动器会在这几个位置自动找 Java：

```
/usr/lib/jvm/jdk-*/bin/java
/usr/lib/jvm/java-*/bin/java
/usr/bin/java
```

都找不到就读 `~/.minecraft/wl-launcher.conf` 里的 `jvm=` 手动指定。

### 3. 代码

```bash
git clone https://github.com/10086-lab/Wolfram-MC-Launcher.git
cd Wolfram-MC-Launcher
```

## 用法

```bash
./run.sh
```

或者直接：

```bash
wolframscript -file mclaunch.wl
```

必须在**真正的终端**里跑。用管道、重定向或某些 IDE 的伪终端喂输入会失败，因为 `InputString` 依赖 tty。

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

**第一步，按 `9` 下载版本。** 会问版本号，输 `26.2` 或 `26.3`。库约 80MB、资源约 460MB，看网速。

**第二步，按 `7` 选登录方式。**

- `1` 离线模式，随便填个名字直接玩
- `2` 添加微软账号，会给出一个链接和 8 位设备码，浏览器打开链接输入码、登录微软账号授权，回终端等它自己完成

**第三步，按 `s` 启动。** 启动器自己挑 Java、装库、解压 natives、拼 classpath，然后拉起游戏。默认盯 10 秒日志，看到 `Sound engine started` 之类的输出就说明进得去了。

### 之后

配置会存到 `~/.minecraft/wl-launcher.conf`，下次打开菜单直接沿用，按 `s` 就能玩。

菜单里 `s` 启动游戏，`7` 管理账号，`9` 下载版本，`q` 退出。

## 文件

| 文件 | 说明 |
| --- | --- |
| `mclaunch.wl` | 全部逻辑，约 750 行 |
| `run.sh` | 启动入口 |
| `.gitignore` | 忽略日志、临时产物和本地凭证 |

配置与凭证落在 `~/.minecraft/` 下（不随仓库分发）：

- `wl-launcher.conf` — 版本、内存、窗口、当前账号等
- `wl-launcher-accounts.json` — 账号库，权限 600
- `wl-launcher-token.json` — 旧版单凭证，首次运行会自动并入账号库

## 常见问题

**「本地版本」显示 0 个**

`~/.minecraft/versions/` 下每个版本目录必须同时有 `<版本号>.jar` 和 `<版本号>.json`。缺 json 没法还原启动参数，会被跳过。按 `9` 重新下载一次就补齐了。

**启动后闪退，日志里有 `NoClassDefFoundError`**

大概率是库文件下坏了。删掉 `~/.minecraft/libraries/` 和 `~/.minecraft/assets/objects/` 重下一次。

**输出中文乱码**

`wolframscript -file` 按 Latin-1 读源码，所以源码里所有非 ASCII 字符都写成 `\:XXXX` 转义形式。自己改代码加中文的话，记得一起转义。

## 已知限制

- 只处理 Mojang 官方库，不认 Fabric / NeoForge 的额外依赖
- 在没有独立显卡的机器上用 llvmpipe 软渲染，帧率很低
- 下载走官方源，国内网络可能较慢
