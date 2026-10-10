import Foundation

// 极简断言器。不依赖任何测试框架——这套工具链（只有 CommandLineTools）里
// `swift test` 不会真的执行测试，详见 Package.swift 顶部说明。

final class Harness {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentGroup = ""

    func group(_ name: String) {
        currentGroup = name
        print("\n\u{001B}[1m── \(name) ──\u{001B}[0m")
    }

    func check(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(label)")
        } else {
            failures.append("[\(currentGroup)] \(label)")
            print("  \u{001B}[31m✗ \(label)\u{001B}[0m")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual == expected {
            passed += 1
            print("  \u{001B}[32m✓\u{001B}[0m \(label)")
        } else {
            failures.append("[\(currentGroup)] \(label)\n      期望: \(expected)\n      实际: \(actual)")
            print("  \u{001B}[31m✗ \(label)\u{001B}[0m\n      期望: \(expected)\n      实际: \(actual)")
        }
    }

    func close(_ actual: Double, _ expected: Double, tolerance: Double, _ label: String) {
        check(abs(actual - expected) <= tolerance,
              "\(label)（期望 \(expected) ± \(tolerance)，实际 \(String(format: "%.4f", actual))）")
    }

    func atLeast(_ actual: Double, _ floor: Double, _ label: String) {
        check(actual >= floor,
              "\(label)（要求 ≥ \(floor)，实际 \(String(format: "%.4f", actual))）")
    }

    func atMost(_ actual: Double, _ ceiling: Double, _ label: String) {
        check(actual <= ceiling,
              "\(label)（要求 ≤ \(ceiling)，实际 \(String(format: "%.4f", actual))）")
    }

    /// 打印总结并返回进程退出码
    func finish() -> Int32 {
        print("\n" + String(repeating: "─", count: 60))
        if failures.isEmpty {
            print("\u{001B}[32m全部通过：\(passed) 项检查\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m失败 \(failures.count) 项 / 共 \(passed + failures.count) 项：\u{001B}[0m")
        for f in failures { print("  · \(f)") }
        return 1
    }
}
