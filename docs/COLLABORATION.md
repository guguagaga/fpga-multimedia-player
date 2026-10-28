# 组内开发顺序与工程版本对应

本地开发是正常方式，Git记录提交的父子关系，GitHub保存共享历史。文件修改时间和聊天里的“最新版”不能替代提交编号。每位队员使用自己的克隆目录；不要让两个人同时在同一工作目录修改和切换分支。

## 开始一个任务

先保存当前修改（提交到自己的分支），再执行：

```powershell
git switch main
git pull --ff-only
git switch -c fix/你的任务名
```

`--ff-only`失败时说明本地与远程已分叉，先查看`git log --oneline --graph --all`并协调，不要强推。命令中的中文占位名要换成实际分支名，例如`fix/image-loading`。不要求所有人按同一时间串行开发；要求合并到main的版本可追踪并通过检查。

## 修改、提交和上传自己的分支

```powershell
git status
git add 具体修改的文件或目录
git diff --cached
git commit -m "Explain the behavior changed and why"
git push -u origin fix/你的任务名
```

在GitHub打开Pull requests → New pull request，base选择main，compare选择自己的分支。说明改动和验证，队友检查后合并。不要把私有媒体、厂商IP、工具exe和整个构建目录提交到源码仓库。

## 合并前同步队友的更新

先保证工作区干净，然后在自己的任务分支执行：

```powershell
git fetch origin
git merge origin/main
```

若冲突，逐文件协调并检查最终内容，用`git add`标记解决，再`git commit`完成合并。再运行受影响仿真和综合检查，并`git push`。这里采用merge，保留两边历史，不要求改写已分享提交或使用force。

Git能发现同一处文本冲突，但不能保证不同文件之间接口、时钟或功能一定兼容。无文本冲突也要复测。若希望在网页强制要求PR/审查，需按当前账号套餐和仓库可用功能配置规则；约定流程本身不会自动阻止直接推main。

## 源码、bit与SD媒体要一起记录

每个上板版本记下：`git rev-parse HEAD`、候选源码哈希清单、工具/seed/约束、bit SHA256、SD视频与音轨SHA256、时序结果、板测结果。构建期间不修改其源码；新修改使用新候选目录。

本轮以`c9e97b2`的v114为基线。v115/v116是组合改动，v117只替换频谱固定除法，v118只拆分BMP宽比较；每个候选单独构建、保留日志。研究补丁不自动修改生产清单。网络不可用时可以本地提交，但不能声称已经同步远程；恢复后先fetch，再核对分支和差异。

这份指南允许队员并行开发，但main的合并与上板版本应明确负责人，避免两个人各自把不同bit都叫“最终版”。
