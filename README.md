# 赛博美学数字艺术多媒体交互画框

2026 年全国大学生嵌入式芯片与系统设计竞赛 FPGA 创新设计赛道，安路科技选题一“基于安路 EG4S20 的 HDMI 多媒体播放系统”。

作品基于 HX4S20C 开发板，将 TF 卡图片、背景音乐与四季赛博城市整合在同一套 FPGA 系统中，通过 HDMI 输出画面和声音。用户可切换图片与动态场景，调节亮度、对比度和音量，并开启中文字幕与音频可视化。系统固化后上电运行，无需电脑参与播放。

## 1. 作品功能

| 功能 | 说明 |
| --- | --- |
| 图片播放 | 读取 TF 卡中的六张 24 位非压缩 BMP，经 SDRAM 缓存后显示；支持手动切换和自动轮播 |
| 图像缩放 | 双线性等比缩放，适配 640×360 画布并居中补黑；HDMI 输出 1280×720、60 Hz 视频 |
| 画面转场 | 切换图片时淡出、淡入；自动轮播周期可选 3、5、15 秒 |
| 四季动态场景 | 雨夜霓虹、黄昏雷云、薄雾深夜、飘雪清晨；天气、灯光、交通与人物由 FPGA 实时生成 |
| 音乐播放 | 48 kHz、16 位、双声道 PCM，支持四首曲目选择，通过 HDMI 输出 |
| 字幕与音频可视化 | 七条中文字幕随图片或场景切换；音频幅度柱随实际播放样本变化 |
| 实时交互 | 中文菜单调节亮度、对比度、音量、轮播周期，并控制字幕、音频可视化、图片选择和选曲 |

## 2. 运行环境

| 项目 | 要求 |
| --- | --- |
| 开发板 | 安路 HX4S20C，FPGA 型号 EG4S20BG256 |
| 开发工具 | Anlogic TD 6.2.1，完整版本 6.2.168116，安装 USB-JTAG 下载驱动 |
| 电脑 | Windows，Python 3.10 或以上版本；构建脚本使用 Python 标准库，无需安装额外 Python 包 |
| 存储 | FAT32 格式 TF 卡及读卡器，配套图片和音乐素材另行提供 |
| 显示与声音 | 支持 1280×720、60 Hz 的 HDMI 显示设备；使用显示设备扬声器或其音频输出口连接耳机、音箱 |
| 连接线 | USB-JTAG 数据线、HDMI 线 |

Python 用于电脑端构建和读卡核验，作品运行时不需要 Python。阅读技术文档可直接打开 PDF，无需安装 LaTeX。

## 3. 工程目录

```text
FPGA_Anlu/
├─ project/
│  ├─ probe.al                 TD 工程，顶层模块 top
│  ├─ top.v                    顶层连接、时钟、复位和交互控制
│  ├─ sd.v                     TF 读卡、BMP 解析、缩放加载和音乐读取
│  ├─ video.v                  帧缓存、画面处理、菜单、字幕和音频输出
│  ├─ ip.v                     PLL、FIFO 等模块
│  ├─ build.tcl                完整综合、布局布线流程
│  ├─ fonts/                   基础字模
│  ├─ scene/                   四季场景、字幕、菜单和刷新控制
│  ├─ probe/                   720p 合成、扫描输出和时钟模块
│  ├─ reference/               双线性缩放核
│  └─ ip/                      工程文件校验和媒体规格清单
├─ user_source/                厂商 IP 引用的配置头
├─ tools/                      构建与 TF 卡只读核验脚本
├─ report/                     技术文档 PDF、LaTeX 源码和配图
└─ LICENSES/                   相关组件许可证
```

TD 工程入口为 [project/probe.al](project/probe.al)，顶层文件为 [project/top.v](project/top.v)。编译请使用下文的构建命令，脚本会执行完整时序约束和布局布线配置。保留上述目录层级，解压后即可使用，无需另行查找 IP 文件。

## 4. TF 卡素材准备

使用另交的配套图片和音乐，保持文件内容及下列文件名。取放 TF 卡、连接 HDMI 和 USB-JTAG 前，先关闭开发板电源。

在 TF 卡根目录建立 `SHOW640` 文件夹，将六张图片按下表命名并放入：

| 卡上路径 | 画面 | 输入尺寸 |
| --- | --- | --- |
| `SHOW640/N01WATCH.BMP` | 未来腕表 | 1280×720 |
| `SHOW640/N02DRINK.BMP` | 轻盈能量饮品 | 1280×720 |
| `SHOW640/N03CHIP.BMP` | 芯片之美 | 640×480 |
| `SHOW640/N04RAIN.BMP` | 强降雨提示 | 1920×800 |
| `SHOW640/N05LANE.BMP` | 辅助驾驶演示 | 1920×1080 |
| `SHOW640/N06LEARN.BMP` | 数字课堂 | 640×360 |

将配套的 `TRACKS.BIN` 和四个 WAV 文件放在 TF 卡根目录，保留原清单：

| 文件 | 曲目 |
| --- | --- |
| `TRACK05.WAV` | Resonance |
| `TRACK03.WAV` | Nightcall |
| `TRACK02.WAV` | Future Club |
| `TRACK06.WAV` | Heat Waves |

图片须在卡上连续分配；构建脚本会检查文件内容、大小和连续性。换卡或重新复制图片后，需要按下一节重新核验卡上的位置并生成位流。完整媒体规格见 [project/ip/sources.json](project/ip/sources.json)。

## 5. 编译与生成位流

将工程解压到本地目录，在仓库根目录打开 PowerShell。先检查工程文件：

```powershell
python tools/build.py --check
```

正常输出为 `Checked 36 frozen project inputs and all local includes`。

把准备好的 TF 卡通过读卡器连接电脑，确认其实际盘符。以管理员身份打开 PowerShell，进入仓库根目录，执行：

```powershell
python tools/build.py --td-bin "<本机TD安装目录>/bin" --run-name new_card --card-drive "<实际盘符>:" --generate-bit
```

- 将 `<本机TD安装目录>` 换成本机 TD 6.2.1 的安装位置，`bin` 目录中应有 `td_commands_prompt.exe`。
- 将 `<实际盘符>:` 换成资源管理器中显示的 TF 卡盘符，例如 `E:`。
- `new_card` 是本次构建目录名；再次编译时换用新名字，例如 `new_card_2`。

脚本只读 TF 卡，核验六张图片后，在构建副本中设置它们的起始扇区，再完成综合、布局布线和位流生成。看到 `Route complete` 和输出目录后，可在以下位置找到结果：

```text
build/new_card/project/probe.bit       用于下载的位流
build/new_card/project/probe.al        本次构建的 TD 工程
build/new_card/project/probe.timing    时序报告
build/new_card/result.json            构建结果
```

使用配套原 TF 卡且卡上文件与分配未改变时，可省略 `--card-drive "<实际盘符>:"`。省略 `--generate-bit` 则只执行综合和布局布线。

## 6. 下载与启动

1. 安全弹出 TF 卡，关闭开发板电源，将 TF 卡插入板上卡槽。
2. 将开发板 **HDMI_B** 接到显示设备，并连接扬声器、耳机或音箱；用 **USB-JTAG** 接口连接电脑。
3. 将 SW1、SW2、SW3 均置为 `0`，打开开发板电源。
4. 在 TD 中打开 **Tools → BitWriter**，点击 **Refresh**，确认识别到 `0:EG4S20BG256`。
5. 点击 **Add**，选择本次生成的 `build/new_card/project/probe.bit`，下载模式选择 **Program SRAM**，点击 **Run**。
6. 下载完成后短按 **KEY1**，等待图片缓存加载，屏幕出现腕表画面并开始播放背景音乐。

Program SRAM 用于临时运行，断电后失效。确认图像、声音和按键操作正常后，可在 BitWriter 中选择 **Program Flash**，将同一镜像写入 16 Mbit 配置 Flash 并完成校验。写入结束后正常断电、重新上电，即可独立启动。

## 7. 按键与菜单

| 控件 | 功能 |
| --- | --- |
| KEY1 | 系统复位，重新读取媒体并恢复默认参数 |
| SW1 | `1` 开启自动轮播，`0` 关闭 |
| SW2 | `1` 打开中文菜单，`0` 关闭 |
| SW3 | `1` 进入四季动态场景，`0` 返回 TF 图片 |
| KEY2 | 菜单中进入参数调整；再次按下确认并返回上一级 |
| KEY3 | 菜单关闭时切到下一张图片或下一个场景；菜单中选择下一项或增大参数 |
| KEY4 | 菜单关闭时切到上一张图片或上一个场景；菜单中选择上一项或减小参数 |

菜单依次包含：亮度、音量、对比度、滚动字幕、音频可视化、自动轮播周期、当前图片、音频选择。

默认亮度 50、音量 50、对比度 100，轮播周期 5 秒，字幕和音频可视化关闭。打开 SW2 后用 KEY3／KEY4 选择菜单项，按 KEY2 进入调整，再用 KEY3／KEY4 修改，按 KEY2 返回。“当前图片”项在选定图片后按 KEY2 确认切换；动态场景下该项不可选，使用 SW3 返回图片模式后即可操作。

可按以下顺序体验作品：手动查看六张图片 → 打开 SW1 观察轮播与转场 → 打开 SW3 查看四季动态场景 → 打开 SW2 调节参数、选曲并开启字幕和音频可视化。

## 8. 技术文档

系统结构、模块设计和功能说明见 [作品技术文档](report/design_report.pdf)。可编辑入口为 [report/template.tex](report/template.tex)，正文位于 `report/body/`，配图位于 `report/figures/`。

修改文档后，在安装了 XeLaTeX 的电脑上进入 `report/`，运行两次编译以更新目录：

```powershell
xelatex template.tex
xelatex template.tex
```

相关组件许可证见 [LICENSES](LICENSES/)。

## 9. 常见问题

| 现象 | 处理方法 |
| --- | --- |
| 找不到 `td_commands_prompt.exe` | 检查 `--td-bin` 是否指向本机 TD 6.2.1 的 `bin` 目录 |
| 读卡时提示拒绝访问 | 使用管理员 PowerShell，并确认 TF 卡实际盘符 |
| 提示图片内容不符或文件不连续 | 按第 4 节使用配套素材重新准备 TF 卡，再执行带 `--card-drive` 的构建命令 |
| 提示构建目录已存在 | 修改 `--run-name`，使用一个新目录名 |
| BitWriter 无法识别器件 | 检查板卡电源、USB-JTAG 连接和下载驱动，再点击 Refresh |
| 下载后没有出现图片或音乐 | 确认 TF 卡和位流对应，短按 KEY1 重新加载；显示设备切到已连接的 HDMI 输入，并检查其音量和音频输出 |
