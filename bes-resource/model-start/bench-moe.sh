#!/bin/bash
# MoE 并行模式压测脚本（三模式共用）
# 对已启动的 vllm-moe-bench 容器跑 `vllm bench serve`，random 数据集，走 /v1/completions
# 用法: bash bench-moe.sh <模式标签>
#   例: bash bench-moe.sh tp4-ep
#       bash bench-moe.sh dp4-ep
#       bash bench-moe.sh tp4-noep
#
# 每个模式跑 3 档并发：1(延迟) / 16 / 64(吞吐)，结果 JSON 存到容器 /results (宿主 model-test/moe-bench)

set -e

MODE="${1:?请传入模式标签, 如: bash bench-moe.sh tp4-ep}"
CONTAINER="vllm-moe-bench"
MODEL="/models/Qwen1.5-MoE-A2.7B"
SERVED="qwen1.5-moe"
IN_LEN=1024
OUT_LEN=256

# 并发档位 -> 该档发送的请求数
declare -A NUM_PROMPTS=( [1]=30 [16]=160 [64]=256 )
CONCS=(1 16 64)

# 确认容器在跑
if ! docker ps --filter "name=^${CONTAINER}$" --filter "status=running" -q | grep -q .; then
  echo "[错误] 容器 ${CONTAINER} 未运行，请先执行对应 start-moe-*.sh"
  exit 1
fi

# 确认服务就绪
echo "[bench] 等待服务就绪 (${SERVED}) ..."
for i in $(seq 1 60); do
  if curl -s http://localhost:9003/v1/models 2>/dev/null | grep -q "$SERVED"; then
    echo "[bench] 服务就绪"; break
  fi
  [ "$i" = "60" ] && { echo "[错误] 服务 20 分钟内未就绪"; exit 1; }
  sleep 20
done

echo "[bench] 模式=${MODE}  输入=${IN_LEN} 输出=${OUT_LEN}  并发档=${CONCS[*]}"
for C in "${CONCS[@]}"; do
  N="${NUM_PROMPTS[$C]}"
  echo ""
  echo "========== 模式 ${MODE} | 并发 ${C} | 请求数 ${N} =========="
  docker exec "$CONTAINER" bash -c "source /usr/local/Ascend/ascend-toolkit/set_env.sh && vllm bench serve \
    --backend openai \
    --host 127.0.0.1 --port 8000 \
    --endpoint /v1/completions \
    --model '$MODEL' \
    --served-model-name '$SERVED' \
    --dataset-name random \
    --random-input-len $IN_LEN \
    --random-output-len $OUT_LEN \
    --num-prompts $N \
    --max-concurrency $C \
    --request-rate inf \
    --percentile-metrics ttft,tpot,itl,e2el \
    --metric-percentiles 50,90,99 \
    --save-result \
    --result-filename '/results/${MODE}-c${C}.json'" \
    2>&1 | tee "/home/liushilei/vllm-ascend/bes-resource/model-test/moe-bench/${MODE}-c${C}.log"
done

echo ""
echo "[bench] 模式 ${MODE} 完成，结果在 bes-resource/model-test/moe-bench/${MODE}-c*.json"
