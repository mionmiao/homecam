import SwiftUI

struct CameraHomeView: View {
    @EnvironmentObject private var model: CameraAppModel
    @State private var serverURL = ""
    @State private var deviceName = DeviceInfo.defaultName
    @State private var pairingCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("设备状态") {
                    Label(model.statusText, systemImage: model.isStreaming ? "video.fill" : "bolt.horizontal.circle")
                    if model.isStreaming { Text("摄像头和麦克风正在使用").foregroundStyle(.orange) }
                    else { Text("待命时不使用摄像头或麦克风").foregroundStyle(.secondary) }
                    if !model.configSummary.isEmpty {
                        Text(model.configSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("当前安装版本 \(model.appBuildText)").font(.caption).foregroundStyle(.secondary)
                }
                if !model.isPaired {
                    Section("连接 HomeCam") {
                        labeled("网页地址") {
                            TextField("https://example.com", text: $serverURL)
                                .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        }
                        labeled("设备名称") { TextField("此设备名称", text: $deviceName) }
                        labeled("六位配对码") { TextField("网页端生成的配对码", text: $pairingCode).keyboardType(.numberPad) }
                    }
                    Section {
                        Button {
                            model.pair(serverURL: serverURL, name: deviceName, code: pairingCode)
                        } label: {
                            HStack { Spacer()
                                if model.isWorking { ProgressView().tint(.white) }
                                Text(model.isWorking ? "正在配对…" : "配对并开始待命").fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking || serverURL.isEmpty || pairingCode.count != 6)
                        Text("配对码由网页端“添加摄像头”生成，10 分钟内有效。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("已配对设备") {
                        Text(model.deviceName)
                        Text(model.serverURL.absoluteString).font(.footnote).foregroundStyle(.secondary)
                        Button("刷新运行时配置") { model.refreshConfig(manual: true) }
                        Button("检查更新") { model.checkForUpdate(manual: true) }
                        Button("停止待命", role: .destructive) { model.disconnect() }
                    }
                }
                if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                    Section("iPhone 使用说明") {
                        Text("保持此 App 在前台，网页端点击“开始观看”后才会开启采集。进入后台会自动停止直播。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("版本更新：启动时会自动检查，有新版可一键安装（需已安装 LiveContainer）。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
            }
            .navigationTitle("HomeCam 摄像头")
            .alert("HomeCam", isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ), presenting: model.notice) { notice in
                switch notice {
                case .update(let info):
                    Button("立即更新") { model.installUpdate(info) }
                    Button("稍后", role: .cancel) { model.notice = nil }
                case .message:
                    Button("好") { model.notice = nil }
                }
            } message: { notice in
                switch notice {
                case .update(let info):
                    Text("当前 build \(UpdateChecker.localBuild) → 最新 build \(info.build)\(info.version.isEmpty ? "" : "（\(info.version)）")\n\n安装会退出当前 App，装完后从 LiveContainer 重新打开即可。\n\n\(info.notes)")
                case .message(let text):
                    Text(text)
                }
            }
            .onAppear {
                serverURL = model.serverURL.absoluteString.hasSuffix("/") ? "" : (model.serverURL.absoluteString == "https://" ? "" : model.serverURL.absoluteString)
                if deviceName.isEmpty { deviceName = DeviceInfo.defaultName }
                model.capturePhotosIfNeeded()  // 冷启动首次进入
            }
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
