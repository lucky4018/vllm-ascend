#!/bin/bash
# Qwen1.5-MoE-A2.7B 模型启动脚本
# 使用 vLLM + Ascend NPU 运行
# 模型为 MoE 架构 (Qwen2MoeForCausalLM, ~14.3B params, bf16 ≈ 28GB)
# 单卡 910B4 (32GB) 放不下权重+KV cache，使用 2 卡张量并行

docker run --rm \
  --name vllm-qwen1.5-moe-a2.7b \
  --privileged \
  --device /dev/davinci0 \
  --device /dev/davinci1 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /home/publicmodel:/models:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -p 9002:8000 \
  --shm-size=16g \
  -e ASCEND_VISIBLE_DEVICES=0,1 \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:$LD_LIBRARY_PATH \
  vllm-ascend-0.20.2rc:offline \
  vllm serve /models/Qwen1.5-MoE-A2.7B \
  --port 8000 \
  --host 0.0.0.0 \
  --trust-remote-code \
  --served-model-name qwen1.5-moe \
  --tensor-parallel-size 2 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.9
