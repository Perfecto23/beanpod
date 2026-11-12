#!/bin/zsh
# 豆仓（仓鼠）建模用四视图：先以概念图为参考出正面，再以正面为参考出左、右、背。
cd "$(dirname "$0")"
gen() {
  local name=$1; local ref=$2; local prompt=$3
  [ -f "$name.png" ] && return
  local t0=$(date +%s)
  codex exec --skip-git-repo-check --ephemeral -c 'model_reasoning_effort="low"' -C "$PWD" -s workspace-write \
    "使用内置的 image_gen 工具生成一张方形图片：$prompt 生成后把最终图片复制到当前目录，命名为 $name.png，然后只回复文件名。" -i "$ref" < /dev/null > "$name.log" 2>&1
  echo "$name $(( $(date +%s) - t0 ))s $([ -f $name.png ] && echo ok || echo FAIL)"
}
D="角色「豆仓」：一只圆滚滚的珍珠白小仓鼠，腮帮子鼓鼓的，圆圆的小耳朵内侧是淡粉色，黑亮的豆豆眼带高光，粉色小鼻子，微笑的小嘴，几根细胡须，粉色的小手和小脚，脖子上挂着一副白色头戴耳机（耳罩外圈有一圈天蓝色细线），身后有一个很小的圆尾巴。"
Q="质感是高级植绒潮玩手办：表面是很短很细的绒，轮廓干净圆润，不要长毛、不要飞散的毛发。纯白背景，无阴影，无文字无水印，正交视角没有透视变形，角色完整入画、垂直居中。"
gen front concept.png "参考图 concept.png 是角色的概念图。画同一个角色的正面建模设定图。$D 姿势改成标准的建模站姿：正对镜头站直，左右完全对称，双臂向两侧张开约 30 度、手里不拿任何东西，双脚分开站稳。$Q"
S="参考图 front.png 是角色的正面建模设定图。画同一个角色，$D 所有特征、比例、配色、耳机的位置都和参考图保持一致，同样的站姿（双臂向两侧张开约 30 度、双脚分开），同样大小、同样位置。$Q"
gen left front.png "$S 这次画正左侧视图（角色身体朝向画面左侧，纯侧面 90 度）。" &
gen right front.png "$S 这次画正右侧视图（角色身体朝向画面右侧，纯侧面 90 度）。" &
gen back front.png "$S 这次画正背面视图（看到后脑勺、两只耳朵的背面、耳机的头梁绕在后颈、背后的小圆尾巴）。" &
wait
