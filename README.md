# 豆仓 BeanPod

一个原生 macOS App，用来在电脑上管理 AI 录音豆（型号 D3200）：把录音拉到本地、播放、转成文字。全程在本机完成，不经过任何云服务。

> 非官方项目，与设备厂商及其合作方没有任何关系。仅用于管理你自己设备上的你自己的录音。

## 能做什么

**设备**
- 搜索并连接录音豆，之后自动回连；查看电量、存储、固件
- 在电脑上开始、暂停录音；把录音下载到 Mac 并自动解密成通用的 `.ogg`

**转写**
- 默认用 [Qwen3‑ASR 0.6B](https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF) 经 llama.cpp 在本机转写，带时间戳，点任意一句可以从那里开始听
- 没装模型时自动改用系统自带的语音识别；两种都不上传录音

**整理**
- 自动判断场景：会议、访谈、销售、沟通、电话、自媒体、大会、课程、灵感，每种场景有自己的纪要栏目（比如销售会抽出客户需求、异议、预算与决策人、下一步）
- 可以设定自己的职业，整理时的侧重点随之变化
- 生成标题、摘要、分栏要点、待办、标签、人物
- 分析模型可配置：任何兼容 OpenAI 接口的服务都行。用本机的 Ollama 或 LM Studio 时，文字稿也不出这台电脑

**总览与知识库**
- 总览：录音数量与时长、近 14 天趋势、场景分布、未完成待办、常出现的话题
- 知识库：所有录音的要点自动汇总，可按场景和话题筛选、全文搜索（命中文字稿时可直接跳到那一句），也可以直接提问，回答会标出依据的录音
- 导出为 Markdown，每条录音一个文件，带 frontmatter，可直接放进 Obsidian

没有做：Wi‑Fi 批量导出、边录边转写、说话人区分、固件升级、绑定与解绑。

## 使用前要知道

- 录音豆同一时间只连一台设备。手机连着时电脑搜不到，先关掉手机蓝牙。
- 蓝牙下载不快：实测 26 秒的录音约 7 秒传完，一小时的录音要十几分钟。
- 只在固件 04.92 上测过。

## 构建

需要 macOS 14 以上、Xcode 26、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
```

```bash
xcodebuild -project BeanPod.xcodeproj -scheme BeanPod -derivedDataPath build build
```

```bash
open build/Build/Products/Debug/BeanPod.app
```

核心逻辑的测试：

```bash
swift test
```

## 代码结构

转写需要 llama.cpp（`brew install llama.cpp`）和模型文件，模型可以在 App 的设置里一键下载。

```
Sources/BeanKit/   协议与音频，不依赖界面，可单独测试
  Frame.swift        帧的编码、校验、重组
  Commands.swift     命令
  Models.swift       设备信息、录音列表的解析
  Crypto.swift       密钥协商、文件解密、切片解析
  OggOpus.swift      把裸 Opus 帧装进 Ogg 容器
  OpusDecoder.swift  解码成 WAV
App/               SwiftUI 界面与业务
  BLEClient.swift    蓝牙连接
  BeanStore.swift    设备状态、录音库
  Pipeline.swift     转写 → 整理的流水线，知识库检索、问答、导出
  QwenASR.swift      本机 Qwen3‑ASR（llama-server）
  Analyzer.swift     场景判断与纪要生成
  Domain.swift       场景、职业、录音的数据结构
docs/PROTOCOL.md   协议笔记，逐条标注了哪些是真机实测、哪些尚未独立核实
```

录音保存在 `~/Library/Application Support/BeanPod/Recordings/`，运行日志在 `~/Library/Logs/BeanPod.log`。

## 致谢与来源

协议方面参考了 [tacshi/Soundcore](https://github.com/tacshi/Soundcore) 的协议笔记，它是第一个把这台设备的协议整理出来的项目。本项目的代码是用 Swift 独立编写的，没有使用该项目的代码；在真机上核对时发现并修正了其中几处字段含义，详见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

本仓库不包含任何厂商的代码、固件或密钥。

## 许可证

[MIT](LICENSE)
