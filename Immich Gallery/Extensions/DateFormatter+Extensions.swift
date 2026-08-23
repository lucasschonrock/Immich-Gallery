//
//  DateFormatter+Extensions.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-07-26.
//

import Foundation

extension DateFormatter {
    static func formatSpecificISO8601(_ utcTimestamp: String, includeTime: Bool = true) -> String {
        guard let date = date(fromImmichTimestamp: utcTimestamp) else {
            return utcTimestamp
        }
        return formatDisplayDate(date, includeTime: includeTime)
    }

    static func formatThumbnailDate(_ utcTimestamp: String) -> String {
        guard let date = date(fromImmichTimestamp: utcTimestamp) else {
            return utcTimestamp
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter.string(from: date)
    }

    private static func date(fromImmichTimestamp utcTimestamp: String) -> Date? {
        let cleanedTimestamp = utcTimestamp
            .replacingOccurrences(of: "Optional(\"", with: "")
            .replacingOccurrences(of: "\")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = TimeZone(abbreviation: "UTC")

        let formatOptions: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate, .withTime, .withTimeZone],
            [.withFullDate, .withTime, .withTimeZone, .withFractionalSeconds]
        ]

        for options in formatOptions {
            isoFormatter.formatOptions = options
            if let date = isoFormatter.date(from: cleanedTimestamp) {
                return date
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
                return date
            }
        }

        return nil
    }

    private static func formatDisplayDate(_ date: Date, includeTime: Bool) -> String {
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = includeTime ? "yyyy-MMM-dd HH:mm:ss" : "yyyy-MMM-dd"
        outputFormatter.timeZone = TimeZone(abbreviation: "UTC")
        outputFormatter.locale = Locale(identifier: "en_US_POSIX")

        return outputFormatter.string(from: date).uppercased()
    }
}
