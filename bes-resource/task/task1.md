我需要在离线环境制作一个vllm-ascend镜像，请基于Dockerfile生成一个脚本，自动把构建镜像的依赖资源全部下载到本地并构建镜像，写一个build.sh，放到/bes-resource/ubuntu22.04/build.sh中。


build.sh包含两个功能：
1、get-resource //自动下载所有资源，所有资源放到bes-resource目录下
bes-resource
--ubuntu22.04
----Dockerfile.offline  //基于Dockerfile改成离线打包镜像,不改变原有文件，只改动资源从本地资源拉取
----build.sh            //
----offline-resource
------apt   //所有离线apt资源包都下载下这个目录中，给Dockerfile.offline使用
------code  //vllm代码、Mooncake代码存放位置
------pip   //pip代码存放位置，根据不同工程分成独立的离线pip包目录
------changecode
2、start    //开始构建镜像


基于Dockerfile复制生成全新文件 Dockerfile.offline，适配离线构建环境，最终构建命令固定：
docker build --no-cache -f .bes-resource/ubuntu22.04/Dockerfile.offline -t vllm-ascend-0.20.2rc:offline .

# 硬性规则
1. 必须使用离线资源构建，原构建脚本中在线资源或依赖请提前下载好。
2. 所有在线资源需要下载到本地,Dockerfile.offline尽量保持和原有文件一致的写法
3. 禁止直接改动vllm-ascend、vllm、Mooncake源码，如果需要改动请在changecode下创建相同路径的同名文件，  执行在dockerbuild时把同名文件复制替换过去
4. vllm和Mooncake代码使用正面仓库的分支
   git clone  -b bes/v0.20.2 https://github.com/lucky4018/vllm
   git clone  -b bes/v0.3.8.post1 https://github.com/lucky4018/Mooncake
5. 所有生成资源都要在bes-resource下，包括脚本，离线包，日志等


# 效率优化补充
镜像构建耗时很长，请在脚本内增加快速校验手段：
- 构建前校验离线文件完整性，提前拦截缺失资源问题，避免白等长时间打包
- 构建日志分文件保存，出错可快速定位失败环节
- 在保证功能和脚本结构不大变的情况下，尽量优化镜像大小


# 文档输出
输出一个总结文档，说明改动了什么，最终如何达到任务目标的

# 镜像构建成功后置任务

测试镜像是否能拉起大模型，使用以下命令。如果不行请反复检查镜像构建是否和原Dockerfile有不一样或缺少依赖导致
docker run --rm \
  --name vllm-qwen3-0.6b \
  --privileged \
  --device /dev/davinci4 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /home/bes/work/vllm-project/models/Qwen:/models:ro \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
  -v /usr/local/dcmi:/usr/local/dcmi \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
  -p 9001:8000 \
  --shm-size=16g \
  -e ASCEND_VISIBLE_DEVICES=4 \
  -e LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:$LD_LIBRARY_PATH \
  vllm-ascend-0.20.2rc:offline \
  vllm serve /models/Qwen3-0.6B \
  --port 8000 \
  --host 0.0.0.0 \
  --trust-remote-code \
  --served-model-name qwen3 \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.9