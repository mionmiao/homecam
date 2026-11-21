# HomeCam iOS Camera

手机端用 **LiveContainer + SideStore**（免费 Apple ID，无需付费开发者账号）运行。应用只在前台待命：网页端开始观看时才启用相机和麦克风，切到后台立即停止推流。

> 应用伪装成「电话」：启动显示最近通话。进入真实界面的暗号是在拨号键盘输入 `*#666#*` 后点绿色拨号按钮。解锁状态会持久保存。

## 1. 一次性配置 LiveContainer + SideStore（手机端）

> 2026-10 起 LiveContainer 官方 GitHub 仓库不可访问，请用社区镜像
> `github.com/LiveContainerMirror/LiveContainer` 的 **Nightly 20260918** 构建。
> 二合一的 `LiveContainer+SideStore.ipa` SHA-256 应为
> `bec41bc21d75a0f2e85a0aa589ce5772e24e410deb017486758a3bc0503c8de7`，不符请不要安装。

1. 电脑连接手机，用 iLoader / Impactor 安装上面的二合一 IPA（Impactor 勾选 "Only Register Main Bundle"）。
2. 手机：设置 → 通用 → VPN 与设备管理 → 信任开发者证书；隐私与安全性 → 打开开发者模式。
3. 打开 LiveContainer → 左上角 SideStore 图标 → 用免费 Apple ID 登录。
4. 连接 **LocalDevVPN**，在 SideStore 中 `Refresh All`，确认证书有效期被刷新。
5. SideStore → Settings → `Export Signing Certificate`。
6. 回到 LiveContainer → 设置 → `从 SideStore 导入证书`（按钮变成 "Remove Certificate" 即成功）。
7. 设置 → `JIT-Less Mode Diagnose` → 显示 **Test Passed** 即配置完成。

> 若手机 iOS 为 26.x 且稳定版 SideStore 刷新报 "not connected to WiFi and/or LocalDevVPN"，改用 SideStore nightly 构建。
> 手机若装有 Tailscale，刷新前需断开（iOS 只允许一个 VPN）。
> 证书每 7 天过期一次，SideStore 需定期 `Refresh All`（可配快捷指令自动续签）。本方案未部署自建 anisette 服务器，续签走 SideStore 默认服务器。

## 2. 安装 HomeCam Camera

1. 打开本仓库的 GitHub Release `ios-unsigned`（仓库首页右侧 Releases，或直接访问 `/releases/tag/ios-unsigned`），下载 `HomeCamCamera.ipa`。
   构建由 `.github/workflows/ios-ipa.yml` 在推送 `ios/` 变更时自动产出，是**未签名**包。
2. 在 LiveContainer 右上角「+」→ 选择该 IPA → 导入。
3. 回到 LiveContainer 应用列表，长按图标可「添加到主屏幕」；点击图标启动。
4. 首次观看时若系统询问相机/麦克风权限，允许即可（LiveContainer 下权限为全局授予）。

模拟器不支持摄像头推流，请用真机。

## 3. 本地开发构建

在 macOS 上安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，在本目录执行：

```sh
xcodegen generate
xcodebuild -project HomeCamCamera.xcodeproj -scheme HomeCamCamera \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -archivePath /tmp/HomeCamCamera.xcarchive archive
```

然后把 `.xcarchive/Products/Applications/HomeCam Camera.app` 放进 `Payload/` 并打包成 IPA 即可导入 LiveContainer。

## 4. 设计边界

iOS 不允许在应用被系统挂起或结束后可靠地远程唤醒摄像头，因此本端只承诺**前台待命**：
配对后维持待命连接，网页端开始观看才开启采集，离开前台立即停止。这部分限制与 LiveContainer 无关，是 iOS 系统层面的约束。
