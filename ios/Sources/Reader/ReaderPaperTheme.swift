import ReadiumNavigator
import UIKit

/// Use Readium's actual page palette for the native safe area and toolbar.
enum ReaderPaperTheme {
    static func background(_ preference: String) -> UIColor {
        let theme: Theme = preference == "dark" ? .dark : preference == "white" ? .light : .sepia
        return theme.backgroundColor.uiColor
    }
}
