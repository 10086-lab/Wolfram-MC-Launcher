# Wolfram MC Launcher

用纯 Wolfram Language 写的 Minecraft 启动器。不需要 Node、Python 或任何第三方库，一个 `.wl` 文件加一个 `.sh` 入口就能跑。

## 功能

- **交互式菜单**，没有命令行参数，启动后改配置、切版本、登录都在菜单里完成
- **版本管理**：列出本机已装版本；从 Mojang 官方源下载任意正式版（库 + 资源 + 清单）
- **正版登录**：微软账号设备码流程，支持多账号保存与切换
- **离线模式**：不登录也能玩
- **可调配置**：内存、窗口大小、JVM 参数、游戏参数，设置写盘持久化
- **磁盘占用统计**：分别显示 libraries / assets / versions 的体积

## 依赖

- Wolfram Engine 14 以上（开发环境 15.0.1）
- Java 21 以上；Minecraft 26.x 需要 Java 25
- Linux（路径拼接、natives 解压按 Unix 写死）

## 用法

```bash
./run.sh
```

或者直接：

```bash
wolframscript -file mclaunch.wl
```

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

## 已知限制

- 只处理 Mojang 官方库，不认 Fabric / NeoForge 的额外依赖
- 在没有独立显卡的机器上用 llvmpipe 软渲染，帧率很低
- 下载走官方源，国内网络可能较慢
