#!/bin/zsh
# 按 11-13 定下的设计语言（暖灰 + 玫瑰红），出「双语文字稿 + 翻译风格 + 剪贴板提示」的图。
cd "$(dirname "$0")"
gen() {
  local name=$1; local prompt=$2
  [ -f "$name.png" ] && return
  local t0=$(date +%s)
  codex exec --skip-git-repo-check --ephemeral -c 'model_reasoning_effort="low"' -C "$PWD" -s workspace-write \
    "当前目录的 ref_current.jpg 是这款 macOS 应用「豆仓」已经定稿的录音页截图，ui_materials.png 是素材库页的设计稿。请先看这两张图，然后使用内置的 image_gen 工具（把它们一起传入，设计语言必须完全一致：暖灰底、白色圆角卡片、玫瑰红 #F43F5E 强调色、深色选中的小筛选块）生成一张 16:10 横向的高保真 UI 设计稿（正视图、不要透视）：$prompt 生成后把最终图片复制到当前目录，命名为 $name.png，然后只回复文件名。" < /dev/null > "$name.log" 2>&1
  echo "$name $(( $(date +%s) - t0 ))s $([ -f $name.png ] && echo ok || echo FAIL)"
}
S="界面文字是简体中文（英文原文部分是英文），清晰可读、没有乱码。不要蓝色、紫色。简洁，不加多余装饰。"
gen ui_translate "【素材的文字稿页，双语对照】三栏布局和素材库设计稿一样（侧栏「素材」选中，中间素材列表第一条「How I Built a $1M App Alone」被选中，小字「YouTube · @indiehacker · 12:40」）。右边详情：顶部「YouTube · @indiehacker」标签和日期、右上角一排图标按钮，标题「How I Built a \$1M App Alone」，右侧页签「纪要 / 文字稿 / 改写」中「文字稿」被选中。页签下方一条工具行：左边一个三段小切换「原文 / 双语 / 译文」（「双语」选中，白底），右边一个玫瑰红小按钮「翻译」带下拉箭头，按钮左边灰字「简体中文 · 科技」。下面是双语文字稿卡片：每一句一组，左边灰色时间戳「0:00」「0:14」「0:31」，右边先是英文原句（深色），紧接着下一行是中文译文（暖灰色、略小、左边一条很细的玫瑰红竖线），例如「So the first version took me about three weekends.」下面「第一个版本大概花了我三个周末。」。再画一个从「翻译」按钮展开的小弹出面板（白色圆角卡片、阴影）：标题「翻译成」下面一个下拉「简体中文」；标题「风格」下面一排小块「通用 / 科技 / 小说 / 学术文献 / 新闻 / 社交论坛 / 口播字幕 / 自定义」（「科技」深色选中）；底部小灰字「用整理纪要的那个云端模型来翻译」和玫瑰红按钮「开始翻译」。窗口顶部正中还浮着一条白色圆角提示条：左边玫瑰红链接图标，文字「剪贴板里有一条 YouTube 链接」，右边玫瑰红文字按钮「导入」和灰色「忽略」。$S"
