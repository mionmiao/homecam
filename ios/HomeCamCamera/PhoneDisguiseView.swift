import SwiftUI

/// 电话 App 伪装外壳。默认显示「最近通话」，输入暗号 *#666#* 点拨号后进入真实界面。
/// 进后台或关闭后回到伪装页面（解锁仅在本次前台会话内有效）。
struct PhoneDisguiseView: View {
    @State private var unlocked = false
    @State private var tab: PhoneTab = .recents
    @State private var viewID = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: CameraAppModel

    var body: some View {
        Group {
            if unlocked {
                CameraHomeView().environmentObject(model)
            } else {
                TabView(selection: $tab) {
                    FavoritesView().tabItem { Label("个人收藏", systemImage: "star.fill") }.tag(PhoneTab.favorites)
                    RecentsView().tabItem { Label("最近通话", systemImage: "clock") }.tag(PhoneTab.recents)
                    ContactsView().tabItem { Label("通讯录", systemImage: "person.circle.fill") }.tag(PhoneTab.contacts)
                    KeypadView(onSecret: { unlocked = true }).tabItem { Label("拨号键盘", systemImage: "circle.grid.3x3.fill") }.tag(PhoneTab.keypad)
                    VoicemailView().tabItem { Label("语音留言", systemImage: "circle.circle") }.tag(PhoneTab.voicemail)
                }
                .tint(.blue)
                .id(viewID)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                unlocked = false
                tab = .recents
                viewID = UUID()   // 强制重建，清空拨号输入
            }
        }
    }
}

enum PhoneTab: Hashable { case favorites, recents, contacts, keypad, voicemail }

// MARK: - 通用组件

private struct StatusBar: View {
    var body: some View {
        HStack {
            Text("22:14").font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "signal").font(.system(size: 12))
                Image(systemName: "wifi").font(.system(size: 12))
                Image(systemName: "battery.75percent").font(.system(size: 13))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.top, 8)
    }
}

private struct Avatar: View {
    var body: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable().scaledToFit()
            .frame(width: 44, height: 44)
            .foregroundStyle(.gray.opacity(0.55))
    }
}

private struct InfoButton: View {
    var body: some View {
        Image(systemName: "info.circle").foregroundStyle(.blue).font(.system(size: 20))
    }
}

private struct SearchBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.gray)
            Text("搜索").foregroundStyle(.gray)
            Spacer()
            Image(systemName: "mic.fill").foregroundStyle(.gray)
        }
        .padding(10).background(Color.white.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct Header: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
    }
}

// MARK: - 个人收藏

private struct FavoritesView: View {
    private let favorites: [(String, String)] = [
        ("张伟", "138 4521 8890"), ("李娜", "186 0392 4471"),
        ("王芳", "159 7734 2206"), ("刘洋", "133 9081 5567"),
        ("陈静", "137 5566 7812")
    ]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                StatusBar()
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "plus").foregroundStyle(.blue).font(.system(size: 22, weight: .semibold))
                }.padding(.horizontal, 20)
                Header(title: "个人收藏").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(favorites.indices, id: \.self) { i in
                            HStack(spacing: 12) {
                                Avatar()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(favorites[i].0).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                    HStack(spacing: 3) { Image(systemName: "phone.fill").font(.system(size: 10)); Text(favorites[i].1) }
                                        .foregroundStyle(.gray).font(.system(size: 13))
                                }
                                Spacer()
                                InfoButton()
                            }
                            .padding(.vertical, 10).padding(.horizontal, 20)
                            Divider().background(Color.white.opacity(0.15)).padding(.leading, 76)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 最近通话

private struct RecentsView: View {
    private let calls: [(String, String, String, Bool)] = [
        ("138 4521 8890", "北京", "2026/11/20", false),
        ("186 0392 4471", "上海", "2026/11/20", false),
        ("95588", "未知", "2026/11/19", true),
        ("159 7734 2206", "广东 深圳", "2026/11/19", false),
        ("021 6288 3391", "上海", "2026/11/18", false),
        ("133 9081 5567", "浙江 杭州", "2026/11/18", false),
        ("400 820 5588", "未知", "2026/11/17", false),
        ("187 6612 3390", "山东 青岛", "2026/11/16", false),
        ("139 1100 2288", "四川 成都", "2026/11/15", true),
        ("137 5566 7812", "北京", "2026/11/14", false)
    ]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                StatusBar()
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    HStack(spacing: 0) {
                        Text("所有通话").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6).background(Color.white.opacity(0.2))
                        Text("未接来电").font(.system(size: 13)).foregroundStyle(.gray).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }.padding(.horizontal, 20)
                Header(title: "最近通话").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                SearchBar().padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(calls.indices, id: \.self) { i in
                            let c = calls[i]
                            HStack(spacing: 12) {
                                Avatar()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.0).foregroundStyle(c.3 ? .red : .white).font(.system(size: 16, weight: .semibold))
                                    HStack(spacing: 3) {
                                        Image(systemName: "phone.fill").font(.system(size: 10))
                                        Text(c.1).font(.system(size: 13))
                                    }.foregroundStyle(.gray)
                                }
                                Spacer()
                                Text(c.2).foregroundStyle(.gray).font(.system(size: 13))
                                InfoButton()
                            }
                            .padding(.vertical, 10).padding(.horizontal, 20)
                            Divider().background(Color.white.opacity(0.15)).padding(.leading, 76)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 通讯录

private struct ContactsView: View {
    private let contacts: [(String, String)] = [
        ("陈静", "137 5566 7812"), ("赵敏", "188 2233 9901"),
        ("孙磊", "135 7788 4412"), ("周涛", "139 1100 2288"),
        ("吴桐", "186 6677 3312")
    ]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                StatusBar()
                HStack {
                    HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("列表") }.foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "plus").foregroundStyle(.blue).font(.system(size: 22, weight: .semibold))
                }.padding(.horizontal, 20)
                Header(title: "通讯录").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                SearchBar().padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.gray.opacity(0.5)).frame(width: 48, height: 48)
                                Text("MZ").foregroundStyle(.white).font(.system(size: 20, weight: .semibold))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Mio Zhu").foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                Text("我的名片").foregroundStyle(.gray).font(.system(size: 13))
                            }
                            Spacer()
                        }.padding(.horizontal, 20).padding(.vertical, 10)
                        Divider().background(Color.white.opacity(0.15)).padding(.leading, 20)
                        ForEach(contacts.indices, id: \.self) { i in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.gray.opacity(0.45)).frame(width: 44, height: 44)
                                    Text(String(contacts[i].0.prefix(1))).foregroundStyle(.white).font(.system(size: 18, weight: .semibold))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contacts[i].0).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                    Text(contacts[i].1).foregroundStyle(.gray).font(.system(size: 13))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 9).padding(.horizontal, 20)
                            Divider().background(Color.white.opacity(0.15)).padding(.leading, 76)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 拨号键盘（暗号入口）

private struct KeypadView: View {
    let onSecret: () -> Void
    @State private var input = ""
    private let secret = "*#666#*"
    private let keys: [[String]] = [
        ["1", "2\nABC", "3\nDEF"], ["4\nGHI", "5\nJKL", "6\nMNO"],
        ["7\nPQRS", "8\nTUV", "9\nWXYZ"], ["*", "0\n+", "#"]
    ]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                StatusBar()
                // 输入显示：大字居中 + 右上角联系人图标
                ZStack {
                    Text(input).foregroundStyle(.white).font(.system(size: 32, weight: .regular)).frame(height: 44)
                    HStack {
                        Spacer()
                        Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.blue).font(.system(size: 24))
                    }.padding(.trailing, 24)
                }
                .padding(.top, 22)
                Spacer()
                VStack(spacing: 20) {
                    ForEach(keys, id: \.self) { row in
                        HStack(spacing: 22) {
                            ForEach(row, id: \.self) { key in
                                Button { input.append(String(key.first!)) } label: {
                                    ZStack {
                                        Circle().fill(Color.gray.opacity(0.45)).frame(width: 74, height: 74)
                                        if key.contains("\n") {
                                            let parts = key.split(separator: "\n")
                                            VStack(spacing: 1) {
                                                Text(parts[0]).foregroundStyle(.white).font(.system(size: 29, weight: .regular))
                                                Text(parts[1]).foregroundStyle(.white).font(.system(size: 10, weight: .semibold))
                                            }
                                        } else {
                                            Text(key).foregroundStyle(.white).font(.system(size: 29))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // 拨号按钮 + 删除按钮
                HStack(spacing: 34) {
                    Button {
                        if input == secret { onSecret() }
                        input = ""
                    } label: {
                        ZStack {
                            Circle().fill(Color.green).frame(width: 74, height: 74)
                            Image(systemName: "phone.fill").foregroundStyle(.white).font(.system(size: 29))
                        }
                    }
                    Button {
                        if !input.isEmpty { input.removeLast() }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.gray)
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 34, height: 24)
                            .background(Color.gray.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, 24)
                Spacer()
            }
        }
    }
}

// MARK: - 语音留言

private struct VoicemailView: View {
    private let mails: [(String, String, String, String)] = [
        ("+86 138 4521 8890", "北京", "2026/11/18", "01:23"),
        ("+86 186 0392 4471", "上海", "2026/11/15", "00:47"),
        ("95533", "未知", "2026/11/12", "02:11"),
        ("+86 159 7734 2206", "广东 深圳", "2026/11/08", "00:58"),
        ("+86 133 9081 5567", "浙江 杭州", "2026/11/03", "01:36"),
        ("10086", "未知", "2026/10/28", "00:22"),
        ("+86 187 6612 3390", "山东 青岛", "2026/10/20", "03:05"),
        ("+86 139 1100 2288", "四川 成都", "2026/10/12", "01:48")
    ]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                StatusBar()
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    Text("应答语").foregroundStyle(.blue)
                }.padding(.horizontal, 20)
                Header(title: "语音信箱").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                VStack(spacing: 8) {
                    Text("若要获取语音留言，首先请设置\n密码以及应答语。").foregroundStyle(.gray).font(.system(size: 13)).multilineTextAlignment(.center)
                    Text("设置").foregroundStyle(.white).padding(.horizontal, 40).padding(.vertical, 8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.6)))
                }.frame(maxWidth: .infinity).padding(.top, 24)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mails.indices, id: \.self) { i in
                            let m = mails[i]
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.0).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                    Text(m.1).foregroundStyle(.gray).font(.system(size: 13))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(m.2).foregroundStyle(.gray).font(.system(size: 13))
                                    Text(m.3).foregroundStyle(.gray).font(.system(size: 13))
                                }
                                InfoButton()
                            }
                            .padding(.vertical, 10).padding(.horizontal, 20)
                            Divider().background(Color.white.opacity(0.15))
                        }
                    }
                }
            }
        }
    }
}
