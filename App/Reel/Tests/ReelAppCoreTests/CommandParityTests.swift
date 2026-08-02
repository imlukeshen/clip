import AIKit
import ReelAppCore
import Testing

@MainActor
@Test func everyApplicationMenuItemIsARegisteredCommand() {
    for id in AppCommandRouter.menuCommandIDs {
        #expect(CommandRegistry.command(id: id) != nil, "Missing command \(id.rawValue)")
    }
}
