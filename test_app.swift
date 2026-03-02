import Foundation
let u = URL(fileURLWithPath: "/Applications/Safari.app")
let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
let isPackage = (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage
print("isDir: \(String(describing: isDir))")
print("isPackage: \(String(describing: isPackage))")
