#!/bin/bash
# Qwen3-0.6B 模型启动脚本
# 使用 vLLM + Ascend NPU 运行


  docker run -it --rm \
  --name vllm-tmp \
  --privileged \
  --device /dev/davinci4 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /home/bes/work/vllm-project/models/Qwen:/models:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -p 9002:8000 \
  --shm-size=16g \
  -e ASCEND_VISIBLE_DEVICES=4 \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:$LD_LIBRARY_PATH \
  vllm-ascend-0.20.2rc:offline bash