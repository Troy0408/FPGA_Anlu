# 赛博美学数字艺术多媒体交互画框

2026 年全国大学生嵌入式芯片与系统设计竞赛，FPGA 创新设计赛道，安路科技选题一。平台为 HX4S20C / EG4S20BG256。

本仓库只保留提交所需工程、源码及技术文档。图片和音乐另行提供。

| 入口 | 内容 |
| --- | --- |
| `project/probe.al` | TD 工程，顶层 `top`；包含 RTL、头文件、内置字库和场景 ROM、引脚／时序约束、必要厂商 IP；`user_source/` 保留厂商相对 include 必需的配置头 |
| `project/build.tcl` | 原固化版本的完整构建流程，保留附加时序约束、精确 CDC 对象检查、seed 3 和布线后 hold 修复 |
| `report/design_report.pdf` | 当前 39 页技术文档；实物照片和工具截图仍有占位 |
| `report/template.tex` | 技术文档 XeLaTeX 入口；`body/` 和 `figures/` 为其全部本地依赖 |
| `project/ip/sources.json` | 构建输入校验、来源和单独交付的媒体文件规格 |
| `LICENSES/` | 所用字体和缩放核必须保留的许可证 |

使用 Windows、Python 3.10+ 和 TD **6.2.1**（原版本 `6.2.168116`），在本仓库根目录执行。`--td-bin` 使用本机实际安装目录；也可设置 `TD_BIN`。

```powershell
python tools/build.py --check
python tools/build.py --td-bin "<本机TD安装目录>/bin" --run-name first_build
```

输出统一写入 `build/first_build/`，不覆盖提交的工程。脚本实际调用 `td_commands_prompt.exe`，检查完成标记、输出数据库和数值时序。需要生成位流时为第二条命令增加 `--generate-bit`；该步骤不下载板卡或写 Flash。不要只按 GUI 默认选项编译 `.al`：完整配置与附加 SDC 由 `build.tcl` 执行。

源码直接取自 2026-10-30 最终固化工程的构建输入，原镜像 SHA-256 为 `33d0b5261a61d8ce3938d22935454ac9271717502599f679872a1dd1e1669b22`。工程文件仅将缓存的绝对位置改为相对路径；RTL／IP／约束原始字节保留。重新布局布线不保证生成相同位流。原工程的 PHY-7002、完整 CDC／电气签核及热下载首启问题仍按开发仓库记录保留，本精简包不新增硬件验收结论。

TF 使用 FAT32。六张另交的 BMP 按 `project/ip/sources.json` 中的文件名放入 `SHOW640`，图片应连续分配。原顶层中的物理 LBA 对应原测试卡；换卡或重新复制素材后，在管理员 PowerShell 中对**实际卡盘符**重新只读核验，再构建：

```powershell
python tools/build.py --td-bin "<本机TD安装目录>/bin" --run-name new_card --card-drive "<实际盘符>:"
```

此命令只读卡，在构建副本中改写六个图像起始扇区；源工程不变。卡上的文件或分配变化后需重做。音乐根目录沿用另交的 `TRACKS.BIN` 及 `TRACK05.WAV`、`TRACK03.WAV`、`TRACK02.WAV`、`TRACK06.WAV`，对应 Resonance、Nightcall、Future Club、Heat Waves；WAV 为 48 kHz、16 位、双声道 PCM。构建不需要媒体文件；实物播放需要这些另交素材。TF 取放前断电。

KEY1 复位；SW1 自动轮播；SW2 中文菜单；SW3 动态场景；KEY2 进入／返回菜单；KEY3／KEY4 在菜单中调整参数，关闭菜单时前后切图／场景。字幕及音频可视化默认关闭，可在菜单中开启。

技术文档使用 XeLaTeX，在 `report/` 下运行 `xelatex template.tex` 两次更新目录。正文、样式和配图保持原稿；排版改自 [FPGA-course 固定版本模板](https://github.com/zhouxzh/FPGA-course/tree/86024f0c4e259a62bd2c947b712558d07429b6ec)，保留 KIALA9 署名。PDF 与所附源码输入逐文件核对一致。

RTL 复用官方例程 4／5，并包含团队图像解析／缩放适配、帧缓存／刷新、音乐／菜单／参数、中文字幕和实时场景等修改。四份厂商保护 IP 与原包哈希一致，按原厂权利声明使用；并非团队原创 IP。缩放核改自 David Kronstein 的 Video Stream Scaler（`freecores/video_stream_scaler@8063961cee8ac56934ca647c9b20ad2c8c5740bf`），源代码及 LGPL-2.1-or-later 声明保留；有限中文字形源于 GNU Unifont 18.0.01，选择 SIL OFL-1.1。字体版权为 Roman Czyborra、Paul Hardy、Qianqian Fang、Andrew Miller、Johnnie Weaver、David Corbett、Ælla Chiana Moskopp、Rebecca Bettencourt、Minseo Lee、Ho-Seok Ee 等（1998–2026）。ASCII 字模的 MIT 声明保留在源码内；四季城市构图改编自用户提供的 ChatGPT HTML 参考。
