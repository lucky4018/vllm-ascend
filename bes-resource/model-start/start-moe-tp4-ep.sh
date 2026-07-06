#!/bin/bash
# 模式① 窄 EP（低延迟首选）: TP=4, DP=1 + --enable-expert-parallel
# Qwen1.5-MoE-A2.7B  用 0,1,2,3 共 4 卡
# attention 走 TP=4；60 个专家按 EP 切分到 4 卡；全局 1 个实例，单请求用满 4 卡
#
# 说明：三种模式共用容器名 vllm-moe-bench、宿主端口 9003、served-model-name qwen1.5-moe，
#       一次只启动一种，跑完 `docker stop vllm-moe-bench` 再起下一个，压测脚本无需改动。

docker run --rm -d \
  --name vllm-moe-bench \
  --privileged \
  --device /dev/davinci0 \
  --device /dev/davinci1 \
  --device /dev/davinci2 \
  --device /dev/davinci3 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /home/publicmodel:/models:ro \
  -v /home/liushilei/vllm-ascend/bes-resource/model-test/moe-bench:/results \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -p 9003:8000 \
  --shm-size=16g \
  -e ASCEND_VISIBLE_DEVICES=0,1,2,3 \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:$LD_LIBRARY_PATH \
  vllm-ascend-0.20.2rc:offline \
  vllm serve /models/Qwen1.5-MoE-A2.7B \
  --port 8000 \
  --host 0.0.0.0 \
  --trust-remote-code \
  --served-model-name qwen1.5-moe \
  --tensor-parallel-size 4 \
  --data-parallel-size 1 \
  --enable-expert-parallel \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.9

echo "模式① TP4+EP 启动中 (容器 vllm-moe-bench, 端口 9003)"
echo "查看日志: docker logs -f vllm-moe-bench"
