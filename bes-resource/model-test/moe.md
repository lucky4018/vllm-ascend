# 4张910B4跑MoE（Qwen1.5-MoE-A2.7B）两种最优模式，按业务场景直接选
## 前置规则（4卡总设备=4，仅两种合法EP组合）
公式：`EP_SIZE = TP × DP = 4`
只有两套可用EP方案，再加一套纯TP对照组：
1. **TP=4，DP=1 + --enable-expert-parallel（窄EP·低延迟首选）**
2. **TP=1，DP=4 + --enable-expert-parallel（宽EP·高吞吐首选）**
3. **TP=4、无EP（纯TP，仅做性能对比基准，不推荐生产）**

## 一、场景1：在线对话、客服、低延迟交互（优先选 TP=4 DP=1 + EP）
### 适用特征
- 并发量不高（同时在线几十人以内）、对**TTFT首包延迟、单条生成速度**敏感；
- 短轮次对话、用户在意响应快慢；
- 模型权重偏大，想压低单卡权重显存占用。

### 核心优势
1. Attention稠密层做4卡张量切分，同一条请求4卡并行计算Prefill，**首token速度最快**；
2. EP_SIZE=4，Qwen1.5-MoE共8专家 → 每卡分到2个完整专家，专家显存直接减半；
3. 仅一套KV缓存，内存开销集中，单请求推理延迟最稳、抖动最小；
4. 仅一组推理引擎，HCCL通信量更少，910B单机高速互联下损耗极低。

### 启动参数示例
```bash
export HCCL_CONNECT_TIMEOUT=1800
export HCCL_BUFFSIZE=16777216
export VLLM_NPU_ATB_ENABLE=1
export VLLM_NPU_MULTI_STREAM=1
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ASCEND_VISIBLE_DEVICES=0,1,2,3

vllm serve ./Qwen1.5-MoE-A2.7B \
--tensor-parallel-size 4 \
--enable-expert-parallel \
--enable-eplb \
--quantization ascend \
--gpu-memory-utilization 0.9 \
--max-model-len 32768 \
--max-num-batched-tokens 32768 \
--max-num-seqs 256 \
--no-enable-prefix-caching \
--trust-remote-code \
--port 8000
```

## 二、场景2：批量任务、高并发压测、离线文本生成（优先选 TP=1 DP=4 + EP）
### 适用特征
- 大批量离线推理、QPS很高、同时几百条请求并发；
- 能接受轻微延迟上涨，追求**整体总tokens/s吞吐最大化**；
- 需要超大KV缓存池承载大量并发会话。

### 核心优势
1. 4套独立完整模型副本、4套独立KV缓存，请求轮询分到4张卡，并发上限比TP4高2~3倍；
2. EP_SIZE=4，专家同样均分4卡（每卡2个完整专家），EP显存收益完全保留；
3. 卡之间无稠密层AllReduce同步，仅MoE路由AllToAll，请求之间完全隔离，高并发下AICore利用率拉满；
4. 流量波动时吞吐弹性更好，适合压测、批量摘要、数据清洗。

### 启动参数示例
```bash
export HCCL_CONNECT_TIMEOUT=1800
export HCCL_BUFFSIZE=16777216
export VLLM_NPU_ATB_ENABLE=1
export VLLM_NPU_MULTI_STREAM=1
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ASCEND_VISIBLE_DEVICES=0,1,2,3

vllm serve ./Qwen1.5-MoE-A2.7B \
--tensor-parallel-size 1 \
--data-parallel-size 4 \
--enable-expert-parallel \
--enable-eplb \
--quantization ascend \
--gpu-memory-utilization 0.85 \
--max-model-len 32768 \
--max-num-batched-tokens 16384 \
--max-num-seqs 128 \
--no-enable-prefix-caching \
--trust-remote-code \
--port 8001
```

## 三、三套方案横向对比（4卡MoE）
| 方案 | 核心优点 | 短板 | 最佳场景 |
|------|--------|------|--------|
| TP4+EP | TTFT最低、单请求最快、单卡权重显存最小 | 仅1套KV，并发上限低 | 在线对话、低延迟服务 |
| TP1+DP4+EP | 总吞吐最高、并发上限拉满 | 每张卡完整存Attention，权重显存更高，单请求延迟略高 | 批量离线、高并发压测 |
| TP4 无EP（纯TP） | 无AllToAll路由通信 | 每张卡存全部8专家分片，显存翻倍、算力大量浪费、吞吐最差 | 仅做对照基线，不生产使用 |

## 四、快速选型一句话总结
1. 做人机交互、客服、聊天，要快响应 → **TP=4 + EP**
2. 跑批量任务、压测性能、追求每秒总token量 → **TP=1 DP=4 + EP**
3. 仅做并行对比实验看EP收益差距，才跑纯TP无EP模式

## 补充小提示（910B专属）
1. 4卡全部单机高速互联，两种EP方案HCCL AllToAll/AllReduce损耗都很小，不用担心通信拖后腿；
2. Qwen1.5-MoE-A2.7B仅8专家，4卡EP均分后每卡2专家，负载均衡波动极小，`--enable-eplb`开不开差距不大，建议打开兜底；
3. 若后续换大MoE（如Qwen3.5-35B-A3B），4卡纯TP会直接OOM，只能两种EP方案。