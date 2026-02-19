//
//  TimerDisplay.swift
//  FlowCue
//
//  Estimated time remaining display for the overlay.
//

import Foundation

class TimerEstimator {
    /// Estimate remaining time based on words left and speed
    /// - Parameters:
    ///   - totalWords: total words in script
    ///   - completedWords: words already spoken/scrolled
    ///   - wordsPerSecond: current speed setting
    /// - Returns: formatted string "MM:SS" or nil if no estimate
    static func estimateRemaining(totalWords: Int, completedWords: Int, wordsPerSecond: Double) -> String? {
        guard totalWords > 0, wordsPerSecond > 0 else { return nil }
        let remaining = max(0, totalWords - completedWords)
        let seconds = Int(Double(remaining) / wordsPerSecond)
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Calculate words per minute from start time and words completed
    static func wordsPerMinute(startTime: Date, wordsCompleted: Int) -> Int {
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 5, wordsCompleted > 0 else { return 0 }
        return Int(Double(wordsCompleted) / elapsed * 60)
    }
}
