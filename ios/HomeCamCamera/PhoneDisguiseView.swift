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
                viewID = UUID()
            }
        }
    }
}

enum PhoneTab: Hashable { case favorites, recents, contacts, keypad, voicemail }

// MARK: - 数据（通讯录号码与通话记录互相呼应）

private let contactList: [(String, String)] = [
    ("张伟明", "138 0013 8000"), ("李静怡", "139 1122 3344"),
    ("王建国", "136 6677 8899"), ("陈思远", "158 2233 4455"),
    ("赵敏华", "137 8899 0011"), ("刘晓彤", "186 3344 5566"),
    ("周文杰", "135 0011 2233"), ("吴佳怡", "188 5566 7788"),
    ("孙浩然", "159 7788 9900"), ("妈妈", "133 4567 8899"),
    ("房东-李叔", "139 8877 6655"), ("快递-顺丰", "185 0023 6688"),
    ("银行客服", "95588"), ("幼儿园-张老师", "0538 6221 8890")
]

private enum CallKind { case incoming, outgoing, missed
    var icon: String {
        switch self {
        case .incoming: return "phone.arrow.down.left.fill"
        case .outgoing: return "phone.arrow.up.right.fill"
        case .missed: return "phone.arrow.down.left.fill"
        }
    }
    var color: Color {
        switch self { case .incoming: return .green; case .outgoing: return .blue; case .missed: return .red }
    }
}

private struct CallEntry {
    let title: String
    let subtitle: String
    let date: String
    let kind: CallKind
}

// MARK: - 通用组件

private struct Avatar: View {
    var body: some View {
        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
            .frame(width: 44, height: 44).foregroundStyle(.gray.opacity(0.55))
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
    var body: some View { Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(.white) }
}

// MARK: - 个人收藏

private struct FavoritesView: View {
    private let favorites = ["妈妈", "张伟明", "李静怡", "快递-顺丰", "王建国", "房东-李叔"]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "plus").foregroundStyle(.blue).font(.system(size: 22, weight: .semibold))
                }.padding(.horizontal, 20).padding(.top, 10)
                Header(title: "个人收藏").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(favorites, id: \.self) { name in
                            let number = contactList.first { $0.0 == name }?.1 ?? ""
                            HStack(spacing: 12) {
                                Avatar()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(name).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                    HStack(spacing: 3) { Image(systemName: "phone.fill").font(.system(size: 10)); Text(number) }
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
    private let calls: [CallEntry] = [
        CallEntry(title: "李静怡", subtitle: "139 1122 3344", date: "昨天 20:31", kind: .incoming),
        CallEntry(title: "185 0023 9966", subtitle: "广东 深圳", date: "昨天 18:12", kind: .missed),
        CallEntry(title: "张伟明", subtitle: "138 0013 8000", date: "昨天 14:05", kind: .outgoing),
        CallEntry(title: "妈妈", subtitle: "133 4567 8899", date: "昨天 09:48", kind: .incoming),
        CallEntry(title: "021 6288 3391", subtitle: "上海", date: "11月19日 16:23", kind: .missed),
        CallEntry(title: "银行客服", subtitle: "95588", date: "11月19日 11:07", kind: .incoming),
        CallEntry(title: "陈思远", subtitle: "158 2233 4455", date: "11月18日 21:15", kind: .outgoing),
        CallEntry(title: "房东-李叔", subtitle: "139 8877 6655", date: "11月18日 19:30", kind: .outgoing),
        CallEntry(title: "400 820 5588", subtitle: "未知", date: "11月18日 10:12", kind: .missed),
        CallEntry(title: "赵敏华", subtitle: "137 8899 0011", date: "11月17日 17:44", kind: .incoming),
        CallEntry(title: "10086", subtitle: "未知", date: "11月17日 08:56", kind: .incoming),
        CallEntry(title: "王建国", subtitle: "136 6677 8899", date: "11月16日 20:10", kind: .outgoing),
        CallEntry(title: "186 6677 3312", subtitle: "山东 青岛", date: "11月16日 15:33", kind: .missed),
        CallEntry(title: "快递-顺丰", subtitle: "185 0023 6688", date: "11月15日 13:22", kind: .incoming),
        CallEntry(title: "刘晓彤", subtitle: "186 3344 5566", date: "11月15日 11:05", kind: .incoming),
        CallEntry(title: "幼儿园-张老师", subtitle: "0538 6221 8890", date: "11月14日 16:40", kind: .outgoing),
        CallEntry(title: "139 1100 2288", subtitle: "四川 成都", date: "11月13日 19:28", kind: .missed),
        CallEntry(title: "周文杰", subtitle: "135 0011 2233", date: "11月12日 12:15", kind: .incoming),
        CallEntry(title: "李静怡", subtitle: "139 1122 3344", date: "11月11日 18:02", kind: .incoming),
        CallEntry(title: "400 820 5588", subtitle: "未知", date: "11月10日 09:33", kind: .incoming),
        CallEntry(title: "吴佳怡", subtitle: "188 5566 7788", date: "11月8日 21:06", kind: .outgoing),
        CallEntry(title: "171 8856 3209", subtitle: "北京", date: "11月6日 14:27", kind: .missed)
    ]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    HStack(spacing: 0) {
                        Text("所有通话").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6).background(Color.white.opacity(0.2))
                        Text("未接来电").font(.system(size: 13)).foregroundStyle(.gray).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 10)
                Header(title: "最近通话").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                SearchBar().padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(calls.indices, id: \.self) { i in
                            let c = calls[i]
                            HStack(spacing: 12) {
                                Avatar()
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.title).foregroundStyle(c.kind == .missed ? .red : .white).font(.system(size: 16, weight: .semibold))
                                    HStack(spacing: 4) {
                                        Image(systemName: c.kind.icon).font(.system(size: 10)).foregroundStyle(c.kind.color)
                                        Text(c.subtitle).font(.system(size: 13)).foregroundStyle(.gray)
                                    }
                                }
                                Spacer()
                                Text(c.date).foregroundStyle(.gray).font(.system(size: 12))
                                InfoButton()
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

// MARK: - 通讯录

private struct ContactsView: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("列表") }.foregroundStyle(.blue)
                    Spacer()
                    Image(systemName: "plus").foregroundStyle(.blue).font(.system(size: 22, weight: .semibold))
                }.padding(.horizontal, 20).padding(.top, 10)
                Header(title: "通讯录").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                SearchBar().padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.blue.opacity(0.7)).frame(width: 46, height: 46)
                                Text("WJ").foregroundStyle(.white).font(.system(size: 18, weight: .semibold))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Wenjun Zhu").foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                Text("我的名片").foregroundStyle(.gray).font(.system(size: 13))
                            }
                            Spacer()
                        }.padding(.vertical, 10).padding(.horizontal, 20)
                        Divider().background(Color.white.opacity(0.15)).padding(.leading, 20)
                        ForEach(contactList.indices, id: \.self) { i in
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.gray.opacity(0.45)).frame(width: 42, height: 42)
                                    Text(String(contactList[i].0.prefix(1))).foregroundStyle(.white).font(.system(size: 17, weight: .semibold))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(contactList[i].0).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                    Text(contactList[i].1).foregroundStyle(.gray).font(.system(size: 13))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8).padding(.horizontal, 20)
                            Divider().background(Color.white.opacity(0.15)).padding(.leading, 74)
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
                ZStack {
                    Text(input).foregroundStyle(.white).font(.system(size: 32, weight: .regular)).frame(height: 48)
                    HStack {
                        Spacer()
                        Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(.blue).font(.system(size: 24))
                    }.padding(.trailing, 24)
                }
                .padding(.top, 18)
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
        ("李静怡", "139 1122 3344", "昨天 20:31", "00:42"),
        ("021 6288 3391", "上海", "11月19日 16:23", "01:18"),
        ("妈妈", "133 4567 8899", "11月17日 19:05", "00:55"),
        ("银行客服", "95588", "11月15日 11:07", "02:03"),
        ("张伟明", "138 0013 8000", "11月12日 14:05", "01:27"),
        ("400 820 5588", "未知", "11月10日 09:33", "00:36"),
        ("幼儿园-张老师", "0538 6221 8890", "11月8日 16:40", "01:44"),
        ("139 1100 2288", "四川 成都", "11月5日 19:28", "00:29"),
        ("王建国", "136 6677 8899", "11月2日 20:10", "01:12"),
        ("10086", "未知", "10月28日 08:56", "00:47")
    ]
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Text("编辑").foregroundStyle(.blue)
                    Spacer()
                    Text("应答语").foregroundStyle(.blue)
                }.padding(.horizontal, 20).padding(.top, 10)
                Header(title: "语音信箱").frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mails.indices, id: \.self) { i in
                            let m = mails[i]
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill").foregroundStyle(.gray).font(.system(size: 34))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.0).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
                                    Text(m.1).foregroundStyle(.gray).font(.system(size: 13))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(m.2).foregroundStyle(.gray).font(.system(size: 12))
                                    Text(m.3).foregroundStyle(.gray).font(.system(size: 13))
                                }
                                InfoButton()
                            }
                            .padding(.vertical, 10).padding(.horizontal, 20)
                            Divider().background(Color.white.opacity(0.15)).padding(.leading, 66)
                        }
                    }
                }
            }
        }
    }
}
