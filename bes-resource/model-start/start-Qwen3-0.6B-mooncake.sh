#!/bin/bash
# Qwen3-0.6B 模型启动脚本
# 使用 vLLM + Ascend NPU 运行
  docker run --rm \
  --name vllm-qwen3-0.6b-mooncake \
  --privileged \
  --device /dev/davinci7 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /home/bes/work/vllm-project/models/Qwen:/models:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -p 9000:8000 \
  --shm-size=16g \
  -e ASCEND_VISIBLE_DEVICES=7 \
  vllm-ascend-0.20.2rc:offline \
  bash -c "
    source /usr/local/Ascend/cann/set_env.sh && \
    export LD_LIBRARY_PATH=/usr/local/lib:\$LD_LIBRARY_PATH && \
  vllm serve /models/Qwen3-0.6B \
  --port 8000 \
  --host 0.0.0.0 \
  --trust-remote-code \
  --served-model-name qwen3 \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{\"kv_connector\": \"MooncakeConnector\", \"kv_role\": \"kv_both\", \"kv_rank\": 0, \"kv_parallel_size\": 1}'"





