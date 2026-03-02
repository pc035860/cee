import Foundation
let u1 = URL(fileURLWithPath: "/tmp/foo/.").deletingLastPathComponent()
let u2 = URL(fileURLWithPath: "/tmp/foo/image.jpg").deletingLastPathComponent()
print("u1: \(u1.path) , u2: \(u2.path)")
print("u1 == u2: \(u1 == u2)")
