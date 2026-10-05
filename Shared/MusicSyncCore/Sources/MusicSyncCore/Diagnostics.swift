// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
import Foundation

public enum DiagnosticLevel: String, CaseIterable, Codable, Sendable { case info, warning, error }
public struct DiagnosticEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let role: String
    public let level: DiagnosticLevel
    public let text: String
}
/// Session-only bounded events; callers must never submit packets or credentials.
public struct DiagnosticHistory {
    public private(set) var entries: [DiagnosticEntry] = []
    private let capacity: Int
    public init(capacity: Int = 300) { self.capacity = min(1000,max(1,capacity)) }
    @discardableResult public mutating func append(role: String, level: DiagnosticLevel = .info, text: String, date: Date = Date()) -> Bool {
        let clean = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(600))
        guard !clean.trimmingCharacters(in:.whitespaces).isEmpty else { return false }
        let role = String(role.prefix(40))
        if let last = entries.last, last.role == role, last.level == level, last.text == clean, (0..<2).contains(date.timeIntervalSince(last.date)) { return false }
        entries.append(DiagnosticEntry(id:UUID(),date:date,role:role,level:level,text:clean))
        if entries.count > capacity { entries.removeFirst(entries.count-capacity) }
        return true
    }
    public mutating func clear() { entries.removeAll(keepingCapacity:true) }
    public var plainText: String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return entries.map { "\(formatter.string(from:$0.date)) [\($0.role)] [\($0.level.rawValue)] \($0.text)" }.joined(separator:"\n")
    }
}
