#!/bin/bash

# 从Classified仓库同步总榜数据到当前仓库
# 将总榜数据格式转换为适合当前仓库的格式
#
# 使用方法:
#   ./scripts/sync_from_classified.sh      # 正常执行同步
#   ./scripts/sync_from_classified.sh --safe  # 安全模式，只检查不执行

set -e  # 遇到错误立即退出

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 错误处理函数
handle_error() {
    log "错误: $1"
    exit 1
}

# 格式化星数函数
format_stars() {
    local stars=$1
    if [[ $stars -ge 1000 ]]; then
        # 转换为k格式，保留1位小数
        echo "$(echo "scale=1; $stars/1000" | bc 2>/dev/null || echo $((stars/1000)))k"
    else
        echo "$stars"
    fi
}

# 格式化日期函数
format_date() {
    local date_str=$1
    # 转换 YYYY-MM-DD 到 MM/DD 格式
    if [[ $date_str =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then
        echo "${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
    else
        echo "$date_str"
    fi
}

# 简化描述函数
simplify_description() {
    local desc=$1
    # 限制描述长度，保留前100个字符
    if [[ ${#desc} -gt 100 ]]; then
        echo "${desc:0:100}..."
    else
        echo "$desc"
    fi
}

# 配置变量
CLASSIFIED_REPO_PATH="../GitHub-Chinese-Top-Charts-Classified"
CLASSIFIED_DATA_PATH="${CLASSIFIED_REPO_PATH}/content/charts/overall/software/All-Language.md"
TEMP_DIR="/tmp/sync-data-$(date +%s)"
SYNC_BRANCH="sync-data"
LOG_FILE="sync.log"
SAFE_MODE=false

# 检查安全模式参数
if [ "$1" = "--safe" ] || [ "$1" = "-s" ]; then
    SAFE_MODE=true
    log "安全模式启用 - 只检查不执行实际同步"
fi

# 清理函数
cleanup() {
    log "清理临时文件..."
    rm -rf "$TEMP_DIR"
    # 清理sync.log文件
    if [ -f "sync.log" ]; then
        rm -f sync.log 2>/dev/null || true
    fi
    log "清理完成"
}

# 设置trap确保脚本退出时清理
trap cleanup EXIT

# 开始同步
log "=== 开始从Classified仓库同步数据 ==="
log "数据源: $CLASSIFIED_DATA_PATH"

# 检查当前Git仓库状态
if [[ ! -d ".git" ]]; then
    handle_error "当前目录不是Git仓库"
fi

# 检查Git工作目录是否干净
STATUS_OUTPUT=$(git status --porcelain)
# 过滤掉sync.log文件
FILTERED_STATUS=$(echo "$STATUS_OUTPUT" | grep -v "?? sync.log" || true)
if [[ -n "$FILTERED_STATUS" ]]; then
    handle_error "工作目录不干净，请先提交或暂存更改"
fi

# 获取当前分支
CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH="main"  # 默认分支
fi
log "当前分支: $CURRENT_BRANCH"

# 检查Classified仓库和数据文件
if [[ ! -d "$CLASSIFIED_REPO_PATH" ]]; then
    handle_error "Classified仓库不存在: $CLASSIFIED_REPO_PATH"
fi

if [[ ! -f "$CLASSIFIED_DATA_PATH" ]]; then
    handle_error "Classified数据文件不存在: $CLASSIFIED_DATA_PATH"
fi

# 如果是安全模式，只检查不执行
if [ "$SAFE_MODE" = true ]; then
    log "[安全模式] 检查数据源..."
    if [[ -f "$CLASSIFIED_DATA_PATH" ]]; then
        TOTAL_LINES=$(grep -c "^\|" "$CLASSIFIED_DATA_PATH" || echo "0")
        log "[安全模式] Classified数据文件包含 $TOTAL_LINES 个项目"

        # 显示前5个项目
        log "[安全模式] 前5个项目预览:"
        grep "^\|" "$CLASSIFIED_DATA_PATH" | head -n 5 | while read line; do
            log "[安全模式] $line"
        done
    fi

    log "[安全模式] 检查当前README.md..."
    if [[ -f "README.md" ]]; then
        CURRENT_LINES=$(grep -c "^\|" README.md || echo "0")
        log "[安全模式] 当前README.md包含 $CURRENT_LINES 个项目"
    fi

    log "[安全模式] 检查完成，未执行实际操作"
    exit 0
fi

# 创建临时工作目录
mkdir -p "$TEMP_DIR"

# 备份当前README.md
log "备份当前README.md..."
cp README.md "$TEMP_DIR/README.md.backup"

# 检查sync-data分支是否存在
if git show-ref --verify --quiet "refs/heads/$SYNC_BRANCH"; then
    log "删除已存在的 $SYNC_BRANCH 分支..."
    git branch -D "$SYNC_BRANCH"
fi

# 创建新的sync-data分支
log "创建同步分支: $SYNC_BRANCH"
git checkout --orphan "$SYNC_BRANCH"

# 清理工作目录
git rm -rf . 2>/dev/null || true
log "清理工作目录完成"

# 恢复所有文件（除了README.md）
log "恢复文件..."
cp -r "$TEMP_DIR/README.md.backup" README.md 2>/dev/null || true

# 恢复其他重要文件
IMPORTANT_FILES=(".gitattributes" "LICENSE" "README-Part2.md" "CLAUDE.md" ".github" "scripts")
for file in "${IMPORTANT_FILES[@]}"; do
    if [ -e "../$CURRENT_BRANCH/$file" ]; then
        log "恢复文件: $file"
        cp -r "../$CURRENT_BRANCH/$file" . 2>/dev/null || true
    fi
done

# 解析Classified数据并转换格式
log "解析和转换数据格式..."

# 创建临时数据文件
TEMP_DATA_FILE="$TEMP_DIR/converted_data.md"

# 提取并转换数据表格
log "开始数据转换..."
in_table=false
row_count=0

# 添加表头
echo "|#|Repository|Description|Stars|Language|Updated|" >> "$TEMP_DATA_FILE"
echo "|:-|:-|:-|:-|:-|:-|" >> "$TEMP_DATA_FILE"

while IFS= read -r line; do
    if [[ $line =~ ^\|\s*[0-9]+\s*\|\s*\[.*\]\(.*\)\s*\|.*\|.*\|.*\|.*\|$ ]]; then
        # 数据行，需要转换格式
        # 使用cut解析数据行
        rank=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
        repo_part=$(echo "$line" | cut -d'|' -f3)
        description=$(echo "$line" | cut -d'|' -f4)
        stars=$(echo "$line" | cut -d'|' -f5 | tr -d ' ')
        language=$(echo "$line" | cut -d'|' -f6 | tr -d ' ')
        updated=$(echo "$line" | cut -d'|' -f7 | tr -d ' ')

        # 从repo部分解析出repo_name和repo_url
        if [[ $repo_part =~ ^\[([^\]]+)\]\(([^)]+)\)$ ]]; then
            repo_name="${BASH_REMATCH[1]}"
            repo_url="${BASH_REMATCH[2]}"
        else
            continue
        fi

        # 格式转换
        formatted_stars=$(format_stars "$stars")
        formatted_date=$(format_date "$updated")
        simplified_desc=$(simplify_description "$description")

        # 重新构建行
        new_line="|$rank|[$repo_name]($repo_url)|$simplified_desc|$formatted_stars|$language|$formatted_date|"
        echo "$new_line" >> "$TEMP_DATA_FILE"

        row_count=$((row_count + 1))
        if [[ $((row_count % 10)) -eq 0 ]]; then
            log "已处理 $row_count 个项目..."
        fi
    fi
done < "$CLASSIFIED_DATA_PATH"

log "数据转换完成，共处理 $row_count 个项目"

# 更新README.md的All Language部分
log "更新README.md的All Language部分..."

# 读取当前README.md内容
README_CONTENT=$(cat README.md)

# 找到All Language部分的开始和结束
ALL_LANG_START=$(echo "$README_CONTENT" | grep -n "^## All Language$" | cut -d: -f1)
if [[ -z "$ALL_LANG_START" ]]; then
    handle_error "未找到README.md中的All Language部分"
fi

# 找到下一个主要标题作为结束位置
ALL_LANG_END=$(echo "$README_CONTENT" | tail -n +$((ALL_LANG_START + 1)) | grep -n "^## " | head -n 1 | cut -d: -f1)

if [[ -z "$ALL_LANG_END" ]]; then
    # 如果没有找到下一个标题，则到文件末尾
    ALL_LANG_END=$(echo "$README_CONTENT" | wc -l)
else
    ALL_LANG_END=$((ALL_LANG_START + ALL_LANG_END - 1))
fi

# 构建新的README.md内容
log "构建新的README.md内容..."

# 保留All Language之前的内容
HEAD_CONTENT=$(echo "$README_CONTENT" | head -n $((ALL_LANG_START - 1)))

# 添加All Language标题
echo "$HEAD_CONTENT" > README.md
echo "" >> README.md
echo "## All Language" >> README.md
echo "" >> README.md

# 添加转换后的表格
cat "$TEMP_DATA_FILE" >> README.md

# 保留All Language之后的内容（如果存在）
TAIL_START=$((ALL_LANG_END + 1))
TOTAL_LINES=$(echo "$README_CONTENT" | wc -l)

if [[ $TAIL_START -le $TOTAL_LINES ]]; then
    echo "" >> README.md
    echo "$README_CONTENT" | tail -n +$TAIL_START >> README.md
fi

log "README.md更新完成"

# 确保没有sync.log文件
if [ -f "sync.log" ]; then
    rm -f sync.log 2>/dev/null || true
fi

# 添加所有更改
log "添加文件到Git..."
git add .

# 提交更改
COMMIT_MSG="自动同步自Classified仓库 - $(date '+%Y-%m-%d %H:%M:%S')

数据来源: $CLASSIFIED_DATA_PATH
处理项目数: $row_count
同步时间: $(date)"

log "提交更改..."
if ! git commit -m "$COMMIT_MSG"; then
    handle_error "提交失败"
fi
log "提交完成"

# 显示同步结果
log "=== 同步完成 ==="
log "最新提交:"
git log --oneline -n 3

# 显示文件统计
if command -v wc &> /dev/null; then
    TOTAL_FILES=$(find . -name "*.md" -not -path "./.git/*" | wc -l)
    log "Markdown文件总数: $TOTAL_FILES"
fi

# 显示表格行数
TABLE_ROWS=$(grep -c "^\|.*\|.*\|.*\|.*\|.*\|" README.md || echo "0")
log "README.md中的表格行数: $TABLE_ROWS"

log "同步脚本执行完成"
exit 0