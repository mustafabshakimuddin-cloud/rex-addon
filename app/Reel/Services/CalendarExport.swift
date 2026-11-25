import Foundation

/// Upcoming episodes as an iCalendar file, for the Calendar app or any other. Sharing the file
/// needs no calendar permission: the reader chooses where it goes.
enum CalendarExport {
    static func ics(_ episodes: [CalendarEpisode], now: Date = Date()) -> String {
        let stamp = DateFormatter.ics.string(from: now)
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//\(AppConfig.name)//Upcoming episodes//EN", "CALSCALE:GREGORIAN"]
        for entry in episodes {
            let day = DateFormatter.icsDay.string(from: entry.date)
            let next = DateFormatter.icsDay.string(from: entry.date.addingTimeInterval(86_400))
            lines += [
                "BEGIN:VEVENT",
                "UID:\(entry.id)@\(AppConfig.name.lowercased()).app",
                "DTSTAMP:\(stamp)",
                // A whole-day event: air times in the catalogue are rarely the real hour.
                "DTSTART;VALUE=DATE:\(day)",
                "DTEND;VALUE=DATE:\(next)",
                "SUMMARY:\(escape("\(entry.item.name) \(entry.episode.code)"))",
                "DESCRIPTION:\(escape(entry.episode.title))",
                "URL:reel://title/\(entry.item.id)?type=series",
                "END:VEVENT",
            ]
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func write(_ episodes: [CalendarEpisode]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Upcoming Episodes.ics")
        return (try? ics(episodes).data(using: .utf8)?.write(to: url, options: .atomic)) != nil ? url : nil
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: ";", with: #"\;"#)
            .replacingOccurrences(of: ",", with: #"\,"#)
            .replacingOccurrences(of: "\n", with: #"\n"#)
    }
}

private extension DateFormatter {
    static let ics: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    static let icsDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
}
