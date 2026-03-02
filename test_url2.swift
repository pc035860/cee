import Foundation
let u1 = URL(fileURLWithPath: "/tmp/foo")
let u2 = URL(fileURLWithPath: "/tmp/foo/")

print("u1: \(u1.path)")
print("u1 + . : \(u1.appendingPathComponent(".").path)")
print("u1 + . - last : \(u1.appendingPathComponent(".").deletingLastPathComponent().path)")

print("u2: \(u2.path)")
print("u2 + . : \(u2.appendingPathComponent(".").path)")
print("u2 + . - last : \(u2.appendingPathComponent(".").deletingLastPathComponent().path)")

