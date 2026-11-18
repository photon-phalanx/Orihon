# 在 GitHub 上打包 Orihon

进入 **Actions → Build Orihon IPA → Run workflow**，选择要打包的分支。也可以给指定提交添加并推送以 `ios-build-` 开头的标签来手动触发。两种方式都从同一提交生成真机包和模拟器测试版本。

在运行页面的 **Artifacts** 下载 **Orihon-unsigned.ipa**，用自己的侧载工具签名后安装。构建使用 Xcode 27.2 和 iOS 27.2 SDK，最低系统版本为 iOS 17。工作流会在打包前读取 Mach-O 的平台、架构、SDK 和最低版本。GitHub 无需 Apple 签名凭据。

**duo** 任务在 iOS 27.2 的 iPhone Duo 模拟器上打开一个离线章节。它通过不同颜色的页面验证折叠、展开、跨页翻页和旋转后的页码，并点击返回键。运行页面的 **Orihon-Duo-screenshots** 保存各步骤的截图，便于检查跨页中缝和控件位置。
