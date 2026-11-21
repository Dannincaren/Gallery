import SwiftUI
import GalleryCore

struct MappingGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "info.circle").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.secondary)
                Text(L("映射说明")).font(.title2.bold())
                Text(L("把喜欢的素材，分配给 macOS 的每一种光标。"))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("GALLERY").font(.system(size: 10, weight: .medium)).kerning(2.5).foregroundStyle(.tertiary)
            }.padding(24).frame(width: 160, alignment: .leading).frame(maxHeight: .infinity)
                .background(.quaternary.opacity(0.3))
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        action("01", L("连接素材"), L("点一侧橱窗，再点另一侧。"),
                               L("一次完成连接并高亮对应连线。橱窗选择会自动清空，无需再点一次。"))
                        action("02", L("选择与解除"), L("单击选线，快速双击解除。"),
                               L("再次单击连线取消高亮；点击空白处清空连线和橱窗的选择。"))
                        action("03", L("版本与撤回"), L("点省略号选版本，点右上角撤回。"),
                               L("版本面板中点「选用此版本」确认。右上角的恢复按钮可恢复导入对应关系，该操作也能撤回。"))
                        action("04", L("保存更改"), L("点右上角「保存」完成。"),
                               L("有未配对角色时先确认使用系统光标，再单独选择是否删除未用素材。确认列表可在窗口内滚动。"))
                        Divider().padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("补充说明")).font(.headline)
                            note(L("左侧为 macOS 原生角色的固定预览，不随正在使用的主题改变；右侧为主题保留的素材。名称采用系统接口名或真实标识符，并附功能说明；未公开槽位的用途可能未确认。反色 I 型槽的系统原图为红色方块，不代表日常文本光标的外观。"))
                            note(L("右侧预览忽略主题整体及角色的自定义缩放，保留动画帧与播放节奏。各素材自动适应预览区域，相差不超过 2% 的倍率统一取较小值。实际使用大小仍以主题与角色设置为准。"))
                            note(L("同一素材可分配给多个原生角色，保存后各目标的大小、热点与动画独立。布局变化时视图会跟随左侧角色；手动滚动可中断跟随。"))
                            note(L("删除只清理当前主题在 Gallery 内的未用素材，不改动原始安装包或其他主题。已经删除的素材不能通过恢复按钮找回；放弃未保存的映射不会更改主题。"))
                        }.padding(.bottom, 4)
                    }.padding(.trailing, 10).padding(.vertical, 2)
                }
                Divider()
                HStack(spacing: 12) {
                    Text(L("以后可通过标题旁的 ⓘ 再次查看。")).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L("知道了")) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }.padding(26)
        }.frame(width: 730, height: 660)
    }
    private func action(_ number: String, _ title: String, _ lead: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.title3.bold())
                Text(lead).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.body)
            }.fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
