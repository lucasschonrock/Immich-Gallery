//
//  DateFormatter+Extensions.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-07-26.
//

import Foundation

extension DateFormatter {
    static func formatSpecificISO8601(_ utcTimestamp: String, includeTime: Bool = true) -> String {
        // Clean the input string
        let cleanedTimestamp = utcTimestamp
            .replacingOccurrences(of: "Optional(\"", with: "")
            .replacingOccurrences(of: "\")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(abbreviation: "UTC")
        
        // Try different format options to handle both with and without fractional seconds
        let formatOptions: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],  // For formats with .000Z
            [.withInternetDateTime],                          // For formats without fractional seconds
            [.withFullDate, .withTime, .withTimeZone],       // Alternative for +00:00 format
            [.withFullDate, .withTime, .withTimeZone, .withFractionalSeconds] // Alternative with fractional seconds
        ]
        
        for options in formatOptions {
            isoFormatter.formatOptions = options
            if let date = isoFormatter.date(from: cleanedTimestamp) {
                return formatDisplayDate(date, includeTime: includeTime)
            }
        }

        let fallbackFormats = [
            "yyyyMMdd'T'HHmmss",
            "yyyyMMdd'T'HHmmss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy:MM:dd HH:mm:ss",
            "yyyy-MM-dd"
        ]

        for dateFormat in fallbackFormats {
            let inputFormatter = DateFormatter()
            inputFormatter.locale = Locale(identifier: "en_US_POSIX")
            inputFormatter.timeZone = TimeZone(abbreviation: "UTC")
            inputFormatter.dateFormat = dateFormat

            if let date = inputFormatter.date(from: cleanedTimestamp) {
                return formatDisplayDate(date, includeTime: includeTime)
            }
        }
        
        return utcTimestamp
    }

    private static func formatDisplayDate(_ date: Date, includeTime: Bool) -> String {
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = includeTime ? "yyyy-MMM-dd HH:mm:ss" : "yyyy-MMM-dd"
        outputFormatter.timeZone = TimeZone(abbreviation: "UTC")
        outputFormatter.locale = Locale(identifier: "en_US_POSIX")

        return outputFormatter.string(from: date).uppercased()
    }
}
