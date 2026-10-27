# GitHub公开仓库上传指南

仓库名称：`fpga-multimedia-player`。本指南整理于2026-10-28，由你登录后上传；当前未替你创建或推送仓库。

本次D盘交付位置：`D:\codexworks\audio_video_recovery_20261028`。上传用的源码根目录为其中的`github\fpga-multimedia-player`；外层也放了一份本指南，方便直接打开。

## 1. 选对上传文件夹

本指南所在的`docs`目录上一级，就是**公开源码根目录**。应能看见`README.md`、`rtl`、`docs`、`host`、`tools`、`constraints`、`verification`和`project_manifest.json`。只上传这个文件夹中的内容。

交付目录里的`board_v114`含完整本地厂商依赖，`media`含测试音轨；这两个目录以及SD卡文件、bit、原片/歌曲不要一起上传。源码ZIP用于传递，GitHub不会自动把ZIP展开为源码主页。ZIP先解压，再上传解压后的目录内容。

## 2. 创建空的公开仓库

1. 登录[GitHub创建仓库页面](https://github.com/new)。
2. `Owner`选你的个人账号或组内已授权的组织，`Repository name`填`fpga-multimedia-player`。
3. `Description`可填：`安路 EG4S20 FPGA 多媒体播放器：FAT32、720P60输出与音视频测试版、图片轮播、音频、频谱和中文OSD。`
4. 选择`Public`。不要勾选初始化README、`.gitignore`或License，文件包已有README及依赖说明；厂商/第三方版权需分别保留，暂不为整个工程套用统一MIT等许可证。
5. 点击`Create repository`，保留页面，记下仓库HTTPS地址，例如`https://github.com/你的用户名/fpga-multimedia-player.git`。

如果已创建同名仓库，直接打开它，不要再新建重复仓库。

## 3. 推荐：PowerShell + Git上传完整目录

在资源管理器打开公开源码根目录，在地址栏输入`powershell`并回车。先确认工具及目录：

```powershell
git --version
Get-Location
Test-Path .\README.md
Test-Path .\project_manifest.json
```

后两项应返回`True`。若`git`命令不存在，可先安装[Git for Windows](https://git-scm.com/download/win)，关闭并重开PowerShell；也可以使用下文网页上传方式。

**第一次上传这个文件夹**时依次执行；把名字、邮箱及用户名换成你自己的。GitHub可在[邮箱设置](https://github.com/settings/emails)中提供noreply邮箱，使用该完整地址可避免提交记录公开真实邮箱。

```powershell
git init -b main
git config user.name "你的提交署名"
git config user.email "你的GitHub提交邮箱"
git add .
git status --short
```

`git status`应列出源码、文档、工具脚本与合成测试。若出现`board_v114`、`media`、`fat32_verification_workspace`、`build_workspace`、`*.bit`、`*.VID`、`*.VAU`、`*.wav`或工具`*.exe`，先停止提交并检查是否进入了错误目录。若出现初始化后的本地生成文件，按`.gitignore`排除。不要删掉公开源码中的人工合成测试fixture。

确认后：

```powershell
git commit -m "Freeze v114 test snapshot: 720p60 output and audio recovery guards"
git remote add origin https://github.com/YOUR_USER/fpga-multimedia-player.git
git push -u origin main
```

将`YOUR_USER`替换为你的GitHub用户名。浏览器或Git Credential Manager弹出登录时，由你本人登录并完成授权；GitHub账户密码不能作为Git HTTPS密码直接输入，不需要把密码或令牌发给别人。不要把访问令牌写进remote URL或README。

如果提示`remote origin already exists`，先运行`git remote -v`核对地址；只有确认指向你的目标仓库后再推送。不要直接强推覆盖已有工程。若提示远程分支已有提交，先核对是否误选了已有仓库；保留双方提交并处理合并，不能用`--force`跳过。

## 4. 不使用Git：网页分批上传

1. 打开新仓库页面，点击`uploading an existing file`；已有仓库使用`Add file` → `Upload files`。
2. 从公开源码根目录把文件和目录拖入上传区域。必须保留`rtl/video/...`等层级，不要只拖ZIP，不要把整个外层交付文件夹套进仓库。
3. 网页单次通常限制100个文件、单文件25MiB；若提示文件数限制，按`rtl`、`docs`、`host`、`verification`等顶层目录分批。某个目录过多时，再按模块子目录分批，核对预览路径没有被展开成同一层。首次也要上传根目录的`.gitignore`。
4. 填写简短提交说明，如`Add video and storage RTL`，点击`Commit changes`。大批量和后续持续更新建议使用Git，避免漏文件。

## 5. 上传后五分钟核对

- 仓库首页直接显示中文README，能点进模块导航、算法介绍、构建方式、验证状态和参考资料。
- `rtl/video/video_player.v`等源码在预期子目录中，不是只有一个ZIP。
- `release_status.json`与本地交付相同。实验候选、时序未收敛、未实板等状态如实保留，不把综合通过或生成bit写成全片可靠性通过。
- 没有厂商加密IP、媒体、SD真实目录、工具二进制、个人凭据或本地还原工作区。
- README中本地D盘位置是本地交付说明，外部访客无法访问本地文件；源码说明链接应使用仓库相对路径。

可在右侧`About`设置简介，并添加`fpga`、`verilog`、`multimedia`、`fat32`、`hdmi`等topics。README是仓库主页；本次不需要启用GitHub Pages，也不需要把RTL工程部署为网站。

## 6. 后续提交与复现

修改后在同一目录执行`git status`、`git add`、`git commit`、`git push`。不要使用force push覆盖组员提交，先`git pull`并协调冲突。

访客复现先阅读[依赖与许可](DEPENDENCIES.md)、[工程构建](BUILD.md)和[验证状态](VALIDATION.md)。通过`project_manifest.json`从自己的合法厂商工程导入依赖；公开包不包含厂商工具和加密IP，因此下载仓库后不能承诺无需安装工具就直接生成bit。

正式比赛提交时，记录当前Git提交号（`git rev-parse HEAD`）、板上实际bit文件名和SHA256、SD视频/音轨版本及测试结果，避免源码版本与演示产物不一致。

## 7. 邀请组员一起修改

打开仓库 Settings → Collaborators（有些界面显示 Collaborators and teams）→ Add people，输入组员GitHub用户名或邮箱，发送邀请，组员接受后即可按授予权限协作。组织仓库用对应团队的Write权限；个人仓库按GitHub提供的协作者权限界面操作。公开只代表所有人能读，不等于所有人能改。

建议每个人创建自己的分支并通过Pull request合并。今天首个提交说明可写 `Freeze v114 test snapshot: 720p60 output and audio recovery guards`。如创建Release，请勾选Pre-release，标题注明 `v114 test snapshot - timing not closed`，不要标成稳定版本。

## 当天最终版检查

README应显示v114、720p60，以及setup −1.980ns的已知限制。manifest.release应为v114-20261028-final-test；不要把以前v56/v109的文件夹上传为今天最终版。上传的是 `github/fpga-multimedia-player` 文件夹内部内容。
