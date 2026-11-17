import SwiftUI

struct CameraHomeView: View {
    @EnvironmentObject private var model: CameraAppModel
    @State private var serverURL = ""
    @State private var deviceName = UIDevice.current.name
    @State private var pairingCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("设备状态") {
                    Label(model.statusText, systemImage: model.isStreaming ? "video.fill" : "bolt.horizontal.circle")
                    if model.isStreaming { Text("摄像头和麦克风正在使用").foregroundStyle(.orange) }
                    else { Text("待命时不使用摄像头或麦克风").foregroundStyle(.secondary) }
                }
                if !model.isPaired {
                    Section("连接 HomeCam") {
                        TextField("网页地址", text: $serverURL).textInputAutocapitalization(.never).keyboardType(.URL)
                        TextField("设备名称", text: $deviceName)
                        TextField("六位配对码", text: $pairingCode).keyboardType(.numberPad)
                        Button(model.isWorking ? "正在配对…" : "配对并开始待命") {
                            model.pair(serverURL: serverURL, name: deviceName, code: pairingCode)
                        }.disabled(model.isWorking || serverURL.isEmpty || pairingCode.count != 6)
                    }
                } else {
                    Section("已配对设备") {
                        Text(model.deviceName)
                        Text(model.serverURL.absoluteString).font(.footnote).foregroundStyle(.secondary)
                        Button("停止待命", role: .destructive) { model.disconnect() }
                    }
                }
                if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                Section("iPhone 使用说明") {
                    Text("保持此 App 在前台，网页端点击“开始观看”后才会开启采集。进入后台会自动停止直播。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("HomeCam 摄像头")
            .onAppear { serverURL = model.serverURL.absoluteString; deviceName = model.deviceName }
        }
    }
}
