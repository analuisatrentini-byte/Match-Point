import Foundation

// MARK: - API Tennis Date Parsing

/// Returns nil when the API returns an unparseable date. Callers must decide
/// how to treat that — historically this function fell back to `.now`, which
/// silently shifted historical matches forward to today and corrupted fixture
/// vs. history separation. Prefer `.distantPast` or skipping the record.
func parseDate(dateString: String?, timeString: String?) -> Date? {
    let formatter = TennisAPIConfiguration.makePOSIXDateFormatter()

    let cleanedDate = dateString?.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanedTime = timeString?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let cleanedDate, let cleanedTime, !cleanedDate.isEmpty, !cleanedTime.isEmpty {
        let combined = "\(cleanedDate) \(cleanedTime)"
        for format in [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "dd.MM.yyyy HH:mm",
            "dd/MM/yyyy HH:mm"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: combined) {
                return date
            }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleanedDate) {
                return date
            }
        }
    }

    if let cleanedDate, !cleanedDate.isEmpty {
        for format in [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "dd-MM-yyyy",
            "dd.MM.yyyy",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleanedDate) {
                return date
            }
        }
    }

    return nil
}
