# HomeCam

按需启用的家庭摄像头：Android 手机作为摄像头端，浏览器作为观看端。服务器仅负责账号、设备配对、连接协调和必要的 WebRTC 中继，不保存录像。

## 第一版能力

- 观看端发起观看后才启用手机的摄像头和麦克风；停止观看立即释放。
- 低码率 WebRTC 实时画面（默认 480p / 12fps / 450kbps）。
- 设备配对、单观看者限制、网页端本地录像（浏览器保存）。
- Android 常驻通知、开机后尝试恢复待命服务。

## 本地启动

1. 复制 `.env.example` 为 `.env`，修改管理员密码和随机签名密钥。
2. `npm install`
3. `npm start`
4. 访问 `http://localhost:3000`。

生产环境必须使用 HTTPS/WSS（建议准备一个域名，再由 Caddy 自动签发证书）。蜂窝网络观看还应在 VPS 安装 coturn，并把 TURN 地址和凭据填入 `ICE_SERVERS`；示例见 `deploy/turnserver.conf`。部署说明见 `deploy/Caddyfile` 与 `deploy/homecam.service`。

## Android

用 Android Studio 打开 `android/`，同步 Gradle 后安装到作为摄像头的手机。在应用中输入服务器 HTTPS 地址和网页端生成的一次性配对码。

> iOS 摄像头端已实现（见 `ios/README.md`），通过 LiveContainer + SideStore 用免费 Apple ID 侧载，构建产出的未签名 IPA 在 GitHub Release 的 `ios-unsigned` 中下载。iOS 不允许可靠地在后台被远程唤醒并持续开启摄像头，因此 iOS 端只承诺前台待命：配对后维持待命连接，开始观看才启用采集，切到后台立即停止。
