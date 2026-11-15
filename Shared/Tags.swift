import Foundation

/// 标签：AI 整理时会给每条录音打几个，用户也可以自己加、删、改（设计稿 design/ui/ui_tags_list.png、ui_tags_edit.png）。
/// 标签存在 Recording.tags 里；用户动过一次，这条的 tagsEdited 就为真，重新整理时不再覆盖。
extension BeanStore {
    /// 去掉井号和首尾空白。AI 有时写「#客户」，有时写「客户」，统一成后者。
    nonisolated static func cleanTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "#＃ \t\n"))
    }

    func recordings(tagged tag: String) -> [Recording] {
        recordings.filter { $0.tags.contains { Self.cleanTag($0) == tag } }
    }

    func addTag(_ id: UInt32, _ raw: String) {
        let tag = Self.cleanTag(raw)
        guard !tag.isEmpty, let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        guard !recordings[i].tags.contains(where: { Self.cleanTag($0) == tag }) else { return }
        recordings[i].tags.append(tag)
        recordings[i].tagsEdited = true
        saveLibrary()
    }

    func removeTag(_ id: UInt32, _ tag: String) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].tags.removeAll { Self.cleanTag($0) == tag }
        recordings[i].tagsEdited = true
        saveLibrary()
    }

    /// 改名：所有用到这个标签的录音一起改；改成已有的名字就是合并。
    func renameTag(_ old: String, to raw: String) {
        let new = Self.cleanTag(raw)
        guard !new.isEmpty, new != old else { return }
        for i in recordings.indices where recordings[i].tags.contains(where: { Self.cleanTag($0) == old }) {
            var tags = recordings[i].tags.map(Self.cleanTag).map { $0 == old ? new : $0 }
            var seen = Set<String>()
            tags = tags.filter { seen.insert($0).inserted }
            recordings[i].tags = tags
            recordings[i].tagsEdited = true
        }
        saveLibrary()
        addLog("标签「\(old)」改成「\(new)」")
    }

    /// 从所有录音上去掉这个标签。
    func deleteTag(_ tag: String) {
        for i in recordings.indices where recordings[i].tags.contains(where: { Self.cleanTag($0) == tag }) {
            recordings[i].tags.removeAll { Self.cleanTag($0) == tag }
            recordings[i].tagsEdited = true
        }
        saveLibrary()
        addLog("删掉了标签「\(tag)」")
    }
}
