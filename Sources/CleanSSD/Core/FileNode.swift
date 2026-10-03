import Foundation

/// Узел дерева файловой системы. Мелкие файлы не хранятся отдельными узлами,
/// а агрегируются в `smallFilesSize` родительской папки — это экономит память
/// при сканировании миллионов файлов.
final class FileNode: Identifiable {
    let name: String
    let isDirectory: Bool
    /// Итоговый занятый размер (с учётом всех потомков) — заполняется в `finalize()`.
    var size: Int64 = 0
    /// Собственный размер: для файла — занятые блоки, для папки — блоки самой записи каталога.
    var selfSize: Int64 = 0
    var smallFilesSize: Int64 = 0
    var smallFilesCount = 0
    var itemCount = 0
    var children: [FileNode] = []
    weak var parent: FileNode?
    var isAccessDenied = false

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }

    func append(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    /// Полный путь. У корня `name` — это абсолютный путь.
    var path: String {
        guard let parent else { return name }
        return (parent.path as NSString).appendingPathComponent(name)
    }

    var displayName: String {
        parent == nil ? ((name as NSString).lastPathComponent.isEmpty ? name : (name as NSString).lastPathComponent) : name
    }

    /// Подсчитывает размеры снизу вверх и сортирует детей по убыванию размера.
    func finalize() {
        guard isDirectory else {
            size = selfSize
            itemCount = 1
            return
        }
        var total = selfSize + smallFilesSize
        var count = smallFilesCount
        for child in children {
            child.parent = self
            child.finalize()
            total += child.size
            count += child.itemCount
        }
        children.sort { $0.size > $1.size }
        size = total
        itemCount = count
    }

    func isAncestor(of other: FileNode) -> Bool {
        var current = other.parent
        while let node = current {
            if node === self { return true }
            current = node.parent
        }
        return false
    }

    /// Убирает узел из дерева и вычитает его размер из всех предков.
    func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var current: FileNode? = parent
        while let node = current {
            node.size -= size
            node.itemCount -= itemCount
            node.children.sort { $0.size > $1.size }
            current = node.parent
        }
        self.parent = nil
    }

    func find(path target: String) -> FileNode? {
        let rootPath = path
        if target == rootPath { return self }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var node: FileNode = self
        for component in target.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// Цепочка от корня до этого узла (для «хлебных крошек»).
    var lineage: [FileNode] {
        var chain: [FileNode] = [self]
        var current = parent
        while let node = current {
            chain.append(node)
            current = node.parent
        }
        return chain.reversed()
    }
}
