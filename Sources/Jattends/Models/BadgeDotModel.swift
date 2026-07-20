/// Pure state-transition model for the menu bar badge dot.
///
/// The dot previously animated based on a comparison of freshly-created
/// CGColor instances, which was unreliable and caused spurious blink
/// animations on every store reload. This model makes the transition
/// decision explicit and testable: an unchanged urgency is a no-op.
enum BadgeDotModel {
    enum Urgency: Equatable {
        case urgent, normal
    }

    enum Action: Equatable {
        case none
        case appear(Urgency)
        case disappear
        case swap(Urgency)
    }

    static func transition(from previous: Urgency?, to current: Urgency?) -> Action {
        switch (previous, current) {
        case (nil, nil):
            return .none
        case (nil, let next?):
            return .appear(next)
        case (.some, nil):
            return .disappear
        case (let prev?, let next?):
            return prev == next ? .none : .swap(next)
        }
    }
}
