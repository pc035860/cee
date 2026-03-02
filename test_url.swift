import Foundation
let u = URL(fileURLWithPath: "/tmp/foo")
let u2 = u.appendingPathComponent(".")
let u3 = u2.deletingLastPathComponent()
print("original: \(u.path)")
print("appended: \(u2.path)")
print("deleted: \(u3.path)")

let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
