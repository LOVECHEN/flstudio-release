#!/usr/bin/env bash
# 镜像单个平台轨的最新 FL Studio 官方安装包到 GitHub Release。
# 由 mirror.yml 用环境变量驱动：
#   REDIRECT  官方稳定重定向 URL（跟随后落到带版本号的直链）— 来自仓库 Secret REDIRECT_MAC/WIN
#   TRACK     tag 前缀 / 轨名（mac | win）
#   PLATFORM  展示用平台名（macOS | Windows x64）
#   LATEST    该轨新建的 Release 是否标记为 /releases/latest（true|false）
#   GH_TOKEN  github.token（gh 用）
set -euo pipefail

: "${REDIRECT:?缺少 REDIRECT（检查仓库 Secret REDIRECT_MAC / REDIRECT_WIN 是否已配置）}"
: "${TRACK:?}"; : "${PLATFORM:?}"; : "${LATEST:=false}"
repo="$GITHUB_REPOSITORY"
UA='Mozilla/5.0'

# 运行期动态日志打码：把源 URL 注册成 GitHub 掩码，之后任何路径
# （成功 / 解析失败 / curl 报错 / 重试）里出现都会被替换成 ***。
# 三层全覆盖，确保「完整 URL」被遮而不只是域名：
#   ① 完整 URL（含 scheme）        https://host/path...
#   ② 无 scheme 的 host+path 整段  host/path...   ← 防工具打印裸 URL 时只遮到域名
#   ③ 仅主机名                     host
# 掩码值一律从 Secret / 运行时解析得来，不把主机名写进仓库文件。
mask () {
  local u="${1:-}"; [ -n "$u" ] || return 0
  printf '::add-mask::%s\n' "$u"                       # ① 完整 URL
  local noscheme="${u#*://}"
  [ "$noscheme" != "$u" ] && printf '::add-mask::%s\n' "$noscheme"   # ② host+path 整段
  local host="${noscheme%%/*}"
  [ -n "$host" ] && [ "$host" != "$noscheme" ] && printf '::add-mask::%s\n' "$host"  # ③ 仅主机
}
mask "$REDIRECT"            # 源 redirect（GitHub 已按 secret 打码，这里连主机名一起补掉）

# 1) HEAD 跟随重定向拿最终直链与文件名（不下载正文）。url_effective 只进变量不落日志，
#    拿到后立刻打码，后续 curl 报错里的直链也会被 *** 掉。
eff="$(curl -fsSL -I -o /dev/null -A "$UA" -w '%{url_effective}' "$REDIRECT")"
mask "$eff"
file="$(basename "$eff")"
ver="$(printf '%s' "$file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ -n "$ver" ] || { echo "无法解析版本号（源不可达或格式变化），异常退出"; exit 1; }

marketing="${ver%.*}"       # 26.1.6
build="${ver##*.}"          # 5406 / 5639
tag="${TRACK}-${ver}"
echo "轨=$TRACK 版本=$ver"   # 只记录版本，不回显任何 URL

# 2) 已归档则跳过
if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
  echo "skip $tag（已存在）"; exit 0
fi

# 3) 下载官方原版（断点续传 + 重试）
echo "::group::下载 $file"
curl -fL --retry 6 --retry-delay 10 --retry-all-errors -C - -A "$UA" -o "$file" "$eff"
sz="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file")"
echo "大小 $sz 字节"
[ "$sz" -gt 100000000 ] || { echo "文件异常小（$sz），疑似下载失败"; exit 1; }
sha256sum "$file" > SHA256SUMS.txt
echo "::endgroup::"

# 4) 发布说明
notes="$(printf '## FL Studio %s · %s\n\n| | |\n|---|---|\n| **产品** | FL Studio（Image-Line） |\n| **版本** | %s（marketing %s / build %s） |\n| **平台** | %s |\n| **文件** | `%s` |\n\n官方原版安装包，**未经任何修改**，逐字节镜像自 Image-Line 官方源，仅作下载加速 / 归档留档。此安装包同时是 FL Studio 试用版与正式版（用授权解锁）。\n\n**SHA-256**\n```\n%s\n```\n' \
  "$marketing" "$PLATFORM" "$ver" "$marketing" "$build" "$PLATFORM" "$file" "$(cat SHA256SUMS.txt)")"

latest_flag="--latest=false"; [ "$LATEST" = "true" ] && latest_flag="--latest=true"

# 5) 两阶段发布：先建空 Release，再带重试上传大资产（1GB+ 上传偶发抖动）
gh release create "$tag" -R "$repo" \
  --title "$PLATFORM · FL Studio $ver" --notes "$notes" $latest_flag
ok=
for i in 1 2 3 4 5; do
  if gh release upload "$tag" "$file" SHA256SUMS.txt --clobber -R "$repo"; then ok=1; break; fi
  echo "上传失败，第 $i 次重试…"; sleep 20
done
[ -n "$ok" ] || { echo "资产上传多次失败"; exit 1; }

rm -f "$file" SHA256SUMS.txt
echo "created $tag"
