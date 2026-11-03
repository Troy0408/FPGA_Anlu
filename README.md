# 赛博美学数字艺术多媒体交互画框

2026 年全国大学生嵌入式芯片与系统设计竞赛 FPGA 创新设计赛道，安路科技选题一“基于安路 EG4S20 的 HDMI 多媒体播放系统”。

作品基于 HX4S20C 开发板，在同一套 FPGA 系统中播放 TF 卡里的图片和背景音乐，并实时生成四季赛博城市画面，画面和声音都经 HDMI 输出。用户可以切换图片与动态场景，调节亮度、对比度和音量，开启中文字幕与音频可视化。镜像固化后上电即可运行，播放时不需要电脑。

配套 TF 卡素材约 207 MB，超出作品压缩包的大小限制，因此只放在 GitHub 仓库 <https://github.com/Troy0408/FPGA_Anlu> 的 `tf_card/` 目录中，获取方法见第 4 节。压缩包内的其他内容与仓库一致。

## 1. 作品功能

| 功能 | 说明 |
| --- | --- |
| 图片播放 | 读取 TF 卡根目录中的 24 位非压缩 BMP，最多六张，经 SDRAM 缓存后显示；支持手动切换和自动轮播 |
| 图像缩放 | 双线性等比缩放，适配 640×360 画布并居中补黑；HDMI 输出 1280×720、60 Hz 视频 |
| 画面转场 | 切换图片时淡出、淡入；自动轮播周期可选 3、5、15 秒 |
| 四季动态场景 | 雨夜霓虹、黄昏雷云、薄雾深夜、飘雪清晨；天气、灯光、交通与人物由 FPGA 实时生成 |
| 音乐播放 | 读取根目录中的 48 kHz、16 位、双声道 PCM WAV，通过 HDMI 输出；使用配套素材时可在菜单中选择四首曲目 |
| 字幕与音频可视化 | 七条中文字幕随图片或场景切换；音频幅度柱随实际播放样本变化 |
| 实时交互 | 中文菜单调节亮度、对比度、音量、轮播周期，并控制字幕、音频可视化、图片选择和选曲 |

## 2. 运行环境

| 项目 | 要求 |
| --- | --- |
| 开发板 | 安路 HX4S20C，FPGA 型号 EG4S20BG256 |
| 开发工具 | Anlogic TD 6.2.1，完整版本 6.2.168116，安装 USB-JTAG 下载驱动 |
| 电脑 | Windows，Python 3.10 或以上版本；构建脚本使用 Python 标准库，无需安装额外 Python 包 |
| 存储 | FAT32 格式 TF 卡及读卡器；配套图片和音乐见仓库 `tf_card/` 目录 |
| 显示与声音 | 支持 1280×720、60 Hz 的 HDMI 显示设备；使用显示设备扬声器或其音频输出口连接耳机、音箱 |
| 连接线 | USB-JTAG 数据线、HDMI 线 |

Python 只在电脑端构建和读卡核验时使用，作品运行时不需要。技术文档直接打开 PDF 阅读，无需安装 LaTeX。

## 3. 工程目录

```text
FPGA_Anlu/
├─ bitstream/
│  └─ probe.bit                已通过时序检查和上板测试的位流，可直接下载
├─ project/
│  ├─ probe.al                 TD 工程，顶层模块 top
│  ├─ top.v                    顶层连接、时钟、复位和交互控制
│  ├─ sd.v                     TF 读卡、根目录查找、BMP 解析、缩放加载和音乐读取
│  ├─ root_catalog.vh          FAT32 根目录扫描与 BMP、WAV 文件头检查
│  ├─ video.v                  帧缓存、画面处理、菜单、字幕和音频输出
│  ├─ ip.v                     PLL、FIFO 等模块
│  ├─ build.tcl                完整综合、布局布线流程
│  ├─ fonts/                   基础字模
│  ├─ scene/                   四季场景、字幕、菜单和刷新控制
│  ├─ probe/                   720p 合成、扫描输出和时钟模块
│  ├─ reference/               双线性缩放核
│  └─ ip/                      工程文件校验和媒体规格清单
├─ user_source/                厂商 IP 引用的配置头
├─ tools/                      构建、读卡核验和仿真回归脚本
├─ report/                     技术文档 PDF（仓库中另含 LaTeX 源码和配图）
├─ tf_card/                    配套 TF 卡素材（仅在 GitHub 仓库中）
└─ LICENSES/                   相关组件许可证
```

TD 工程入口为 [project/probe.al](project/probe.al)，顶层文件为 [project/top.v](project/top.v)。编译时请使用第 5 节的构建命令，脚本会加载完整的时序约束和布局布线配置。解压后保持上述目录层级即可使用，IP 文件均已包含在内。

## 4. TF 卡素材准备

TF 卡使用 FAT32 格式。取放 TF 卡、连接 HDMI 和 USB-JTAG 前，先关闭开发板电源。所有图片和音乐直接放在 TF 卡**根目录**，不要放进文件夹。上电或短按 KEY1 时，系统按目录顺序查找根目录中的文件，换卡后无需重新编译。

**配套展示素材**：在 GitHub 仓库页面点击 **Code → Download ZIP** 下载整个仓库，或执行 `git clone https://github.com/Troy0408/FPGA_Anlu.git`，然后把 `tf_card/` 目录中的全部文件复制到 TF 卡根目录，保持以下文件名：

| 文件 | 内容 | 输入尺寸 |
| --- | --- | --- |
| `N01WATCH.BMP` | 未来腕表 | 1280×720 |
| `N02DRINK.BMP` | 轻盈能量饮品 | 1280×720 |
| `N03CHIP.BMP` | 芯片之美 | 640×480 |
| `N04RAIN.BMP` | 强降雨提示 | 1920×800 |
| `N05LANE.BMP` | 辅助驾驶演示 | 1920×1080 |
| `N06LEARN.BMP` | 数字课堂 | 640×360 |
| `TRACKS.BIN` | 曲目清单 | — |
| `TRACK06.WAV` | Heat Waves | — |
| `TRACK02.WAV` | Future Club | — |
| `TRACK03.WAV` | Nightcall | — |
| `TRACK05.WAV` | Resonance | — |

卡上恰好是这六张图片时，系统按 N01 到 N06 的顺序播放，并显示每张图片对应的滚动字幕；卡上恰好是 `TRACKS.BIN` 和这四个 WAV 时，可在菜单中选曲。

**自备素材**：符合以下格式的图片和音乐同样可以直接放入根目录播放：

- 图片：24 位未压缩 BMP，宽不超过 1920、高不超过 1080，最多读取 6 张。
- 音乐：48 kHz、16 位、立体声 PCM 格式 WAV，最多 5 首。
- 文件须在卡上连续存放，不连续、格式不符或超出数量的文件会被跳过。复制到刚格式化的卡上的文件通常是连续的。

根目录中有配套素材以外的图片，或配套图片不全时，菜单中的“当前图片”和“滚动字幕”显示为灰色，图片按目录顺序轮流显示；四季动态场景（SW3）的字幕不受影响。有配套素材以外的 WAV，或配套音乐不全时，“音频选择”显示为灰色，系统循环播放根目录中第一首有效的 WAV。

## 5. 编译与生成位流

[bitstream/probe.bit](bitstream/probe.bit) 是已生成的位流，只需体验作品时可跳过本节，直接按第 6 节下载。该位流使用布局种子 1 构建，SHA-256 为 `18a28b817905e998b74eef271e1d612a4d69bb66b46c144137cb9fb1ca7b9a3d`。

如需从源码重新生成，将工程解压到本地目录，在工程根目录打开 PowerShell。先检查工程文件：

```powershell
python tools/build.py --check
```

正常输出为 `Checked 37 frozen project inputs and all local includes`。然后执行：

```powershell
python tools/build.py --td-bin "<本机TD安装目录>/bin" --run-name new_build --place-seed 1 --generate-bit
```

- 将 `<本机TD安装目录>` 换成本机 TD 6.2.1 的安装位置，`bin` 目录中应有 `td_commands_prompt.exe`。
- `new_build` 是本次构建目录名；再次编译时换用新名字，例如 `new_build_2`。
- `--place-seed 1` 与 `bitstream/probe.bit` 使用的布局种子相同，参数会记入构建结果。省略时使用默认种子 3，本版用该种子也能完成构建。

位流不依赖 TF 卡内容，构建时无需连接 TF 卡。看到 `Route complete` 和输出目录后，可在以下位置找到结果：

```text
build/new_build/project/probe.bit       用于下载的位流
build/new_build/project/probe.al        本次构建的 TD 工程
build/new_build/project/probe.timing    时序报告
build/new_build/result.json            构建结果
```

省略 `--generate-bit` 则只执行综合和布局布线。

修改读卡或菜单逻辑后，可在已将 ModelSim 的 `vlib`、`vlog`、`vsim` 加入 PATH 的环境中运行回归：

```powershell
python tools/test_media_catalog.py
```

该命令检查 FAT32 目录、文件格式、连续簇、数量限制、菜单与字幕，以及音乐播放和切换，结果保存在 `build/media_catalog_tests/`。加上 `--pixels` 会再运行两组完整画布的 BMP 缩放仿真，耗时较长。仿真和构建通过后，仍需上板核验实际的 TF 卡、HDMI 图像、声音和按键。

## 6. 下载与启动

1. 安全弹出 TF 卡，关闭开发板电源，将 TF 卡插入板上卡槽。
2. 将开发板 **HDMI_B** 接到显示设备，并连接扬声器、耳机或音箱；用 **USB-JTAG** 接口连接电脑。
3. 将 SW1、SW2、SW3 均置为 `0`，打开开发板电源。
4. 在 TD 中打开 **Tools → BitWriter**，点击 **Refresh**，确认识别到 `0:EG4S20BG256`。
5. 点击 **Add**，选择 `bitstream/probe.bit`（自行编译时选择 `build/new_build/project/probe.bit`），下载模式选择 **Program SRAM**，点击 **Run**。
6. 下载完成后短按 **KEY1**，等待根目录查找和图片缓存加载，屏幕出现第一张图片并开始播放背景音乐。

Program SRAM 只用于临时运行，断电后失效。确认图像、声音和按键正常后，可在 BitWriter 中选择 **Program Flash**，把同一镜像写入 16 Mbit 配置 Flash 并完成校验。之后断电再上电，开发板即可独立启动。

## 7. 按键与菜单

| 控件 | 功能 |
| --- | --- |
| KEY1 | 系统复位，重新查找 TF 卡根目录的媒体并恢复默认参数 |
| SW1 | `1` 开启自动轮播，`0` 关闭 |
| SW2 | `1` 打开中文菜单，`0` 关闭 |
| SW3 | `1` 进入四季动态场景，`0` 返回 TF 图片 |
| KEY2 | 菜单中进入参数调整；再次按下确认并返回上一级 |
| KEY3 | 菜单关闭时切到下一张图片或下一个场景；菜单中选择下一项或增大参数 |
| KEY4 | 菜单关闭时切到上一张图片或上一个场景；菜单中选择上一项或减小参数 |

菜单依次包含：亮度、音量、对比度、滚动字幕、音频可视化、自动轮播周期、当前图片、音频选择。

默认亮度 50、音量 50、对比度 100，轮播周期 5 秒，字幕和音频可视化关闭。打开 SW2 后用 KEY3／KEY4 选择菜单项，按 KEY2 进入调整，再用 KEY3／KEY4 修改，按 KEY2 返回。“当前图片”项选定图片后按 KEY2 确认切换；动态场景下该项不可选，用 SW3 返回图片模式后即可操作。卡上不是完整的配套素材时，“当前图片”“滚动字幕”或“音频选择”显示为灰色，规则见第 4 节。

可按以下顺序体验作品：手动查看六张图片 → 打开 SW1 观察轮播与转场 → 打开 SW3 查看四季动态场景 → 打开 SW2 调节参数、选曲并开启字幕和音频可视化。

## 8. 技术文档

系统结构、模块设计和功能说明见 [作品技术文档](report/design_report.pdf)。

文档的 LaTeX 源码只在 GitHub 仓库中：入口为 `report/template.tex`，正文在 `report/body/`，配图在 `report/figures/`。修改后在安装了 XeLaTeX 的电脑上进入 `report/`，编译两次以更新目录，再把生成的 `template.pdf` 复制为 `design_report.pdf`：

```powershell
xelatex template.tex
xelatex template.tex
Copy-Item template.pdf design_report.pdf
```

相关组件许可证见 [LICENSES](LICENSES/)。

## 9. 常见问题

| 现象 | 处理方法 |
| --- | --- |
| 找不到 `td_commands_prompt.exe` | 检查 `--td-bin` 是否指向本机 TD 6.2.1 的 `bin` 目录 |
| 某张图片或某首音乐没有出现 | 检查文件是否在根目录、格式是否符合第 4 节要求；把文件复制到重新格式化的 FAT32 卡上，以保证连续存放 |
| 提示构建目录已存在 | 修改 `--run-name`，使用一个新目录名 |
| BitWriter 无法识别器件 | 检查板卡电源、USB-JTAG 连接和下载驱动，再点击 Refresh |
| 下载后没有出现图片或音乐 | 确认文件放在 TF 卡根目录且格式符合第 4 节，短按 KEY1 重新加载；显示设备切到已连接的 HDMI 输入，并检查其音量和音频输出 |
| 菜单中“当前图片”“滚动字幕”或“音频选择”是灰色 | 卡上有配套素材以外的文件，或配套素材不全，属于正常行为；换回完整的配套素材并短按 KEY1 即可恢复 |
