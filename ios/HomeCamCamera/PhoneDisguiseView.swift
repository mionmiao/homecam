import SwiftUI

/// 电话 App 伪装外壳。默认显示「最近通话」，输入暗号 *#666#* 点拨号后进入真实界面。
struct PhoneDisguiseView: View {
    @AppStorage("homecam.disguise.unlocked") private var unlocked = false
    @State private var tab: PhoneTab = .recents
    @EnvironmentObject private var model: CameraAppModel

    var body: some View {
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
        }
    }
}

enum PhoneTab: Hashable { case favorites, recents, contacts, keypad, voicemail }

// MARK: - 通用组件

private struct StatusBar: View {
    var body: some View {
        HStack {
            Text("22:03").font(.system(size: 15, weight: .semibold))
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
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                StatusBar()
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "plus").foregroundStyle(.blue).font(.system(size: 22, weight: .semibold))
                }.padding(.horizontal, 20)
                Header(title: "个人收藏").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                HStack(spacing: 12) {
                    Avatar()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("175 6087 7999").foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                        HStack(spacing: 3) { Image(systemName: "phone.fill").font(.system(size: 10)); Text("电话") }
                            .foregroundStyle(.gray).font(.system(size: 13))
                    }
                    Spacer()
                    InfoButton()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                Spacer()
            }
        }
    }
}

// MARK: - 最近通话

private struct RecentsView: View {
    private let calls: [(String, String, String, Bool)] = [
        ("9520071", "未知", "2026/9/10", true),
        ("(0532) 8534 0012", "山东 青岛", "2026/9/10", false),
        ("(0532) 8534 0012", "山东 青岛", "2026/9/10", false),
        ("053885340012", "未知", "2026/9/10", false),
        ("9540134", "未知", "2026/9/10", true),
        ("175 6087 7999", "山东 泰安", "2026/9/9", false),
        ("184 1688 3098", "山东 泰安", "2026/9/9", false),
        ("184 0086 5681", "北京", "2026/9/8", false)
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
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                StatusBar()
                HStack {
                    HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("列表") }.foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "plus").foregroundStyle(.blue).font(.system(size: 22, weight: .semibold))
                }.padding(.horizontal, 20)
                Header(title: "通讯录").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                SearchBar().padding(.horizontal, 20)
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
                }.padding(.horizontal, 20)
                Spacer()
                VStack(spacing: 8) {
                    Text("无联系人").foregroundStyle(.white).font(.system(size: 20, weight: .bold))
                    Text("已添加的联系人将在此处显示。").foregroundStyle(.gray).font(.system(size: 14))
                    Text("新建联系人").foregroundStyle(.blue).font(.system(size: 15))
                }
                Spacer()
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
            VStack {
                StatusBar()
                Spacer()
                VStack(spacing: 18) {
                    ForEach(keys, id: \.self) { row in
                        HStack(spacing: 22) {
                            ForEach(row, id: \.self) { key in
                                Button { input.append(String(key.first!)) } label: {
                                    ZStack {
                                        Circle().fill(Color.gray.opacity(0.45)).frame(width: 78, height: 78)
                                        if key.contains("\n") {
                                            let parts = key.split(separator: "\n")
                                            VStack(spacing: 1) {
                                                Text(parts[0]).foregroundStyle(.white).font(.system(size: 30, weight: .regular))
                                                Text(parts[1]).foregroundStyle(.white).font(.system(size: 10, weight: .semibold))
                                            }
                                        } else {
                                            Text(key).foregroundStyle(.white).font(.system(size: 30))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // 已输入的号码（透明但占位，保持布局）
                Text(input).foregroundStyle(.clear).frame(height: 1)
                Button {
                    if input == secret { onSecret() }
                    input = ""
                } label: {
                    ZStack {
                        Circle().fill(Color.green).frame(width: 76, height: 76)
                        Image(systemName: "phone.fill").foregroundStyle(.white).font(.system(size: 30))
                    }
                }
                .padding(.top, 26)
                Spacer()
            }
        }
    }
}

// MARK: - 语音留言

private struct VoicemailView: View {
    private let mails: [(String, String, String, String)] = [
        ("+86 400 819 5561", "中国大陆", "2026/9/4", "01:22"),
        ("+86 (538) 634 4608", "山东 泰安", "2026/8/25", "01:59"),
        ("+86 (464) 616 3458", "黑龙江 七台河", "2026/8/16", "02:24"),
        ("+86 (21) 8051 6017", "上海", "2026/8/14", "00:40"),
        ("+86 (538) 631 4782", "山东 泰安", "2026/7/15", "00:34"),
        ("9529868", "未知", "2026/7/9", "01:14"),
        ("968018", "未知", "2026/7/6", "00:35"),
        ("+86 (755) 3638 0353", "广东 深圳", "2026/7/2", "00:40")
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
                }.frame(maxWidth: .infinity).padding(.top, 30)
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
