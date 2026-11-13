import EventKit
import Foundation
import Observation

/// Today's meetings from the Calendar app of this Mac, for the notch. The hub never sees them.
@MainActor
@Observable
final class MeetingCalendar {
    enum Access {
        case notAsked, granted, denied
    }

    private static let isOnKey = "showsMeetings"
    /// The Calendar app brings changes from the server with a delay of its own, so asking more often gains nothing.
    private static let refreshInterval: Duration = .seconds(60)
    private static let callPattern = #/
        https://(?:
            meet\.google\.com/[a-z]+(?:-[a-z]+)*
          | [\w.-]*zoom\.us/j/[^\s<>"]+
          | teams\.microsoft\.com/l/meetup-join/[^\s<>"]+
        )
        /#

    private(set) var access = MeetingCalendar.currentAccess
    /// The ones not over yet, by start.
    private(set) var meetings: [Meeting] = [] {
        didSet {
            if meetings != oldValue { onChange(meetings) }
        }
    }
    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.isOnKey)
            refresh()
        }
    }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private let onChange: ([Meeting]) -> Void

    init(onChange: @escaping ([Meeting]) -> Void) {
        self.onChange = onChange
        isOn = UserDefaults.standard.object(forKey: Self.isOnKey) as? Bool ?? true
        Task { [weak self] in
            repeat {
                self?.refresh()
            } while (try? await Task.sleep(for: Self.refreshInterval)) != nil
        }
    }

    /// Shows the macOS dialog, so only Settings asks, never the board.
    func requestAccess() async {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { @Sendable _, _ in continuation.resume() }
        }
        refresh()
    }

    private func refresh() {
        // Access can be taken back in System Settings at any moment.
        access = Self.currentAccess
        meetings = isOn && access == .granted ? meetingsLeftToday() : []
    }

    private func meetingsLeftToday() -> [Meeting] {
        let now = Date.now
        let calendars = store.calendars(for: .event).filter { $0.type != .birthday && $0.type != .subscription }
        guard !calendars.isEmpty, let day = Calendar.current.dateInterval(of: .day, for: now) else { return [] }
        let today = store.predicateForEvents(withStart: day.start, end: day.end, calendars: calendars)
        return store.events(matching: today)
            .filter { $0.endDate > now }
            .compactMap(Self.meeting)
            .sorted { $0.start < $1.start }
    }

    private static var currentAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private static func meeting(from event: EKEvent) -> Meeting? {
        let link = callLink(of: event)
        guard isMeeting(event, link: link) else { return nil }
        return Meeting(
            // Every occurrence of a repeating meeting has the same identifier.
            key: "\(event.calendarItemIdentifier) \(event.startDate.timeIntervalSince1970)",
            title: event.title ?? "(no title)",
            start: event.startDate,
            end: event.endDate,
            link: link
        )
    }

    /// With someone else and not declined, or a call of one's own. Calendars of colleagues shared
    /// with this Mac hold their meetings too, so an event with guests counts only with the user among them.
    private static func isMeeting(_ event: EKEvent, link: URL?) -> Bool {
        guard !event.isAllDay, event.status != .canceled else { return false }
        guard let attendees = event.attendees, !attendees.isEmpty else { return link != nil }
        if let user = attendees.first(where: \.isCurrentUser) {
            return user.participantStatus != .declined
        }
        return event.organizer?.isCurrentUser == true
    }

    private static func callLink(of event: EKEvent) -> URL? {
        [event.url?.absoluteString, event.location, event.notes].lazy
            .compactMap { $0?.firstMatch(of: callPattern) }
            .compactMap { URL(string: String($0.output)) }
            .first
    }
}
