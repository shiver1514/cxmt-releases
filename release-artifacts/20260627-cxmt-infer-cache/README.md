# cxmt-infer-cache 0627 更新包

上传时间：2026-06-27  
上传人：Shiver

## 文件

- `cxmt_infer_cache_0627_update_package.zip`
- `SHA256SUMS.txt`

## 内容摘要

本包用于现场更新 `cxmt-infer-cache`，包含：

- 1# 模型稀疏补推
- rule1 稀疏帧速度计算适配
- 2# 稀疏 index 对齐配置
- 专项日志请求/视频剩余口径拆分
- 健康状态 `health_sample` 结构化记录
- 离线汇总新增硬件报告 CSV

## 使用方式

下载 `cxmt_infer_cache_0627_update_package.zip` 后，在现场服务器解压，按包内：

```text
03_文档和SOP/02_现场升级SOP.md
03_文档和SOP/03_现场调试验证SOP.md
03_文档和SOP/04_离线汇总与硬件报告SOP.md
```

执行升级、调试和汇总。

## 校验

下载后可执行：

```bash
sha256sum cxmt_infer_cache_0627_update_package.zip
```

结果应与 `SHA256SUMS.txt` 一致。
